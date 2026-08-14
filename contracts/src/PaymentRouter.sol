// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./IERC20.sol";
import {IBridgeAdapter, IBridgeReceiver} from "./IBridgeAdapter.sol";
import {Types} from "./Types.sol";
import {StreamEscrow} from "./StreamEscrow.sol";
import {MilestoneEscrow} from "./MilestoneEscrow.sol";

/// @notice Entry point for all cross-chain payments.
///
/// Source-chain flow: validate input → pull funds into the correct escrow →
/// encode the canonical message → dispatch to the bridge adapter.
///
/// Destination-chain flow: `receiveMessage` (bridge-only) decodes and
/// replay-checks the message, then records the announcement for status queries.
contract PaymentRouter is IBridgeReceiver {
    error PaymentRouter__NotOwner();
    error PaymentRouter__NotBridge();
    error PaymentRouter__NoBridge();
    error PaymentRouter__ZeroAmount();
    error PaymentRouter__ZeroRecipient();
    error PaymentRouter__ZeroDuration();
    error PaymentRouter__TimeoutInPast();
    error PaymentRouter__WrongDestChain();
    error PaymentRouter__Replay();

    /// @notice Chain id of the chain this router is deployed on.
    uint256 public immutable sourceChainId;

    address public owner;
    IBridgeAdapter public bridge;

    /// @notice sender => next nonce to use.
    mapping(address => uint256) public nonces;
    /// @notice sourceChainId => nonce => delivered (exactly-once delivery).
    mapping(uint256 => mapping(uint256 => bool)) public delivered;

    struct OneTimeLock {
        address sender;
        address token;
        uint256 amount;
        uint256 timeout;
        bool settled;
        bool refunded;
    }
    /// @notice messageId => one-time lock.
    mapping(bytes32 => OneTimeLock) public oneTimeLocks;

    /// @notice messageId => announced message (destination chain).
    mapping(bytes32 => Types.CrossChainMessage) internal _announced;

    event PaymentInitiated(
        uint256 indexed nonce,
        uint256 indexed sourceChainId,
        uint256 indexed destChainId,
        bytes32 messageId
    );
    event PaymentReceived(
        uint256 indexed nonce, uint256 indexed sourceChainId, uint256 destChainId
    );
    event OneTimeRefunded(bytes32 indexed messageId, uint256 amount);

    constructor(uint256 _sourceChainId) {
        sourceChainId = _sourceChainId;
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert PaymentRouter__NotOwner();
        _;
    }

    modifier onlyBridge() {
        if (address(bridge) == address(0) || msg.sender != address(bridge)) {
            revert PaymentRouter__NotBridge();
        }
        _;
    }

    // ---- administration ----

    function setBridge(address _bridge) external onlyOwner {
        bridge = IBridgeAdapter(_bridge);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero owner");
        owner = newOwner;
    }

    // ---- internal helpers ----

    function _nextNonce(address sender) internal returns (uint256 nonce) {
        nonce = nonces[sender];
        nonces[sender] = nonce + 1;
    }

    function _buildAndSend(
        uint256 nonce,
        uint256 destChainId,
        bytes32 destToken,
        uint256 amount,
        address recipient,
        Types.PaymentMode mode,
        bytes memory metadata
    ) internal returns (bytes32 messageId) {
        if (address(bridge) == address(0)) revert PaymentRouter__NoBridge();

        Types.CrossChainMessage memory message = Types.CrossChainMessage({
            nonce: nonce,
            sourceChainId: sourceChainId,
            destChainId: destChainId,
            token: destToken,
            amount: amount,
            recipient: abi.encodePacked(recipient),
            mode: mode,
            metadata: metadata
        });

        bytes memory payload = abi.encode(message);
        bridge.sendMessage(payload, destChainId);
        messageId = keccak256(payload);
        emit PaymentInitiated(nonce, sourceChainId, destChainId, messageId);
    }

    // ---- one-time payments ----

    function sendPayment(
        address token,
        uint256 amount,
        bytes32 destToken,
        address recipient,
        uint256 destChainId,
        uint256 timeout
    ) external returns (bytes32 messageId) {
        if (amount == 0) revert PaymentRouter__ZeroAmount();
        if (recipient == address(0)) revert PaymentRouter__ZeroRecipient();
        if (timeout <= block.timestamp) revert PaymentRouter__TimeoutInPast();

        uint256 nonce = _nextNonce(msg.sender);
        messageId = _buildAndSend(
            nonce, destChainId, destToken, amount, recipient, Types.PaymentMode.OneTime,
            abi.encode(timeout)
        );

        bool ok = IERC20(token).transferFrom(msg.sender, address(this), amount);
        require(ok, "transfer failed");
        oneTimeLocks[messageId] = OneTimeLock({
            sender: msg.sender,
            token: token,
            amount: amount,
            timeout: timeout,
            settled: false,
            refunded: false
        });
    }

    /// @notice Sender recovers a one-time payment if it was never delivered.
    function refundOneTime(bytes32 messageId) external {
        OneTimeLock storage lock = oneTimeLocks[messageId];
        require(lock.sender == msg.sender, "not sender");
        require(!lock.settled, "already settled");
        require(!lock.refunded, "already refunded");
        require(block.timestamp > lock.timeout, "before timeout");

        lock.refunded = true;
        bool ok = IERC20(lock.token).transfer(msg.sender, lock.amount);
        require(ok, "refund failed");
        emit OneTimeRefunded(messageId, lock.amount);
    }

    // ---- streamed payments ----

    function streamPayment(
        address token,
        uint256 amount,
        bytes32 destToken,
        address recipient,
        uint256 destChainId,
        uint256 duration,
        uint256 timeout
    ) external returns (bytes32 messageId, address escrowAddress) {
        if (amount == 0) revert PaymentRouter__ZeroAmount();
        if (recipient == address(0)) revert PaymentRouter__ZeroRecipient();
        if (duration == 0) revert PaymentRouter__ZeroDuration();
        if (timeout <= block.timestamp) revert PaymentRouter__TimeoutInPast();

        uint256 ratePerSecond = amount / duration;
        uint256 nonce = _nextNonce(msg.sender);
        messageId = _buildAndSend(
            nonce, destChainId, destToken, amount, recipient, Types.PaymentMode.Stream,
            abi.encode(ratePerSecond, duration)
        );

        StreamEscrow escrow =
            new StreamEscrow(address(this), msg.sender, recipient, IERC20(token), amount, duration);
        bool ok = IERC20(token).transferFrom(msg.sender, address(escrow), amount);
        require(ok, "transfer failed");
        escrow.fund();
        escrowAddress = address(escrow);
    }

    // ---- milestone payments ----

    function createMilestonePayment(
        address token,
        uint256 amount,
        bytes32 destToken,
        address recipient,
        uint256 destChainId,
        uint256[] calldata trancheAmounts,
        Types.ApprovalMode approvalMode,
        address[] calldata approvers,
        uint256 threshold,
        address oracle,
        uint256 releaseDeadline,
        uint256 timeout
    ) external returns (bytes32 messageId, address escrowAddress) {
        if (amount == 0) revert PaymentRouter__ZeroAmount();
        if (recipient == address(0)) revert PaymentRouter__ZeroRecipient();
        if (timeout <= block.timestamp) revert PaymentRouter__TimeoutInPast();

        uint256 nonce = _nextNonce(msg.sender);
        messageId = _buildAndSend(
            nonce, destChainId, destToken, amount, recipient, Types.PaymentMode.Milestone,
            abi.encode(trancheAmounts, releaseDeadline)
        );

        MilestoneEscrow escrow = new MilestoneEscrow(
            address(this),
            msg.sender,
            recipient,
            IERC20(token),
            amount,
            trancheAmounts,
            approvalMode,
            approvers,
            threshold,
            oracle,
            releaseDeadline
        );
        bool ok = IERC20(token).transferFrom(msg.sender, address(escrow), amount);
        require(ok, "transfer failed");
        escrow.fund();
        escrowAddress = address(escrow);
    }

    // ---- destination chain: receive bridge messages ----

    /// @inheritdoc IBridgeReceiver
    function receiveMessage(bytes calldata payload) external onlyBridge {
        Types.CrossChainMessage memory message =
            abi.decode(payload, (Types.CrossChainMessage));

        if (message.destChainId != sourceChainId) revert PaymentRouter__WrongDestChain();
        if (delivered[message.sourceChainId][message.nonce]) revert PaymentRouter__Replay();

        delivered[message.sourceChainId][message.nonce] = true;
        bytes32 messageId = keccak256(payload);
        _announced[messageId] = message;

        emit PaymentReceived(message.nonce, message.sourceChainId, message.destChainId);
        emit MessageReceived(messageId, message.sourceChainId, message.destChainId);
    }

    /// @notice Mark a one-time payment as delivered (called by the bridge once
    /// the destination confirms delivery). Blocks the sender's timeout refund.
    function settleOneTime(bytes32 messageId) external onlyBridge {
        OneTimeLock storage lock = oneTimeLocks[messageId];
        require(lock.amount > 0, "unknown lock");
        lock.settled = true;
    }

    function announced(bytes32 messageId) external view returns (Types.CrossChainMessage memory) {
        return _announced[messageId];
    }
}
