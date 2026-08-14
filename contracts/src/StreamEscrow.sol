// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./IERC20.sol";

/// @notice Linear, per-second streamed payment (Superfluid/Sablier-style).
///
/// Funds are released to `recipient` at `ratePerSecond` from `startTime` until
/// `endTime`. The recipient may withdraw accrued funds at any time; the sender
/// may cancel with pro-rata settlement (recipient keeps accrued, sender recovers
/// the remainder).
///
/// Accounting invariant at all times:
///     recipient.withdrawn + sender.refund + escrow.balance == amount
///
/// The router transfers the exact `requestedAmount` into this contract and then
/// calls `fund()`, which refunds any dust caused by integer division so the
/// locked `amount` is always an exact multiple of `ratePerSecond`.
contract StreamEscrow {
    error StreamEscrow__NotRouter();
    error StreamEscrow__AlreadyFunded();
    error StreamEscrow__NotFunded();
    error StreamEscrow__Underfunded();
    error StreamEscrow__Cancelled();
    error StreamEscrow__NotSender();
    error StreamEscrow__NotRecipient();
    error StreamEscrow__NothingToWithdraw();
    error StreamEscrow__ZeroRouter();
    error StreamEscrow__ZeroSender();
    error StreamEscrow__ZeroRecipient();
    error StreamEscrow__ZeroDuration();
    error StreamEscrow__AmountBelowDuration();
    error StreamEscrow__TransferFailed();

    address public immutable router;
    address public immutable sender;
    address public immutable recipient;
    IERC20 public immutable token;

    /// @notice Total amount requested by the sender (includes any dust).
    uint256 public immutable requestedAmount;
    /// @notice Exact locked amount = ratePerSecond * duration (no dust).
    uint256 public immutable amount;
    uint256 public immutable ratePerSecond;
    uint256 public immutable startTime;
    uint256 public immutable endTime;

    bool public funded;
    bool public cancelled;
    uint256 public withdrawn;

    event StreamFunded(uint256 lockedAmount, uint256 remainderRefunded);
    event StreamWithdrawn(address indexed recipient, uint256 amount);
    event StreamCancelled(uint256 recipientShare, uint256 senderRefund);

    constructor(
        address _router,
        address _sender,
        address _recipient,
        IERC20 _token,
        uint256 _amount,
        uint256 _duration
    ) {
        if (_router == address(0)) revert StreamEscrow__ZeroRouter();
        if (_sender == address(0)) revert StreamEscrow__ZeroSender();
        if (_recipient == address(0)) revert StreamEscrow__ZeroRecipient();
        if (_duration == 0) revert StreamEscrow__ZeroDuration();
        if (_amount < _duration) revert StreamEscrow__AmountBelowDuration();

        router = _router;
        sender = _sender;
        recipient = _recipient;
        token = _token;
        requestedAmount = _amount;
        ratePerSecond = _amount / _duration;
        amount = ratePerSecond * _duration; // exact locked amount, no dust
        startTime = block.timestamp;
        endTime = startTime + _duration;
    }

    modifier onlyRouter() {
        if (msg.sender != router) revert StreamEscrow__NotRouter();
        _;
    }

    /// @notice Mark funded once the router has transferred `requestedAmount`.
    /// Refunds the division remainder back to the sender so accounting is exact.
    function fund() external onlyRouter {
        if (funded) revert StreamEscrow__AlreadyFunded();
        if (token.balanceOf(address(this)) < requestedAmount) revert StreamEscrow__Underfunded();

        funded = true;
        uint256 remainder = requestedAmount - amount;
        if (remainder > 0) {
            bool ok = token.transfer(sender, remainder);
            if (!ok) revert StreamEscrow__TransferFailed();
        }
        emit StreamFunded(amount, remainder);
    }

    /// @notice Total amount streamed as of `timestamp`, capped at `amount`.
    function streamedAt(uint256 timestamp) public view returns (uint256) {
        if (!funded || timestamp <= startTime) return 0;
        uint256 elapsed = timestamp - startTime;
        uint256 accrued = ratePerSecond * elapsed;
        return accrued > amount ? amount : accrued;
    }

    /// @notice Recipient's currently withdrawable amount.
    function releasableAt(uint256 timestamp) public view returns (uint256) {
        return streamedAt(timestamp) - withdrawn;
    }

    function releasableAmount() public view returns (uint256) {
        return releasableAt(block.timestamp);
    }

    /// @notice Sender-callable portion not yet streamed.
    function refundableAmount() public view returns (uint256) {
        return amount - streamedAt(block.timestamp);
    }

    /// @notice Recipient withdraws everything accrued so far.
    function withdraw() external {
        if (msg.sender != recipient) revert StreamEscrow__NotRecipient();
        if (!funded) revert StreamEscrow__NotFunded();
        if (cancelled) revert StreamEscrow__Cancelled();

        uint256 share = releasableAmount();
        if (share == 0) revert StreamEscrow__NothingToWithdraw();

        withdrawn += share;
        bool ok = token.transfer(recipient, share);
        if (!ok) revert StreamEscrow__TransferFailed();
        emit StreamWithdrawn(recipient, share);
    }

    /// @notice Sender cancels the stream: recipient keeps accrued share, sender
    /// recovers the not-yet-streamed remainder (pro-rata settlement).
    function cancel() external {
        if (msg.sender != sender) revert StreamEscrow__NotSender();
        if (!funded) revert StreamEscrow__NotFunded();
        if (cancelled) revert StreamEscrow__Cancelled();

        cancelled = true;
        uint256 recipientShare = releasableAmount();
        uint256 senderRefund = refundableAmount();

        if (recipientShare > 0) {
            withdrawn += recipientShare;
            bool ok = token.transfer(recipient, recipientShare);
            if (!ok) revert StreamEscrow__TransferFailed();
        }
        if (senderRefund > 0) {
            bool ok = token.transfer(sender, senderRefund);
            if (!ok) revert StreamEscrow__TransferFailed();
        }
        emit StreamCancelled(recipientShare, senderRefund);
    }
}
