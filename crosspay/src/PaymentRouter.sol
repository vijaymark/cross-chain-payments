// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OApp, Origin, MessagingFee, MessagingReceipt} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICrossChainTransport} from "./interfaces/ICrossChainTransport.sol";
import {IPaymentRouter} from "./interfaces/IPaymentRouter.sol";
import {PaymentCodec, PaymentType} from "./libraries/PaymentCodec.sol";

/// @title PaymentRouter
/// @notice CrossPay cross-chain payment router (LayerZero OApp), deployed
///         identically on every supported chain.
///
/// @dev Flow:
///      - **Source**: `sendPayment` / `sendStreamedPayment` pull `amount` of
///        `token` from the sender into the router (non-custodial lock), encode a
///        versioned payload with `PaymentCodec`, and dispatch it over LayerZero
///        to the registered peer on `dstEid`.
///      - **Destination**: `lzReceive` (after the endpoint + peer checks) decodes
///        the payload and either credits `claimable[recipient][token]` (Direct)
///        or mints a linearly-vesting `Stream`.
///      - The recipient calls `claim` / `claimDirect`; neither requires any
///        bridge interaction or source-chain gas.
///
/// ASSUMPTION (cross-chain token identity): the payload carries the token address
/// and the destination treats the *same* address as the payout token. This is only
/// correct when the token is deployed at an identical address on both chains
/// (`MockUSDC` via CREATE2, or a canonical token). A production version should add
/// a per-destination token registry. (Security-relevant, hence documented.)
///
/// ASSUMPTION (funding model): the destination router is pre-funded with the
/// token; `_lzReceive` only updates bookkeeping and `claim` transfers from the
/// router's own balance. No mint/burn or fee mechanism in this MVP (see
/// SECURITY.md).
contract PaymentRouter is OApp, ICrossChainTransport, IPaymentRouter, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ------------------------------------------------------------------ */
    /*                        Storage (packed Stream)                     */
    /* ------------------------------------------------------------------ */

    /// @notice A linearly-vesting stream of `token` to `recipient`.
    /// @dev    Packed into exactly 3 storage slots (order matters for packing;
    ///         validate with `forge inspect PaymentRouter storage-layout`):
    ///         - slot 0: `recipient` (20B) + `start` (5B) + `periods` (4B) — 29B used
    ///         - slot 1: `periodDuration` (4B) + `token` (20B) — 24B used
    ///           (`periodDuration` spills because 20+5+4+4 = 33B > 32B)
    ///         - slot 2: `total` (16B) + `claimed` (16B) — 32B used
    struct Stream {
        address recipient; // slot 0
        uint40 start; // slot 0 (Unix seconds; valid to year ~36k)
        uint32 periods; // slot 0
        uint32 periodDuration; // slot 1
        address token; // slot 1
        uint128 total; // slot 2
        uint128 claimed; // slot 2
    }

    /// @notice Tokens allowed to be routed (checked on both source and destination).
    mapping(address => bool) public supportedTokens;

    /// @notice Direct-payment balances awaiting claim: recipient => token => amount.
    mapping(address => mapping(address => uint256)) public claimable;

    /// @notice All streams, indexed by a monotonically increasing id.
    mapping(uint256 => Stream) public streams;

    /// @notice Next stream id to assign (destination side).
    uint256 public nextStreamId;

    /// @notice Gas forwarded to the destination executor to run `lzReceive`.
    uint128 public constant LZ_RECEIVE_GAS = 200_000;

    /* ------------------------------------------------------------------ */
    /*                             Constructor                            */
    /* ------------------------------------------------------------------ */

    /// @param _endpoint The local LayerZero Endpoint V2 address.
    /// @param _owner    Initial admin (two-step ownership); also registered as
    ///                  the LayerZero delegate.
    constructor(address _endpoint, address _owner) OApp(_endpoint, _owner) Ownable(_owner) {}

    /* ------------------------------------------------------------------ */
    /*                Ownership (two-step, reimplemented)                 */
    /* ------------------------------------------------------------------ */

    /// @dev OApp inherits OpenZeppelin `Ownable` (via OAppCore). Inheriting
    ///      `Ownable2Step` alongside it creates a diamond (both reach `Ownable`)
    ///      whose constructor cannot resolve cleanly, so the two-step transfer
    ///      is reimplemented here with identical semantics. See DECISIONS.md D11.
    address private _pendingOwner;

    /// @notice Emitted when an ownership transfer is initiated (not completed).
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    /// @notice The address that must call `acceptOwnership` to become owner.
    function pendingOwner() public view returns (address) {
        return _pendingOwner;
    }

    /// @notice Begin a two-step ownership transfer; sets the pending owner only.
    function transferOwnership(address newOwner) public override onlyOwner {
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner(), newOwner);
    }

    /// @notice Complete the pending ownership transfer (callable by the pending owner).
    function acceptOwnership() public {
        address sender = msg.sender;
        if (sender != _pendingOwner) revert OwnableUnauthorizedAccount(sender);
        _transferOwnership(sender);
    }

    /// @dev Clear the pending owner on any ownership change.
    function _transferOwnership(address newOwner) internal override {
        delete _pendingOwner;
        super._transferOwnership(newOwner);
    }

    /* ------------------------------------------------------------------ */
    /*                          Send (outbound)                           */
    /* ------------------------------------------------------------------ */

    /// @inheritdoc IPaymentRouter
    /// @dev The caller must send enough native currency to cover the LayerZero
    ///      fee (see `quoteSendPayment`); any excess is refunded to `msg.sender`.
    function sendPayment(uint32 dstEid, address recipient, address token, uint256 amount)
        external
        payable
        whenNotPaused
        nonReentrant
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (!supportedTokens[token]) revert UnsupportedToken();

        // Checks-Effects-Interactions: pull funds before dispatching.
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        bytes memory payload = PaymentCodec.encodeDirect(recipient, token, amount);
        this.sendMessage{value: msg.value}(dstEid, payload, msg.sender);

        emit PaymentSent(dstEid, recipient, token, amount, PaymentType.Direct);
    }

    /// @inheritdoc IPaymentRouter
    function sendStreamedPayment(
        uint32 dstEid,
        address recipient,
        address token,
        uint256 totalAmount,
        uint32 periods,
        uint32 periodDuration
    ) external payable whenNotPaused nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();
        if (totalAmount == 0) revert ZeroAmount();
        if (periods == 0 || periodDuration == 0) revert InvalidPeriods();
        if (!supportedTokens[token]) revert UnsupportedToken();

        IERC20(token).safeTransferFrom(msg.sender, address(this), totalAmount);

        bytes memory payload = PaymentCodec.encodeStream(recipient, token, totalAmount, periods, periodDuration);
        this.sendMessage{value: msg.value}(dstEid, payload, msg.sender);

        emit PaymentSent(dstEid, recipient, token, totalAmount, PaymentType.Stream);
    }

    /* ------------------------------------------------------------------ */
    /*                  Transport (ICrossChainTransport)                  */
    /* ------------------------------------------------------------------ */

    /// @inheritdoc ICrossChainTransport
    /// @dev Only self-callable (via the payment functions) so an arbitrary caller
    ///      cannot inject a spoofed payload toward the peer.
    function sendMessage(uint32 dstEid, bytes calldata payload, address refundAddress)
        external
        payable
        override
        onlySelf
        returns (bytes32 guid)
    {
        MessagingReceipt memory receipt =
            _lzSend(dstEid, payload, _executionOptions(), MessagingFee(msg.value, 0), refundAddress);
        emit MessageSent(dstEid, receipt.guid, payload);
        return receipt.guid;
    }

    /// @inheritdoc ICrossChainTransport
    /// @dev Only self-callable, from `_lzReceive` after endpoint + peer checks.
    function receiveMessage(uint32 srcEid, bytes32 guid, bytes calldata payload) external override onlySelf {
        _applyPayment(srcEid, guid, payload);
        emit MessageReceived(srcEid, guid, payload);
    }

    /// @dev Override the OApp entry point to reject unregistered peers with this
    ///      contract's own `UnauthorizedPeer()` error (the base used `OnlyPeer`).
    function lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) public payable override {
        if (address(endpoint) != msg.sender) revert OnlyEndpoint(msg.sender);
        if (peers[_origin.srcEid] != _origin.sender) revert UnauthorizedPeer();
        _lzReceive(_origin, _guid, _message, _executor, _extraData);
    }

    /// @dev LayerZero OApp receive hook. Peer + endpoint verification happens in
    ///      `lzReceive` above; here we only apply the (already trusted) payload.
    ///      Pause blocks inbound processing (but never claims).
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address, /* _executor */
        bytes calldata /* _extraData */
    )
        internal
        override
        whenNotPaused
    {
        this.receiveMessage(_origin.srcEid, _guid, _message);
    }

    /* ------------------------------------------------------------------ */
    /*                        Apply (destination)                         */
    /* ------------------------------------------------------------------ */

    /// @dev Decode a peer-verified payload and apply it: Direct -> credit
    ///      claimable balance; Stream -> create a Stream.
    function _applyPayment(uint32 srcEid, bytes32 guid, bytes calldata payload) private {
        PaymentCodec.PaymentMessage memory m = PaymentCodec.decode(payload);

        if (m.paymentType == PaymentType.Direct) {
            if (!supportedTokens[m.token]) revert UnsupportedToken();
            if (m.amount == 0) revert ZeroAmount();

            claimable[m.recipient][m.token] += m.amount;
            emit PaymentReceived(srcEid, guid, m.recipient, m.token, m.amount);
        } else {
            // PaymentType.Stream
            if (!supportedTokens[m.token]) revert UnsupportedToken();
            if (m.amount == 0) revert ZeroAmount();
            if (m.periods == 0 || m.periodDuration == 0) revert InvalidPeriods();
            if (m.amount > type(uint128).max) revert AmountTooLarge();

            uint256 streamId = nextStreamId++;
            streams[streamId] = Stream({
                recipient: m.recipient,
                start: uint40(block.timestamp),
                periods: m.periods,
                periodDuration: m.periodDuration,
                token: m.token,
                total: uint128(m.amount),
                claimed: 0
            });

            emit StreamCreated(srcEid, guid, streamId, m.recipient, m.token, m.amount, m.periods, m.periodDuration);
        }
    }

    /* ------------------------------------------------------------------ */
    /*                        Claim (destination)                         */
    /* ------------------------------------------------------------------ */

    /// @inheritdoc IPaymentRouter
    /// @dev Reverts if the caller is not the stream recipient, or nothing is
    ///      currently claimable. Never blocked by the pause flag.
    function claim(uint256 streamId) external nonReentrant {
        Stream storage s = streams[streamId];
        if (s.recipient != msg.sender) revert NotStreamRecipient();

        uint256 vested = _vestedAmount(s.total, s.claimed, s.start, s.periods, s.periodDuration);
        uint256 amount = vested - s.claimed;
        if (amount == 0) revert NothingToClaim();

        // Checks-Effects-Interactions: record the claim before transferring.
        // casting to 'uint128' is safe because `vested` is always <= `total` (uint128).
        // forge-lint: disable-next-line(unsafe-typecast)
        s.claimed = uint128(vested);
        IERC20(s.token).safeTransfer(msg.sender, amount);

        emit StreamClaimed(streamId, msg.sender, amount);
    }

    /// @inheritdoc IPaymentRouter
    /// @dev Never blocked by the pause flag.
    function claimDirect(address token) external nonReentrant {
        uint256 amount = claimable[msg.sender][token];
        if (amount == 0) revert NothingToClaim();

        claimable[msg.sender][token] = 0; // CEI: zero out before transferring.
        IERC20(token).safeTransfer(msg.sender, amount);

        emit DirectClaimed(msg.sender, token, amount);
    }

    /// @dev Linear vesting: `min(total, total * elapsed / (periods * periodDuration))`.
    function _vestedAmount(uint256 total, uint256 claimed, uint40 start, uint32 periods, uint32 periodDuration)
        internal
        view
        returns (uint256)
    {
        if (claimed >= total) return total;

        uint256 duration = uint256(periods) * uint256(periodDuration);
        if (duration == 0) return total; // unreachable: apply() validates periods/periodDuration != 0

        uint256 elapsed = block.timestamp - start;
        if (elapsed >= duration) return total;
        return (total * elapsed) / duration;
    }

    /* ------------------------------------------------------------------ */
    /*                        Admin (Ownable2Step)                        */
    /* ------------------------------------------------------------------ */

    /// @inheritdoc IPaymentRouter
    function setSupportedToken(address token, bool supported) external onlyOwner {
        supportedTokens[token] = supported;
        emit TokenSupportUpdated(token, supported);
    }

    /// @inheritdoc IPaymentRouter
    function pause() external onlyOwner {
        _pause();
    }

    /// @inheritdoc IPaymentRouter
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @inheritdoc IPaymentRouter
    /// @dev Structurally cannot touch `supportedTokens` (which may hold user
    ///      funds) — it reverts `TokenIsSupported` first, so an owner can never
    ///      rug already-escrowed funds through this path.
    function rescueTokens(address token, uint256 amount, address to) external onlyOwner nonReentrant {
        if (supportedTokens[token]) revert TokenIsSupported();
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    /* ------------------------------------------------------------------ */
    /*                          Quote helpers                             */
    /* ------------------------------------------------------------------ */

    /// @inheritdoc IPaymentRouter
    function quoteSendPayment(uint32 dstEid, address recipient, address token, uint256 amount)
        external
        view
        returns (uint256 nativeFee)
    {
        return _quote(dstEid, PaymentCodec.encodeDirect(recipient, token, amount), _executionOptions(), false).nativeFee;
    }

    /// @inheritdoc IPaymentRouter
    function quoteSendStreamedPayment(
        uint32 dstEid,
        address recipient,
        address token,
        uint256 totalAmount,
        uint32 periods,
        uint32 periodDuration
    ) external view returns (uint256 nativeFee) {
        return _quote(
            dstEid,
            PaymentCodec.encodeStream(recipient, token, totalAmount, periods, periodDuration),
            _executionOptions(),
            false
        )
        .nativeFee;
    }

    /* ------------------------------------------------------------------ */
    /*                           Internals                                 */
    /* ------------------------------------------------------------------ */

    /// @dev Execution options: allocate `LZ_RECEIVE_GAS` to `lzReceive` on the
    ///      destination.
    function _executionOptions() internal pure returns (bytes memory) {
        return OptionsBuilder.addExecutorLzReceiveOption(OptionsBuilder.newOptions(), LZ_RECEIVE_GAS, 0);
    }

    /// @dev Restrict transport entry points to self-calls from payment logic /
    ///      the receive hook.
    modifier onlySelf() {
        if (msg.sender != address(this)) revert UnauthorizedCaller(msg.sender);
        _;
    }
}
