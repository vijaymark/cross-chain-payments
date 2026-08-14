// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MilestoneEscrow} from "../src/MilestoneEscrow.sol";
import {Types} from "../src/Types.sol";
import {IERC20} from "../src/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FailingToken} from "./mocks/FailingToken.sol";

contract MilestoneEscrowTest is Test {
    MockERC20 token;
    MilestoneEscrow escrow;

    address sender = address(0xA11CE);
    address recipient = address(0xB0B);
    address approverA = address(0xA);
    address approverB = address(0xB);
    address approverC = address(0xC);
    address oracle = address(0x0ACC1E);
    address stranger = address(0x5A0A);

    uint256 constant AMOUNT = 100 ether;

    function setUp() public {
        token = new MockERC20();
    }

    function _tranches() internal pure returns (uint256[] memory t) {
        t = new uint256[](3);
        t[0] = 40 ether;
        t[1] = 30 ether;
        t[2] = 30 ether;
    }

    function _approvers() internal view returns (address[] memory a) {
        a = new address[](3);
        a[0] = approverA;
        a[1] = approverB;
        a[2] = approverC;
    }

    function _deploy(Types.ApprovalMode mode, uint256 threshold, address oracleAddr)
        internal
        returns (MilestoneEscrow e)
    {
        token.mint(sender, AMOUNT);
        e = new MilestoneEscrow(
            address(this),
            sender,
            recipient,
            token,
            AMOUNT,
            _tranches(),
            mode,
            mode == Types.ApprovalMode.Oracle ? new address[](0) : _approvers(),
            threshold,
            oracleAddr,
            block.timestamp + 1000
        );
        vm.prank(sender);
        token.transfer(address(e), AMOUNT);
        e.fund();
    }

    function test_multisig_releaseAfterThreshold() public {
        escrow = _deploy(Types.ApprovalMode.Multisig, 2, address(0));

        vm.prank(approverA);
        escrow.approveMilestone(0);
        vm.prank(approverB);
        escrow.approveMilestone(0);

        escrow.releaseMilestone(0);
        assertEq(token.balanceOf(recipient), 40 ether);
        assertEq(escrow.releasedAmount(), 40 ether);
        assertTrue(escrow.trancheReleased(0));
    }

    function test_multisig_releaseBeforeThresholdReverts() public {
        escrow = _deploy(Types.ApprovalMode.Multisig, 2, address(0));

        vm.prank(approverA);
        escrow.approveMilestone(0);

        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__InsufficientApprovals.selector);
        escrow.releaseMilestone(0);
    }

    function test_multisig_idempotentApproval() public {
        escrow = _deploy(Types.ApprovalMode.Multisig, 2, address(0));

        vm.prank(approverA);
        escrow.approveMilestone(0);
        vm.prank(approverA);
        escrow.approveMilestone(0); // second is a no-op
        assertEq(escrow.trancheApprovalCount(0), 1);

        vm.prank(approverB);
        escrow.approveMilestone(0);
        escrow.releaseMilestone(0);
    }

    function test_vote_majorityRelease() public {
        escrow = _deploy(Types.ApprovalMode.Vote, 0, address(0));
        assertEq(escrow.threshold(), 2); // majority of 3

        vm.prank(approverA);
        escrow.approveMilestone(1);
        vm.prank(approverB);
        escrow.approveMilestone(1);
        escrow.releaseMilestone(1);

        assertEq(token.balanceOf(recipient), 30 ether);
    }

    function test_oracle_attestAndRelease() public {
        escrow = _deploy(Types.ApprovalMode.Oracle, 0, oracle);

        vm.prank(oracle);
        escrow.attestMilestone(2);
        escrow.releaseMilestone(2);

        assertEq(token.balanceOf(recipient), 30 ether);
    }

    function test_oracle_notOracleReverts() public {
        escrow = _deploy(Types.ApprovalMode.Oracle, 0, oracle);

        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__NotOracle.selector);
        escrow.attestMilestone(0);
    }

    function test_timeoutRefund_recoversUnreleased() public {
        escrow = _deploy(Types.ApprovalMode.Multisig, 2, address(0));

        vm.prank(approverA);
        escrow.approveMilestone(0);
        vm.prank(approverB);
        escrow.approveMilestone(0);
        escrow.releaseMilestone(0); // release 40

        vm.warp(block.timestamp + 1001);
        vm.prank(sender);
        escrow.claimTimeoutRefund();

        assertTrue(escrow.cancelled());
        assertEq(token.balanceOf(sender), 60 ether); // 100 - 40 released
    }

    function test_timeoutRefund_beforeDeadlineReverts() public {
        escrow = _deploy(Types.ApprovalMode.Multisig, 2, address(0));

        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__BeforeDeadline.selector);
        vm.prank(sender);
        escrow.claimTimeoutRefund();
    }

    function test_cannotReleaseAfterCancelled() public {
        escrow = _deploy(Types.ApprovalMode.Multisig, 2, address(0));

        vm.prank(approverA);
        escrow.approveMilestone(0);
        vm.prank(approverB);
        escrow.approveMilestone(0);

        vm.warp(block.timestamp + 1001);
        vm.prank(sender);
        escrow.claimTimeoutRefund();

        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__AlreadyCancelled.selector);
        escrow.releaseMilestone(0);
    }

    function test_constructor_rejectsTrancheMismatch() public {
        token.mint(sender, AMOUNT);
        uint256[] memory bad = new uint256[](2);
        bad[0] = 40 ether;
        bad[1] = 40 ether; // sums to 80 != 100

        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__TrancheMismatch.selector);
        new MilestoneEscrow(
            address(this),
            sender,
            recipient,
            token,
            AMOUNT,
            bad,
            Types.ApprovalMode.Multisig,
            _approvers(),
            2,
            address(0),
            block.timestamp + 1000
        );
    }

    function test_status_transitions() public {
        escrow = _deploy(Types.ApprovalMode.Multisig, 2, address(0));
        assertEq(escrow.status(), 2); // PendingMilestone

        vm.prank(approverA);
        escrow.approveMilestone(0);
        vm.prank(approverB);
        escrow.approveMilestone(0);
        escrow.releaseMilestone(0);
        assertEq(escrow.status(), 3); // PartiallyReleased
    }

    function test_fund_alreadyFundedReverts() public {
        escrow = _deploy(Types.ApprovalMode.Multisig, 2, address(0));
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__AlreadyFunded.selector);
        escrow.fund();
    }

    function test_fund_onlyRouterReverts() public {
        token.mint(sender, AMOUNT);
        MilestoneEscrow e = new MilestoneEscrow(
            address(this), sender, recipient, token, AMOUNT, _tranches(),
            Types.ApprovalMode.Multisig, _approvers(), 2, address(0), block.timestamp + 1000
        );
        vm.prank(stranger);
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__NotRouter.selector);
        e.fund();
    }

    function test_approveMilestone_notApproverReverts() public {
        escrow = _deploy(Types.ApprovalMode.Multisig, 2, address(0));
        vm.prank(stranger);
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__NotApprover.selector);
        escrow.approveMilestone(0);
    }

    function test_approveMilestone_invalidTrancheReverts() public {
        escrow = _deploy(Types.ApprovalMode.Multisig, 2, address(0));
        vm.prank(approverA);
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__InvalidTranche.selector);
        escrow.approveMilestone(3);
    }

    function test_releaseMilestone_notFundedReverts() public {
        token.mint(sender, AMOUNT);
        MilestoneEscrow e = new MilestoneEscrow(
            address(this), sender, recipient, token, AMOUNT, _tranches(),
            Types.ApprovalMode.Multisig, _approvers(), 2, address(0), block.timestamp + 1000
        );
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__NotFunded.selector);
        e.releaseMilestone(0);
    }

    function test_releaseMilestone_alreadyReleasedReverts() public {
        escrow = _deploy(Types.ApprovalMode.Multisig, 2, address(0));
        vm.prank(approverA);
        escrow.approveMilestone(0);
        vm.prank(approverB);
        escrow.approveMilestone(0);
        escrow.releaseMilestone(0);

        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__AlreadyReleased.selector);
        escrow.releaseMilestone(0);
    }

    function test_claimTimeoutRefund_notSenderReverts() public {
        escrow = _deploy(Types.ApprovalMode.Multisig, 2, address(0));
        vm.warp(block.timestamp + 1001);
        vm.prank(stranger);
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__NotSender.selector);
        escrow.claimTimeoutRefund();
    }

    // ---- constructor guards ----

    function test_constructor_zeroRouterReverts() public {
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__ZeroRouter.selector);
        new MilestoneEscrow(address(0), sender, recipient, token, AMOUNT, _tranches(), Types.ApprovalMode.Multisig, _approvers(), 2, address(0), block.timestamp + 1000);
    }

    function test_constructor_zeroSenderReverts() public {
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__ZeroSender.selector);
        new MilestoneEscrow(address(this), address(0), recipient, token, AMOUNT, _tranches(), Types.ApprovalMode.Multisig, _approvers(), 2, address(0), block.timestamp + 1000);
    }

    function test_constructor_zeroRecipientReverts() public {
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__ZeroRecipient.selector);
        new MilestoneEscrow(address(this), sender, address(0), token, AMOUNT, _tranches(), Types.ApprovalMode.Multisig, _approvers(), 2, address(0), block.timestamp + 1000);
    }

    function test_constructor_noTranchesReverts() public {
        uint256[] memory none = new uint256[](0);
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__NoTranches.selector);
        new MilestoneEscrow(address(this), sender, recipient, token, AMOUNT, none, Types.ApprovalMode.Multisig, _approvers(), 2, address(0), block.timestamp + 1000);
    }

    function test_constructor_deadlineInPastReverts() public {
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__DeadlineInPast.selector);
        new MilestoneEscrow(address(this), sender, recipient, token, AMOUNT, _tranches(), Types.ApprovalMode.Multisig, _approvers(), 2, address(0), block.timestamp);
    }

    function test_constructor_zeroTrancheReverts() public {
        uint256[] memory t = new uint256[](2);
        t[0] = 0;
        t[1] = AMOUNT;
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__ZeroTranche.selector);
        new MilestoneEscrow(address(this), sender, recipient, token, AMOUNT, t, Types.ApprovalMode.Multisig, _approvers(), 2, address(0), block.timestamp + 1000);
    }

    function test_constructor_zeroOracleReverts() public {
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__ZeroOracle.selector);
        new MilestoneEscrow(address(this), sender, recipient, token, AMOUNT, _tranches(), Types.ApprovalMode.Oracle, new address[](0), 0, address(0), block.timestamp + 1000);
    }

    function test_constructor_noApproversReverts() public {
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__NoApprovers.selector);
        new MilestoneEscrow(address(this), sender, recipient, token, AMOUNT, _tranches(), Types.ApprovalMode.Multisig, new address[](0), 2, address(0), block.timestamp + 1000);
    }

    function test_constructor_zeroApproverReverts() public {
        address[] memory a = new address[](2);
        a[0] = address(0);
        a[1] = approverB;
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__ZeroApprover.selector);
        new MilestoneEscrow(address(this), sender, recipient, token, AMOUNT, _tranches(), Types.ApprovalMode.Multisig, a, 1, address(0), block.timestamp + 1000);
    }

    function test_constructor_dupApproverReverts() public {
        address[] memory a = new address[](2);
        a[0] = approverA;
        a[1] = approverA;
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__DuplicateApprover.selector);
        new MilestoneEscrow(address(this), sender, recipient, token, AMOUNT, _tranches(), Types.ApprovalMode.Multisig, a, 2, address(0), block.timestamp + 1000);
    }

    function test_constructor_badThresholdZeroReverts() public {
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__BadThreshold.selector);
        new MilestoneEscrow(address(this), sender, recipient, token, AMOUNT, _tranches(), Types.ApprovalMode.Multisig, _approvers(), 0, address(0), block.timestamp + 1000);
    }

    function test_constructor_badThresholdTooHighReverts() public {
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__BadThreshold.selector);
        new MilestoneEscrow(address(this), sender, recipient, token, AMOUNT, _tranches(), Types.ApprovalMode.Multisig, _approvers(), 4, address(0), block.timestamp + 1000);
    }

    // ---- fund guards ----

    function test_fund_underfundedReverts() public {
        token.mint(sender, AMOUNT);
        MilestoneEscrow e = new MilestoneEscrow(address(this), sender, recipient, token, AMOUNT, _tranches(), Types.ApprovalMode.Multisig, _approvers(), 2, address(0), block.timestamp + 1000);
        vm.prank(sender);
        token.transfer(address(e), AMOUNT - 1);
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__Underfunded.selector);
        e.fund();
    }

    // ---- approveMilestone guards ----

    function test_approveMilestone_oracleModeReverts() public {
        escrow = _deploy(Types.ApprovalMode.Oracle, 0, oracle);
        vm.prank(oracle);
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__NotApprover.selector);
        escrow.approveMilestone(0);
    }

    function test_approveMilestone_alreadyReleasedReverts() public {
        escrow = _deploy(Types.ApprovalMode.Multisig, 1, address(0));
        vm.prank(approverA);
        escrow.approveMilestone(0);
        escrow.releaseMilestone(0);

        vm.prank(approverB);
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__AlreadyReleased.selector);
        escrow.approveMilestone(0);
    }

    function test_approveMilestone_afterCancelReverts() public {
        escrow = _deploy(Types.ApprovalMode.Multisig, 2, address(0));
        vm.warp(block.timestamp + 1001);
        vm.prank(sender);
        escrow.claimTimeoutRefund();

        vm.prank(approverA);
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__AlreadyCancelled.selector);
        escrow.approveMilestone(0);
    }

    // ---- attestMilestone guards ----

    function test_attestMilestone_invalidTrancheReverts() public {
        escrow = _deploy(Types.ApprovalMode.Oracle, 0, oracle);
        vm.prank(oracle);
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__InvalidTranche.selector);
        escrow.attestMilestone(3);
    }

    function test_attestMilestone_nonOracleModeReverts() public {
        escrow = _deploy(Types.ApprovalMode.Multisig, 2, address(0));
        vm.prank(approverA);
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__NotOracle.selector);
        escrow.attestMilestone(0);
    }

    function test_attestMilestone_alreadyReleasedReverts() public {
        escrow = _deploy(Types.ApprovalMode.Oracle, 0, oracle);
        vm.prank(oracle);
        escrow.attestMilestone(0);
        escrow.releaseMilestone(0);

        vm.prank(oracle);
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__AlreadyReleased.selector);
        escrow.attestMilestone(0);
    }

    function test_attestMilestone_afterCancelReverts() public {
        escrow = _deploy(Types.ApprovalMode.Oracle, 0, oracle);
        vm.warp(block.timestamp + 1001);
        vm.prank(sender);
        escrow.claimTimeoutRefund();

        vm.prank(oracle);
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__AlreadyCancelled.selector);
        escrow.attestMilestone(0);
    }

    function test_attestMilestone_idempotent() public {
        escrow = _deploy(Types.ApprovalMode.Oracle, 0, oracle);
        vm.prank(oracle);
        escrow.attestMilestone(0);
        vm.prank(oracle);
        escrow.attestMilestone(0); // no-op
        assertTrue(escrow.trancheAttested(0));
    }

    // ---- releaseMilestone guards ----

    function test_releaseMilestone_invalidTrancheReverts() public {
        escrow = _deploy(Types.ApprovalMode.Multisig, 2, address(0));
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__InvalidTranche.selector);
        escrow.releaseMilestone(3);
    }

    function test_releaseMilestone_oracleNotAttestedReverts() public {
        escrow = _deploy(Types.ApprovalMode.Oracle, 0, oracle);
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__InsufficientApprovals.selector);
        escrow.releaseMilestone(0);
    }

    // ---- claimTimeoutRefund guards ----

    function test_claimTimeoutRefund_afterCancelReverts() public {
        escrow = _deploy(Types.ApprovalMode.Multisig, 2, address(0));
        vm.warp(block.timestamp + 1001);
        vm.prank(sender);
        escrow.claimTimeoutRefund();

        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__AlreadyCancelled.selector);
        vm.prank(sender);
        escrow.claimTimeoutRefund();
    }

    function test_claimTimeoutRefund_notFundedReverts() public {
        token.mint(sender, AMOUNT);
        MilestoneEscrow e = new MilestoneEscrow(address(this), sender, recipient, token, AMOUNT, _tranches(), Types.ApprovalMode.Multisig, _approvers(), 2, address(0), block.timestamp + 1000);
        vm.warp(block.timestamp + 1001);
        vm.prank(sender);
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__NotFunded.selector);
        e.claimTimeoutRefund();
    }

    function test_claimTimeoutRefund_fullRelease_noRefund() public {
        escrow = _deploy(Types.ApprovalMode.Multisig, 1, address(0));
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(approverA);
            escrow.approveMilestone(i);
            escrow.releaseMilestone(i);
        }
        assertEq(escrow.releasedAmount(), AMOUNT);

        vm.warp(block.timestamp + 1001);
        vm.prank(sender);
        escrow.claimTimeoutRefund(); // refund = 0

        assertTrue(escrow.cancelled());
        assertEq(token.balanceOf(sender), 0);
    }

    // ---- status + counters ----

    function test_status_created() public {
        token.mint(sender, AMOUNT);
        MilestoneEscrow e = new MilestoneEscrow(address(this), sender, recipient, token, AMOUNT, _tranches(), Types.ApprovalMode.Multisig, _approvers(), 2, address(0), block.timestamp + 1000);
        assertEq(e.status(), 0); // Created
    }

    function test_status_cancelled() public {
        escrow = _deploy(Types.ApprovalMode.Multisig, 2, address(0));
        vm.warp(block.timestamp + 1001);
        vm.prank(sender);
        escrow.claimTimeoutRefund();
        assertEq(escrow.status(), 5); // Cancelled
    }

    function test_status_completed() public {
        escrow = _deploy(Types.ApprovalMode.Multisig, 1, address(0));
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(approverA);
            escrow.approveMilestone(i);
            escrow.releaseMilestone(i);
        }
        assertEq(escrow.status(), 4); // Completed
    }

    function test_tranchesReleasedCount() public {
        escrow = _deploy(Types.ApprovalMode.Multisig, 1, address(0));
        assertEq(escrow.tranchesReleasedCount(), 0);
        vm.prank(approverA);
        escrow.approveMilestone(0);
        escrow.releaseMilestone(0);
        assertEq(escrow.tranchesReleasedCount(), 1);
    }

    // ---- transfer-failure branches (failing token) ----

    function _deployWithFailingToken()
        internal
        returns (MilestoneEscrow e, FailingToken ft)
    {
        ft = new FailingToken();
        ft.mint(sender, AMOUNT);
        vm.prank(sender);
        ft.approve(address(this), AMOUNT);

        e = new MilestoneEscrow(
            address(this),
            sender,
            recipient,
            IERC20(address(ft)),
            AMOUNT,
            _tranches(),
            Types.ApprovalMode.Multisig,
            _approvers(),
            1,
            address(0),
            block.timestamp + 1000
        );
        ft.transferFrom(sender, address(e), AMOUNT);
        e.fund();
    }

    function test_releaseMilestone_transferFailsReverts() public {
        (MilestoneEscrow e,) = _deployWithFailingToken();
        vm.prank(approverA);
        e.approveMilestone(0);
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__TransferFailed.selector);
        e.releaseMilestone(0);
    }

    function test_claimTimeoutRefund_transferFailsReverts() public {
        (MilestoneEscrow e,) = _deployWithFailingToken();
        vm.warp(block.timestamp + 1001);
        vm.prank(sender);
        vm.expectRevert(MilestoneEscrow.MilestoneEscrow__TransferFailed.selector);
        e.claimTimeoutRefund();
    }
}
