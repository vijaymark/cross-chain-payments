// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPaymentRouter} from "../../src/interfaces/IPaymentRouter.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";

/// @title MaliciousReentrantToken
/// @dev MockUSDC whose `transfer` re-enters the router once, to prove the
///      reentrancy guard holds during claims.
contract MaliciousReentrantToken is MockUSDC {
    IPaymentRouter public router;
    bool public armed;

    function setRouter(address r) external {
        router = IPaymentRouter(r);
    }

    function arm() external {
        armed = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (armed && msg.sender == address(router)) {
            armed = false;
            router.claimDirect(address(this));
        }
        return super.transfer(to, amount);
    }
}
