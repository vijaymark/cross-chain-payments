// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";

/// @title SetPeers
/// @notice Wire the current chain's router to its peer on the other chain.
///         Run once per chain, AFTER both routers are deployed, with the
///         matching `--rpc-url`.
/// @dev    Sepolia run:   wires SEPOLIA_ROUTER_ADDR -> eid 40245 -> BASE_SEPOLIA_ROUTER_ADDR
///         Base run:      wires BASE_SEPOLIA_ROUTER_ADDR -> eid 40161 -> SEPOLIA_ROUTER_ADDR
///         Required env: PRIVATE_KEY, SEPOLIA_ROUTER_ADDR, BASE_SEPOLIA_ROUTER_ADDR.
contract SetPeers is Script {
    uint256 constant CHAIN_SEPOLIA = 11155111;
    uint256 constant CHAIN_BASE_SEPOLIA = 84532;
    uint32 constant EID_SEPOLIA = 40161;
    uint32 constant EID_BASE_SEPOLIA = 40245;

    function run() external {
        address localRouter;
        uint32 peerEid;
        address peerRouter;

        if (block.chainid == CHAIN_SEPOLIA) {
            localRouter = vm.envAddress("SEPOLIA_ROUTER_ADDR");
            peerEid = EID_BASE_SEPOLIA;
            peerRouter = vm.envAddress("BASE_SEPOLIA_ROUTER_ADDR");
        } else if (block.chainid == CHAIN_BASE_SEPOLIA) {
            localRouter = vm.envAddress("BASE_SEPOLIA_ROUTER_ADDR");
            peerEid = EID_SEPOLIA;
            peerRouter = vm.envAddress("SEPOLIA_ROUTER_ADDR");
        } else {
            revert("SetPeers: unsupported chain id");
        }

        bytes32 peer = bytes32(uint256(uint160(peerRouter)));

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        PaymentRouter(localRouter).setPeer(peerEid, peer);
        vm.stopBroadcast();

        console2.log(
            string.concat("setPeer(", vm.toString(peerEid), ", ", vm.toString(peer), ") on ", vm.toString(localRouter))
        );
    }
}
