// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AxelarBridgeAdapter} from "../src/AxelarBridgeAdapter.sol";
import {IBridgeAdapter, IBridgeReceiver} from "../src/IBridgeAdapter.sol";
import {MockAxelarGateway} from "./mocks/MockAxelarGateway.sol";

/// @notice Minimal router stand-in that records delivered payloads.
contract ReceiverMock {
    bytes public lastPayload;
    uint256 public receivedCount;

    function receiveMessage(bytes calldata payload) external {
        lastPayload = payload;
        receivedCount++;
    }
}

contract AxelarBridgeAdapterTest is Test {
    AxelarBridgeAdapter adapter;
    MockAxelarGateway gateway;
    ReceiverMock router;

    uint256 constant CHAIN_ID = 1500;
    string constant DEST_CHAIN = "stellar-2025-q1";
    string constant DEST_ROUTER = "CCSNWHMQSPTW4PS7L32OIMH7Z6NFNCKYZKNFSWRSYX7MK64KHBDZDT5I";
    string constant SOURCE_CHAIN = "ethereum-sepolia";

    bytes32 constant COMMAND_ID = keccak256("command-1");
    bytes PAYLOAD = hex"deadbeef";

    function setUp() public {
        gateway = new MockAxelarGateway();
        adapter = new AxelarBridgeAdapter(address(gateway));
        router = new ReceiverMock();

        adapter.setRouter(address(router));
        adapter.setChainConfig(CHAIN_ID, DEST_CHAIN, DEST_ROUTER);
    }

    function test_sendMessage_forwardsToGateway() public {
        vm.expectEmit(true, true, true, true);
        emit IBridgeAdapter.MessageSent(keccak256(PAYLOAD), CHAIN_ID, PAYLOAD);

        vm.prank(address(router));
        bytes32 deliveryId = adapter.sendMessage(PAYLOAD, CHAIN_ID);

        assertEq(deliveryId, keccak256(PAYLOAD), "deliveryId");
        (string memory destChain, string memory contractAddr, bytes memory payload) = gateway.calls(0);
        assertEq(destChain, DEST_CHAIN);
        assertEq(contractAddr, DEST_ROUTER);
        assertEq(payload, PAYLOAD);
    }

    function test_sendMessage_onlyRouter() public {
        vm.expectRevert(AxelarBridgeAdapter.AxelarBridgeAdapter__NotRouter.selector);
        adapter.sendMessage(PAYLOAD, CHAIN_ID);
    }

    function test_sendMessage_unknownChain() public {
        vm.prank(address(router));
        vm.expectRevert(AxelarBridgeAdapter.AxelarBridgeAdapter__UnknownChain.selector);
        adapter.sendMessage(PAYLOAD, 999);
    }

    function test_execute_forwardsToRouter() public {
        gateway.deliver(COMMAND_ID, SOURCE_CHAIN, DEST_ROUTER, address(adapter), PAYLOAD);

        assertEq(router.receivedCount(), 1, "received once");
        assertEq(router.lastPayload(), PAYLOAD, "payload forwarded");
        assertTrue(gateway.isCommandExecuted(COMMAND_ID), "command marked executed");
    }

    function test_execute_notApprovedReverts() public {
        vm.expectRevert();
        adapter.execute(COMMAND_ID, SOURCE_CHAIN, DEST_ROUTER, PAYLOAD);
    }

    function test_execute_replayReverts() public {
        gateway.deliver(COMMAND_ID, SOURCE_CHAIN, DEST_ROUTER, address(adapter), PAYLOAD);

        // The gateway marks the command executed, so a second delivery is rejected.
        vm.expectRevert();
        gateway.deliver(COMMAND_ID, SOURCE_CHAIN, DEST_ROUTER, address(adapter), PAYLOAD);
    }
}
