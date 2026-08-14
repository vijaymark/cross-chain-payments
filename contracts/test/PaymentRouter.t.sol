// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {MockBridgeAdapter} from "../src/MockBridgeAdapter.sol";
import {Types} from "../src/Types.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract PaymentRouterTest is Test {
    PaymentRouter sourceRouter; // chain 1 (Ethereum)
    PaymentRouter destRouter; // chain 1500 (Stellar/Soroban)
    MockBridgeAdapter bridge;
    MockERC20 token;

    address funder = address(0xF00D);
    address recipient = address(0xB0B);
    address stranger = address(0x5A0A);

    bytes32 constant DEST_TOKEN = bytes32(uint256(0xDEAD));
    uint256 constant SOURCE_CHAIN = 1;
    uint256 constant DEST_CHAIN = 1500;

    function setUp() public {
        sourceRouter = new PaymentRouter(SOURCE_CHAIN);
        destRouter = new PaymentRouter(DEST_CHAIN);
        bridge = new MockBridgeAdapter();
        bridge.setRouter(SOURCE_CHAIN, address(sourceRouter));
        bridge.setRouter(DEST_CHAIN, address(destRouter));
        sourceRouter.setBridge(address(bridge));
        destRouter.setBridge(address(bridge));

        token = new MockERC20();
        token.mint(funder, 1000 ether);
    }

    function _approve(uint256 amount) internal {
        vm.prank(funder);
        token.approve(address(sourceRouter), amount);
    }

    function _queuedPayload() internal view returns (bytes32 deliveryId, bytes memory payload) {
        deliveryId = bridge.queue(0);
        (payload,,) = bridge.outbox(deliveryId);
    }

    // ---- one-time ----

    function test_sendPayment_locksAndSends() public {
        _approve(100 ether);
        vm.prank(funder);
        bytes32 messageId = sourceRouter.sendPayment(
            address(token), 100 ether, DEST_TOKEN, recipient, DEST_CHAIN, block.timestamp + 100
        );

        assertEq(sourceRouter.nonces(funder), 1);
        assertEq(token.balanceOf(address(sourceRouter)), 100 ether);

        (address sender, address tok, uint256 amount, uint256 timeout, bool settled, bool refunded) =
            sourceRouter.oneTimeLocks(messageId);
        assertEq(sender, funder);
        assertEq(tok, address(token));
        assertEq(amount, 100 ether);
        assertGt(timeout, block.timestamp);
        assertFalse(settled);
        assertFalse(refunded);
    }

    function test_refundOneTime_afterTimeout() public {
        _approve(100 ether);
        vm.prank(funder);
        bytes32 messageId = sourceRouter.sendPayment(
            address(token), 100 ether, DEST_TOKEN, recipient, DEST_CHAIN, block.timestamp + 100
        );

        vm.warp(block.timestamp + 101);
        vm.prank(funder);
        sourceRouter.refundOneTime(messageId);

        assertEq(token.balanceOf(funder), 1000 ether);
        assertEq(token.balanceOf(address(sourceRouter)), 0);
    }

    function test_refundOneTime_beforeTimeoutReverts() public {
        _approve(100 ether);
        vm.prank(funder);
        bytes32 messageId = sourceRouter.sendPayment(
            address(token), 100 ether, DEST_TOKEN, recipient, DEST_CHAIN, block.timestamp + 100
        );

        vm.expectRevert(bytes("before timeout"));
        vm.prank(funder);
        sourceRouter.refundOneTime(messageId);
    }

    function test_refundOneTime_settledReverts() public {
        _approve(100 ether);
        vm.prank(funder);
        bytes32 messageId = sourceRouter.sendPayment(
            address(token), 100 ether, DEST_TOKEN, recipient, DEST_CHAIN, block.timestamp + 100
        );

        vm.prank(address(bridge));
        sourceRouter.settleOneTime(messageId); // destination confirmed delivery

        vm.warp(block.timestamp + 101);
        vm.expectRevert(bytes("already settled"));
        vm.prank(funder);
        sourceRouter.refundOneTime(messageId);
    }

    // ---- stream ----

    function test_streamPayment_createsFundedEscrow() public {
        _approve(100 ether);
        vm.prank(funder);
        (bytes32 messageId, address escrowAddress) = sourceRouter.streamPayment(
            address(token), 100 ether, DEST_TOKEN, recipient, DEST_CHAIN, 100, block.timestamp + 100
        );

        assertTrue(messageId != bytes32(0), "zero messageId");
        assertEq(token.balanceOf(escrowAddress), 100 ether);

        vm.warp(block.timestamp + 50);
        vm.prank(recipient);
        (bool ok,) = escrowAddress.call(abi.encodeWithSignature("withdraw()"));
        assertTrue(ok);
        assertEq(token.balanceOf(recipient), 50 ether);
    }

    // ---- milestone ----

    function test_createMilestonePayment_fullFlow() public {
        uint256[] memory tranches = new uint256[](2);
        tranches[0] = 60 ether;
        tranches[1] = 40 ether;
        address[] memory approvers = new address[](2);
        approvers[0] = address(0xA);
        approvers[1] = address(0xB);

        _approve(100 ether);
        vm.prank(funder);
        (bytes32 messageId, address escrowAddress) = sourceRouter.createMilestonePayment(
            address(token),
            100 ether,
            DEST_TOKEN,
            recipient,
            DEST_CHAIN,
            tranches,
            Types.ApprovalMode.Multisig,
            approvers,
            2,
            address(0),
            block.timestamp + 1000,
            block.timestamp + 100
        );

        assertTrue(messageId != bytes32(0), "zero messageId");
        assertEq(token.balanceOf(escrowAddress), 100 ether);

        vm.prank(approvers[0]);
        (bool ok0,) = escrowAddress.call(abi.encodeWithSignature("approveMilestone(uint256)", 0));
        assertTrue(ok0);
        vm.prank(approvers[1]);
        (bool ok1,) = escrowAddress.call(abi.encodeWithSignature("approveMilestone(uint256)", 0));
        assertTrue(ok1);
        (bool ok2,) = escrowAddress.call(abi.encodeWithSignature("releaseMilestone(uint256)", 0));
        assertTrue(ok2);

        assertEq(token.balanceOf(recipient), 60 ether);
    }

    // ---- receiveMessage ----

    function test_receiveMessage_deliversAndAnnounces() public {
        _approve(100 ether);
        vm.prank(funder);
        sourceRouter.sendPayment(address(token), 100 ether, DEST_TOKEN, recipient, DEST_CHAIN, block.timestamp + 100);

        (bytes32 deliveryId, bytes memory payload) = _queuedPayload();
        bridge.deliver(deliveryId);

        Types.CrossChainMessage memory msg1 = destRouter.announced(keccak256(payload));
        assertEq(msg1.amount, 100 ether);
        assertEq(uint256(msg1.mode), uint256(Types.PaymentMode.OneTime));
        assertTrue(destRouter.delivered(SOURCE_CHAIN, 0), "nonce 0 should be delivered");
        assertEq(bridge.pending(), 0);
    }

    function test_receiveMessage_replayReverts() public {
        _approve(100 ether);
        vm.prank(funder);
        sourceRouter.sendPayment(address(token), 100 ether, DEST_TOKEN, recipient, DEST_CHAIN, block.timestamp + 100);

        (bytes32 deliveryId, bytes memory payload) = _queuedPayload();
        bridge.deliver(deliveryId);

        vm.expectRevert(PaymentRouter.PaymentRouter__Replay.selector);
        vm.prank(address(bridge));
        destRouter.receiveMessage(payload);
    }

    function test_receiveMessage_wrongDestChainReverts() public {
        Types.CrossChainMessage memory message = Types.CrossChainMessage({
            nonce: 0,
            sourceChainId: SOURCE_CHAIN,
            destChainId: 999, // not this router's chain
            token: DEST_TOKEN,
            amount: 1 ether,
            recipient: abi.encodePacked(recipient),
            mode: Types.PaymentMode.OneTime,
            metadata: ""
        });

        vm.expectRevert(PaymentRouter.PaymentRouter__WrongDestChain.selector);
        vm.prank(address(bridge));
        destRouter.receiveMessage(abi.encode(message));
    }

    function test_receiveMessage_onlyBridge() public {
        Types.CrossChainMessage memory message = Types.CrossChainMessage({
            nonce: 0,
            sourceChainId: SOURCE_CHAIN,
            destChainId: DEST_CHAIN,
            token: DEST_TOKEN,
            amount: 1 ether,
            recipient: abi.encodePacked(recipient),
            mode: Types.PaymentMode.OneTime,
            metadata: ""
        });

        vm.expectRevert(PaymentRouter.PaymentRouter__NotBridge.selector);
        destRouter.receiveMessage(abi.encode(message));
    }

    function test_setBridge_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(PaymentRouter.PaymentRouter__NotOwner.selector);
        sourceRouter.setBridge(stranger);
    }
}
