// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @title Deploy
/// @notice Deploys `MockUSDC` + `PaymentRouter` on one chain. Run once per chain
///         with the matching `--rpc-url`; the LayerZero endpoint is chosen from
///         `block.chainid`.
/// @dev    Required env: PRIVATE_KEY, OWNER, LZ_ENDPOINT_SEPOLIA (when on
///         Sepolia) or LZ_ENDPOINT_BASE_SEPOLIA (when on Base Sepolia).
contract Deploy is Script {
    uint256 constant CHAIN_SEPOLIA = 11155111;
    uint256 constant CHAIN_BASE_SEPOLIA = 84532;

    function run() external {
        address endpoint = _endpoint();
        address owner = vm.envAddress("OWNER");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        MockUSDC token = new MockUSDC();
        PaymentRouter router = new PaymentRouter(endpoint, owner);
        router.setSupportedToken(address(token), true);

        vm.stopBroadcast();

        console2.log("MockUSDC:      ", address(token));
        console2.log("PaymentRouter: ", address(router));
        console2.log("  -> paste these into .env (SEPOLIA_USDC_ADDR / BASE_SEPOLIA_USDC_ADDR and");
        console2.log("     SEPOLIA_ROUTER_ADDR / BASE_SEPOLIA_ROUTER_ADDR) before wiring peers.");
    }

    function _endpoint() internal view returns (address) {
        uint256 chainId = block.chainid;
        if (chainId == CHAIN_SEPOLIA) return vm.envAddress("LZ_ENDPOINT_SEPOLIA");
        if (chainId == CHAIN_BASE_SEPOLIA) return vm.envAddress("LZ_ENDPOINT_BASE_SEPOLIA");
        revert("Deploy: unsupported chain id");
    }
}
