// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC
/// @notice 6-decimal mintable test token used to exercise the router on testnets.
/// @dev    Minting is intentionally open — this is a test fixture, not a
///         production token. Deploy it at the same address on both chains (e.g.
///         via CREATE2) so the router's single-token-address model holds.
contract MockUSDC is ERC20 {
    uint8 private immutable _decimals;

    constructor() ERC20("Mock USDC", "mUSDC") {
        _decimals = 6;
    }

    /// @inheritdoc ERC20
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    /// @notice Mint `amount` to `to`. Unrestricted (testnet-only fixture).
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
