// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test token whose `transferFrom` always returns false, so the
/// router's fund-pull step fails. Used to exercise the router's
/// `PaymentRouter__TransferFailed` path for one-time / stream / milestone
/// payments (which pull funds via `transferFrom`, unlike the escrow refunds
/// that use plain `transfer`).
contract RejectingToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false; // always fails
    }
}
