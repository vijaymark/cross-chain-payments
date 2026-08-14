// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {AxelarBridgeAdapter} from "../src/AxelarBridgeAdapter.sol";

/// @notice Deploys the EVM PaymentRouter wired to an Axelar GMP gateway.
///
///   CHAIN_ID=1 AXELAR_GATEWAY=$GATEWAY forge script script/DeployAxelar.s.sol \
///       --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
///
/// After deployment, register destination chain config with `setChainConfig`
/// (the destination router address is not known until it is deployed).
contract DeployAxelar is Script {
    function run() external returns (PaymentRouter router, AxelarBridgeAdapter adapter) {
        uint256 chainId = vm.envUint("CHAIN_ID");
        address gateway = vm.envAddress("AXELAR_GATEWAY");

        vm.startBroadcast();

        router = new PaymentRouter(chainId);
        adapter = new AxelarBridgeAdapter(gateway);
        router.setBridge(address(adapter));
        adapter.setRouter(address(router));

        vm.stopBroadcast();

        console2.log("CHAIN_ID           :", chainId);
        console2.log("Axelar gateway     :", gateway);
        console2.log("PaymentRouter      :", address(router));
        console2.log("AxelarBridgeAdapter:", address(adapter));
    }
}
