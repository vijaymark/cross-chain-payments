// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {MockBridgeAdapter} from "../src/MockBridgeAdapter.sol";

/// @notice Deploys the EVM PaymentRouter and MockBridgeAdapter, then wires them
/// together. Usage:
///
///   CHAIN_ID=1 forge script script/Deploy.s.sol --rpc-url $RPC_URL \
///       --private-key $PRIVATE_KEY --broadcast
contract Deploy is Script {
    function run() external returns (PaymentRouter router, MockBridgeAdapter bridge) {
        uint256 chainId = vm.envUint("CHAIN_ID");

        vm.startBroadcast();

        router = new PaymentRouter(chainId);
        bridge = new MockBridgeAdapter();
        router.setBridge(address(bridge));
        bridge.setRouter(chainId, address(router));

        vm.stopBroadcast();

        console2.log("CHAIN_ID          :", chainId);
        console2.log("PaymentRouter     :", address(router));
        console2.log("MockBridgeAdapter :", address(bridge));
    }
}
