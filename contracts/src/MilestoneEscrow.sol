// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./IERC20.sol";
import {Types} from "./Types.sol";

/// @notice Tranche-based escrow for grant disbursement. Funds are released in
/// tranches once approved via multisig, DAO vote, or oracle attestation. A
/// timeout fallback lets the sender recover unreleased funds after
/// `releaseDeadline`.
contract MilestoneEscrow {
    error MilestoneEscrow__NotRouter();
    error MilestoneEscrow__AlreadyFunded();
    error MilestoneEscrow__NotFunded();
    error MilestoneEscrow__Underfunded();
    error MilestoneEscrow__NotApprover();
    error MilestoneEscrow__NotOracle();
    error MilestoneEscrow__NotSender();
    error MilestoneEscrow__AlreadyReleased();
    error MilestoneEscrow__InsufficientApprovals();
    error MilestoneEscrow__InvalidTranche();
    error MilestoneEscrow__BeforeDeadline();
    error MilestoneEscrow__AlreadyCancelled();

    address public immutable router;
    address public immutable sender;
    address public immutable recipient;
    IERC20 public immutable token;
    Types.ApprovalMode public immutable mode;
    address public immutable oracle;

    uint256 public immutable amount;
    uint256 public immutable trancheCount;
    uint256 public immutable releaseDeadline;

    uint256[] public trancheAmounts;
    mapping(uint256 => bool) public trancheReleased;
    mapping(uint256 => uint256) public trancheApprovalCount;
    mapping(uint256 => mapping(address => bool)) public trancheApprovedBy;
    mapping(uint256 => bool) public trancheAttested;

    address[] public approvers;
    mapping(address => bool) public isApprover;
    uint256 public threshold;

    bool public funded;
    bool public cancelled;
    uint256 public releasedAmount;

    event MilestoneFunded(uint256 amount);
    event MilestoneApproved(uint256 indexed tranche, address indexed approver, uint256 approvals);
    event MilestoneAttested(uint256 indexed tranche, address indexed oracle);
    event MilestoneReleased(uint256 indexed tranche, uint256 amount);
    event MilestoneCancelled(uint256 refundedAmount);

    constructor(
        address _router,
        address _sender,
        address _recipient,
        IERC20 _token,
        uint256 _amount,
        uint256[] memory _trancheAmounts,
        Types.ApprovalMode _mode,
        address[] memory _approvers,
        uint256 _threshold,
        address _oracle,
        uint256 _releaseDeadline
    ) {
        require(_router != address(0), "zero router");
        require(_sender != address(0), "zero sender");
        require(_recipient != address(0), "zero recipient");
        require(_trancheAmounts.length > 0, "no tranches");
        require(_releaseDeadline > block.timestamp, "deadline in past");

        uint256 sum;
        for (uint256 i = 0; i < _trancheAmounts.length; i++) {
            require(_trancheAmounts[i] > 0, "zero tranche");
            sum += _trancheAmounts[i];
            trancheAmounts.push(_trancheAmounts[i]);
        }
        require(sum == _amount, "tranches != amount");

        router = _router;
        sender = _sender;
        recipient = _recipient;
        token = _token;
        amount = _amount;
        trancheCount = _trancheAmounts.length;
        releaseDeadline = _releaseDeadline;
        mode = _mode;
        oracle = _oracle;

        if (_mode == Types.ApprovalMode.Oracle) {
            require(_oracle != address(0), "zero oracle");
        } else {
            require(_approvers.length > 0, "no approvers");
            for (uint256 i = 0; i < _approvers.length; i++) {
                require(_approvers[i] != address(0), "zero approver");
                require(!isApprover[_approvers[i]], "dup approver");
                isApprover[_approvers[i]] = true;
                approvers.push(_approvers[i]);
            }
            if (_mode == Types.ApprovalMode.Multisig) {
                require(_threshold > 0 && _threshold <= _approvers.length, "bad threshold");
                threshold = _threshold;
            } else {
                // Vote: simple majority of the voter set.
                threshold = _approvers.length / 2 + 1;
            }
        }
    }

    modifier onlyRouter() {
        if (msg.sender != router) revert MilestoneEscrow__NotRouter();
        _;
    }

    /// @notice Mark funded once the router has transferred the full `amount`.
    function fund() external onlyRouter {
        if (funded) revert MilestoneEscrow__AlreadyFunded();
        if (token.balanceOf(address(this)) < amount) revert MilestoneEscrow__Underfunded();
        funded = true;
        emit MilestoneFunded(amount);
    }

    /// @notice Record an approval for tranche `index` (multisig / vote modes).
    function approveMilestone(uint256 index) external {
        if (index >= trancheCount) revert MilestoneEscrow__InvalidTranche();
        if (!isApprover[msg.sender]) revert MilestoneEscrow__NotApprover();
        if (mode == Types.ApprovalMode.Oracle) revert MilestoneEscrow__NotApprover();
        if (trancheReleased[index]) revert MilestoneEscrow__AlreadyReleased();
        if (cancelled) revert MilestoneEscrow__AlreadyCancelled();
        if (trancheApprovedBy[index][msg.sender]) return; // idempotent

        trancheApprovedBy[index][msg.sender] = true;
        trancheApprovalCount[index]++;
        emit MilestoneApproved(index, msg.sender, trancheApprovalCount[index]);
    }

    /// @notice Oracle attestation that a tranche is complete (oracle mode only).
    function attestMilestone(uint256 index) external {
        if (index >= trancheCount) revert MilestoneEscrow__InvalidTranche();
        if (mode != Types.ApprovalMode.Oracle || msg.sender != oracle) {
            revert MilestoneEscrow__NotOracle();
        }
        if (trancheReleased[index]) revert MilestoneEscrow__AlreadyReleased();
        if (cancelled) revert MilestoneEscrow__AlreadyCancelled();
        if (trancheAttested[index]) return; // idempotent

        trancheAttested[index] = true;
        emit MilestoneAttested(index, msg.sender);
    }

    /// @notice Release tranche `index` to the recipient once approved/attested.
    function releaseMilestone(uint256 index) external {
        if (index >= trancheCount) revert MilestoneEscrow__InvalidTranche();
        if (trancheReleased[index]) revert MilestoneEscrow__AlreadyReleased();
        if (cancelled) revert MilestoneEscrow__AlreadyCancelled();
        if (!funded) revert MilestoneEscrow__NotFunded();

        if (mode == Types.ApprovalMode.Oracle) {
            if (!trancheAttested[index]) revert MilestoneEscrow__InsufficientApprovals();
        } else {
            if (trancheApprovalCount[index] < threshold) {
                revert MilestoneEscrow__InsufficientApprovals();
            }
        }

        trancheReleased[index] = true;
        releasedAmount += trancheAmounts[index];
        bool ok = token.transfer(recipient, trancheAmounts[index]);
        require(ok, "release failed");
        emit MilestoneReleased(index, trancheAmounts[index]);
    }

    /// @notice Timeout fallback: sender recovers unreleased funds after the deadline.
    function claimTimeoutRefund() external {
        if (msg.sender != sender) revert MilestoneEscrow__NotSender();
        if (block.timestamp < releaseDeadline) revert MilestoneEscrow__BeforeDeadline();
        if (cancelled) revert MilestoneEscrow__AlreadyCancelled();
        if (!funded) revert MilestoneEscrow__NotFunded();

        cancelled = true;
        uint256 refund = amount - releasedAmount;
        if (refund > 0) {
            bool ok = token.transfer(sender, refund);
            require(ok, "refund failed");
        }
        emit MilestoneCancelled(refund);
    }

    function unreleasedAmount() external view returns (uint256) {
        return amount - releasedAmount;
    }

    function tranchesReleasedCount() external view returns (uint256) {
        uint256 count;
        for (uint256 i = 0; i < trancheCount; i++) {
            if (trancheReleased[i]) count++;
        }
        return count;
    }

    /// @notice Derive the escrow state for off-chain status queries.
    function status() external view returns (uint8) {
        if (!funded) return 0; // Created
        if (cancelled) return 5; // Cancelled
        if (releasedAmount == amount) return 4; // Completed
        if (releasedAmount > 0) return 3; // PartiallyReleased
        return 2; // PendingMilestone
    }
}
