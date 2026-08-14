// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StreamEscrow} from "../src/StreamEscrow.sol";
import {IERC20} from "../src/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FailingToken} from "./mocks/FailingToken.sol";

contract StreamEscrowTest is Test {
    MockERC20 token;
    StreamEscrow escrow;

    address sender = address(0xA11CE);
    address recipient = address(0xB0B);
    address stranger = address(0x5A0A);

    uint256 constant AMOUNT = 1000 ether;
    uint256 constant DURATION = 1000; // 1 ether / second

    function setUp() public {
        token = new MockERC20();
        _deployAndFund(AMOUNT, DURATION);
    }

    function _deployAndFund(uint256 amount, uint256 duration) internal {
        token.mint(sender, amount);
        escrow = new StreamEscrow(address(this), sender, recipient, token, amount, duration);
        vm.prank(sender);
        token.transfer(address(escrow), amount);
        escrow.fund();
    }

    function test_fund_locksExactAmount() public view {
        assertTrue(escrow.funded());
        assertEq(escrow.amount(), AMOUNT);
        assertEq(escrow.ratePerSecond(), AMOUNT / DURATION);
        assertEq(token.balanceOf(address(escrow)), AMOUNT);
    }

    function test_withdraw_nothingAtStart() public {
        vm.expectRevert(StreamEscrow.StreamEscrow__NothingToWithdraw.selector);
        vm.prank(recipient);
        escrow.withdraw();
    }

    function test_withdraw_fullAtEnd() public {
        vm.warp(block.timestamp + DURATION);
        vm.prank(recipient);
        escrow.withdraw();

        assertEq(token.balanceOf(recipient), AMOUNT);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(escrow.withdrawn(), AMOUNT);
    }

    function test_withdraw_partialMidStream() public {
        uint256 start = escrow.startTime();
        vm.warp(start + 250);
        vm.prank(recipient);
        escrow.withdraw();

        assertEq(token.balanceOf(recipient), 250 ether);
        assertEq(escrow.releasableAmount(), 0);

        vm.warp(start + 500);
        vm.prank(recipient);
        escrow.withdraw();
        assertEq(token.balanceOf(recipient), 500 ether);
    }

    function test_cancel_proRataSettlement() public {
        vm.warp(block.timestamp + 250);
        vm.prank(sender);
        escrow.cancel();

        assertTrue(escrow.cancelled());
        assertEq(token.balanceOf(recipient), 250 ether);
        assertEq(token.balanceOf(sender), 750 ether);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_cancel_thenWithdrawReverts() public {
        vm.warp(block.timestamp + 100);
        vm.prank(sender);
        escrow.cancel();

        vm.expectRevert(StreamEscrow.StreamEscrow__Cancelled.selector);
        vm.prank(recipient);
        escrow.withdraw();
    }

    function test_withdraw_notRecipientReverts() public {
        vm.warp(block.timestamp + 100);
        vm.expectRevert(StreamEscrow.StreamEscrow__NotRecipient.selector);
        escrow.withdraw();
    }

    function test_cancel_notSenderReverts() public {
        vm.expectRevert(StreamEscrow.StreamEscrow__NotSender.selector);
        escrow.cancel();
    }

    function test_fund_refundsDivisionDust() public {
        // 1000 tokens over 3 seconds → rate 333, locked 999.999…, dust 1 wei.
        uint256 amount = 1000 ether;
        uint256 duration = 3;
        token.mint(sender, amount);

        StreamEscrow e = new StreamEscrow(address(this), sender, recipient, token, amount, duration);
        vm.prank(sender);
        token.transfer(address(e), amount);
        e.fund();

        assertEq(e.amount(), (amount / duration) * duration);
        assertEq(token.balanceOf(sender), amount - e.amount()); // dust returned
    }

    function test_fund_onlyRouterReverts() public {
        StreamEscrow e = new StreamEscrow(address(this), sender, recipient, token, 100 ether, 100);
        vm.prank(stranger);
        vm.expectRevert(StreamEscrow.StreamEscrow__NotRouter.selector);
        e.fund();
    }

    function test_fund_alreadyFundedReverts() public {
        vm.expectRevert(StreamEscrow.StreamEscrow__AlreadyFunded.selector);
        escrow.fund();
    }

    function test_fund_underfundedReverts() public {
        StreamEscrow e = new StreamEscrow(address(this), sender, recipient, token, 100 ether, 100);
        vm.expectRevert(StreamEscrow.StreamEscrow__Underfunded.selector);
        e.fund();
    }

    function test_withdraw_notFundedReverts() public {
        StreamEscrow e = new StreamEscrow(address(this), sender, recipient, token, 100 ether, 100);
        vm.prank(recipient);
        vm.expectRevert(StreamEscrow.StreamEscrow__NotFunded.selector);
        e.withdraw();
    }

    function test_cancel_notFundedReverts() public {
        StreamEscrow e = new StreamEscrow(address(this), sender, recipient, token, 100 ether, 100);
        vm.prank(sender);
        vm.expectRevert(StreamEscrow.StreamEscrow__NotFunded.selector);
        e.cancel();
    }

    // ---- fuzz: stream math invariants ----

    function testFuzz_streamedAt_neverExceedsAmount(uint256 amount, uint256 duration, uint256 elapsed)
        public
    {
        duration = bound(duration, 1, 365 days);
        amount = bound(amount, duration, type(uint256).max / 2);
        elapsed = bound(elapsed, 0, duration);

        token.mint(sender, amount);
        StreamEscrow e = new StreamEscrow(address(this), sender, recipient, token, amount, duration);
        vm.prank(sender);
        token.transfer(address(e), amount);
        e.fund();

        uint256 streamed = e.streamedAt(block.timestamp + elapsed);
        assertLe(streamed, e.amount(), "streamed exceeds amount");
        assertLe(e.releasableAt(block.timestamp + elapsed), e.amount(), "releasable exceeds amount");
        assertLe(e.refundableAmount() + e.withdrawn(), e.amount(), "accounting overflow");
    }

    function testFuzz_withdraw_neverOverpays(uint256 amount, uint256 duration, uint256 elapsed) public {
        duration = bound(duration, 1, 365 days);
        amount = bound(amount, duration, type(uint256).max / 2);
        elapsed = bound(elapsed, 1, duration);

        token.mint(sender, amount);
        StreamEscrow e = new StreamEscrow(address(this), sender, recipient, token, amount, duration);
        vm.prank(sender);
        token.transfer(address(e), amount);
        e.fund();

        vm.warp(block.timestamp + elapsed);
        vm.prank(recipient);
        e.withdraw();

        assertLe(token.balanceOf(recipient), e.amount(), "recipient overpaid");
        assertEq(token.balanceOf(recipient) + token.balanceOf(address(e)) + token.balanceOf(sender), amount, "funds not conserved");
    }

    // ---- constructor guards ----

    function test_constructor_zeroRouterReverts() public {
        vm.expectRevert(StreamEscrow.StreamEscrow__ZeroRouter.selector);
        new StreamEscrow(address(0), sender, recipient, token, AMOUNT, DURATION);
    }

    function test_constructor_zeroSenderReverts() public {
        vm.expectRevert(StreamEscrow.StreamEscrow__ZeroSender.selector);
        new StreamEscrow(address(this), address(0), recipient, token, AMOUNT, DURATION);
    }

    function test_constructor_zeroRecipientReverts() public {
        vm.expectRevert(StreamEscrow.StreamEscrow__ZeroRecipient.selector);
        new StreamEscrow(address(this), sender, address(0), token, AMOUNT, DURATION);
    }

    function test_constructor_zeroDurationReverts() public {
        vm.expectRevert(StreamEscrow.StreamEscrow__ZeroDuration.selector);
        new StreamEscrow(address(this), sender, recipient, token, AMOUNT, 0);
    }

    function test_constructor_amountLessThanDurationReverts() public {
        vm.expectRevert(StreamEscrow.StreamEscrow__AmountBelowDuration.selector);
        new StreamEscrow(address(this), sender, recipient, token, 5, 10);
    }

    // ---- view guards ----

    function test_streamedAt_notFundedReturnsZero() public {
        StreamEscrow e = new StreamEscrow(address(this), sender, recipient, token, AMOUNT, DURATION);
        assertEq(e.streamedAt(block.timestamp + 500), 0);
        assertEq(e.releasableAmount(), 0);
        assertEq(e.refundableAmount(), e.amount());
    }

    // ---- cancel boundaries ----

    function test_cancel_twiceReverts() public {
        vm.prank(sender);
        escrow.cancel();

        vm.expectRevert(StreamEscrow.StreamEscrow__Cancelled.selector);
        vm.prank(sender);
        escrow.cancel();
    }

    function test_cancel_atStart_noRecipientShare() public {
        vm.prank(sender);
        escrow.cancel();

        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.balanceOf(sender), AMOUNT);
        assertEq(escrow.withdrawn(), 0);
    }

    function test_cancel_atEnd_noSenderRefund() public {
        vm.warp(block.timestamp + DURATION);
        vm.prank(sender);
        escrow.cancel();

        assertEq(token.balanceOf(recipient), AMOUNT);
        assertEq(token.balanceOf(sender), 0);
    }

    // ---- transfer-failure branches (failing token) ----

    function test_fund_refundTransferFailsReverts() public {
        FailingToken ft = new FailingToken();
        uint256 amount = 1000 ether;
        uint256 duration = 3;
        ft.mint(sender, amount);
        vm.prank(sender);
        ft.approve(address(this), amount);

        StreamEscrow e = new StreamEscrow(address(this), sender, recipient, IERC20(address(ft)), amount, duration);
        ft.transferFrom(sender, address(e), amount);

        vm.expectRevert(StreamEscrow.StreamEscrow__TransferFailed.selector);
        e.fund();
    }

    function test_withdraw_transferFailsReverts() public {
        FailingToken ft = new FailingToken();
        ft.mint(sender, AMOUNT);
        vm.prank(sender);
        ft.approve(address(this), AMOUNT);

        StreamEscrow e = new StreamEscrow(address(this), sender, recipient, IERC20(address(ft)), AMOUNT, DURATION);
        ft.transferFrom(sender, address(e), AMOUNT);
        e.fund();

        vm.warp(block.timestamp + 100);
        vm.prank(recipient);
        vm.expectRevert(StreamEscrow.StreamEscrow__TransferFailed.selector);
        e.withdraw();
    }

    function test_cancel_recipientShareTransferFailsReverts() public {
        FailingToken ft = new FailingToken();
        ft.mint(sender, AMOUNT);
        vm.prank(sender);
        ft.approve(address(this), AMOUNT);

        StreamEscrow e = new StreamEscrow(address(this), sender, recipient, IERC20(address(ft)), AMOUNT, DURATION);
        ft.transferFrom(sender, address(e), AMOUNT);
        e.fund();

        vm.warp(block.timestamp + 100);
        vm.prank(sender);
        vm.expectRevert(StreamEscrow.StreamEscrow__TransferFailed.selector);
        e.cancel();
    }

    function test_cancel_senderRefundTransferFailsReverts() public {
        FailingToken ft = new FailingToken();
        ft.mint(sender, AMOUNT);
        vm.prank(sender);
        ft.approve(address(this), AMOUNT);

        StreamEscrow e = new StreamEscrow(address(this), sender, recipient, IERC20(address(ft)), AMOUNT, DURATION);
        ft.transferFrom(sender, address(e), AMOUNT);
        e.fund();

        vm.prank(sender);
        vm.expectRevert(StreamEscrow.StreamEscrow__TransferFailed.selector);
        e.cancel();
    }
}
