// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MilestoneEscrow} from "../src/MilestoneEscrow.sol";
import {Types} from "../src/Types.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

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

        vm.expectRevert(bytes("tranches != amount"));
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
}
