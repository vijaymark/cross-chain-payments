// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @title SendTestStream
/// @notice End-to-end testnet helper: mints `MockUSDC` to the sender, approves
///         the router, quotes the LayerZero fee, and sends a streamed payment.
/// @dev    Required env: PRIVATE_KEY (sender), ROUTER_ADDRESS, TOKEN_ADDRESS,
///         RECIPIENT_ADDRESS, DST_EID, TOTAL_AMOUNT, PERIODS, PERIOD_DURATION.
///         Run against the SOURCE chain RPC.
contract SendTestStream is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address sender = vm.addr(pk);
        address router = vm.envAddress("ROUTER_ADDRESS");
        address token = vm.envAddress("TOKEN_ADDRESS");
        address recipient = vm.envAddress("RECIPIENT_ADDRESS");
        uint32 dstEid = uint32(vm.envUint("DST_EID"));
        uint256 totalAmount = vm.envUint("TOTAL_AMOUNT");
        uint32 periods = uint32(vm.envUint("PERIODS"));
        uint32 periodDuration = uint32(vm.envUint("PERIOD_DURATION"));

        vm.startBroadcast(pk);
        MockUSDC(token).mint(sender, totalAmount);
        MockUSDC(token).approve(router, totalAmount);

        uint256 fee = PaymentRouter(router)
            .quoteSendStreamedPayment(dstEid, recipient, token, totalAmount, periods, periodDuration);
        PaymentRouter(router).sendStreamedPayment{value: fee}(
            dstEid, recipient, token, totalAmount, periods, periodDuration
        );
        vm.stopBroadcast();

        console2.log(
            string.concat(
                "Sent stream ",
                vm.toString(totalAmount),
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
