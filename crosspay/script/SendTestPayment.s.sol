// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @title SendTestPayment
/// @notice End-to-end testnet helper: mints `MockUSDC` to the sender, approves
///         the router, quotes the LayerZero fee, and sends a direct payment.
/// @dev    Required env: PRIVATE_KEY (sender), ROUTER_ADDRESS, TOKEN_ADDRESS,
///         RECIPIENT_ADDRESS, DST_EID, AMOUNT. Run against the SOURCE chain RPC.
contract SendTestPayment is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address sender = vm.addr(pk);
        address router = vm.envAddress("ROUTER_ADDRESS");
        address token = vm.envAddress("TOKEN_ADDRESS");
        address recipient = vm.envAddress("RECIPIENT_ADDRESS");
        uint32 dstEid = uint32(vm.envUint("DST_EID"));
        uint256 amount = vm.envUint("AMOUNT");

        vm.startBroadcast(pk);
        MockUSDC(token).mint(sender, amount);
        MockUSDC(token).approve(router, amount);

        uint256 fee = PaymentRouter(router).quoteSendPayment(dstEid, recipient, token, amount);
        PaymentRouter(router).sendPayment{value: fee}(dstEid, recipient, token, amount);
        vm.stopBroadcast();

        console2.log(
            string.concat(
                "Sent direct payment ",
                vm.toString(amount),
                " -> ",
                vm.toString(recipient),
                " (eid ",
                vm.toString(dstEid),
                ", fee ",
                vm.toString(fee),
                ")"
            )
        );
    }
}
