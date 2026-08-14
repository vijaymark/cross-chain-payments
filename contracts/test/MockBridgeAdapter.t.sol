// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockBridgeAdapter} from "../src/MockBridgeAdapter.sol";

contract ReceiverMock {
    uint256 public received;

    function receiveMessage(bytes calldata) external {
        received++;
    }
}

contract MockBridgeAdapterTest is Test {
    MockBridgeAdapter bridge;
    ReceiverMock receiver;
    address stranger = address(0x5A0A);

    function setUp() public {
        bridge = new MockBridgeAdapter();
        receiver = new ReceiverMock();
    }

    function test_setRouter_notOwnerReverts() public {
        vm.prank(stranger);
        vm.expectRevert(MockBridgeAdapter.MockBridge__NotOwner.selector);
        bridge.setRouter(1, address(receiver));
    }

    function test_deliver_notQueuedReverts() public {
        vm.expectRevert(MockBridgeAdapter.MockBridge__NotQueued.selector);
        bridge.deliver(bytes32(uint256(0xDEADBEEF)));
    }

    function test_deliver_noRouterReverts() public {
        bytes32 deliveryId = bridge.sendMessage(hex"deadbeef", 1);
        vm.expectRevert(MockBridgeAdapter.MockBridge__NoRouter.selector);
        bridge.deliver(deliveryId);
    }

    function test_deliver_alreadyDeliveredReverts() public {
        bridge.setRouter(1, address(receiver));
        bytes32 deliveryId = bridge.sendMessage(hex"deadbeef", 1);
        bridge.deliver(deliveryId);
        assertEq(receiver.received(), 1);

        vm.expectRevert(MockBridgeAdapter.MockBridge__AlreadyDelivered.selector);
        bridge.deliver(deliveryId);
    }

    function test_pending_countsUndelivered() public {
        bridge.sendMessage(hex"aaaa", 1);
        bridge.sendMessage(hex"bbbb", 1);
        assertEq(bridge.pending(), 2);

        bridge.setRouter(1, address(receiver));
        bridge.deliver(bridge.queue(0));
        assertEq(bridge.pending(), 1);
    }
}
