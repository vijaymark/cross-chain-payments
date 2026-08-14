// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAxelarGateway} from "./IAxelarGateway.sol";

/// @notice Minimal subset of Axelar's `IAxelarExecutable` interface that a
/// contract implements to receive cross-chain GMP messages.
///
/// @dev Mirrors:
///   https://github.com/axelarnetwork/axelar-gmp-sdk-solidity/blob/main/contracts/interfaces/IAxelarExecutable.sol
interface IAxelarExecutable {
    error NotApprovedByGateway();

    function gateway() external view returns (IAxelarGateway);

    function execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) external;
}
