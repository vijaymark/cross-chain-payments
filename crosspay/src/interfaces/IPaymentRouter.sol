// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PaymentType} from "../libraries/PaymentCodec.sol";

/// @title IPaymentRouter
/// @notice Public interface for the CrossPay `PaymentRouter`.
/// @dev    `setPeer`, `peers`, and `endpoint` are inherited from LayerZero's
///         `IOAppCore` (via `OApp`), so they are intentionally NOT re-declared
///         here — the `PeerSet` event is likewise emitted by that base contract.
interface IPaymentRouter {
    /* ------------------------------ errors ---------------------------- */

    error ZeroAddress();
    error ZeroAmount();
    error UnsupportedToken();
    error InvalidPeriods();
    error NotStreamRecipient();
    error NothingToClaim();
    error UnauthorizedPeer();
    error TokenIsSupported();
    error AmountTooLarge();
    /// @notice Reverts when the transport entry points (`sendMessage`/
    ///         `receiveMessage`) are called by anyone other than the router.
    error UnauthorizedCaller(address caller);

    /* ------------------------------ events ---------------------------- */

    event PaymentSent(
        uint32 indexed dstEid, address indexed recipient, address indexed token, uint256 amount, PaymentType paymentType
    );
    event PaymentReceived(
        uint32 indexed srcEid, bytes32 indexed guid, address indexed recipient, address token, uint256 amount
    );
    event StreamCreated(
        uint32 indexed srcEid,
        bytes32 indexed guid,
        uint256 indexed streamId,
        address recipient,
        address token,
        uint256 totalAmount,
        uint32 periods,
        uint32 periodDuration
    );
    event StreamClaimed(uint256 indexed streamId, address indexed recipient, uint256 amount);
    event DirectClaimed(address indexed recipient, address indexed token, uint256 amount);
    event TokenSupportUpdated(address indexed token, bool supported);

    /* --------------------------- payments ----------------------------- */

    /// @notice Send an immediate payment to `recipient` on `dstEid`.
    function sendPayment(uint32 dstEid, address recipient, address token, uint256 amount) external payable;

    /// @notice Send a linearly-vesting streamed payment to `recipient` on `dstEid`.
    function sendStreamedPayment(
        uint32 dstEid,
        address recipient,
        address token,
        uint256 totalAmount,
        uint32 periods,
        uint32 periodDuration
    ) external payable;

    /// @notice Withdraw the vested-but-unclaimed portion of `streamId`.
    function claim(uint256 streamId) external;

    /// @notice Withdraw the direct-payment balance for `msg.sender` in `token`.
    function claimDirect(address token) external;

    /* ----------------------------- quotes ----------------------------- */

    /// @notice Native fee required to send a direct payment.
    function quoteSendPayment(uint32 dstEid, address recipient, address token, uint256 amount)
        external
        view
        returns (uint256 nativeFee);

    /// @notice Native fee required to send a streamed payment.
    function quoteSendStreamedPayment(
        uint32 dstEid,
        address recipient,
        address token,
        uint256 totalAmount,
        uint32 periods,
        uint32 periodDuration
    ) external view returns (uint256 nativeFee);

    /* ----------------------------- admin ------------------------------ */

    /// @notice Enable or disable `token` as a routable asset.
    function setSupportedToken(address token, bool supported) external;

    /// @notice Pause new sends and inbound processing (claims unaffected).
    function pause() external;

    /// @notice Resume sends and inbound processing.
    function unpause() external;

    /// @notice Rescue accidentally-sent tokens. Structurally cannot touch
    ///         `supportedTokens` (reverts `TokenIsSupported`).
    function rescueTokens(address token, uint256 amount, address to) external;
}
