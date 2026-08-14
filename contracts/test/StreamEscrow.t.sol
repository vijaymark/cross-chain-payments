// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StreamEscrow} from "../src/StreamEscrow.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

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
}
