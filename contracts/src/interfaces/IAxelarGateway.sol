// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal subset of Axelar's `IAxelarGateway` (General Message
/// Passing) matching the official ABI. Only the entry points the payment
/// adapter needs are declared.
///
/// @dev Mirrors:
///   https://github.com/axelarnetwork/axelar-gmp-sdk-solidity/blob/main/contracts/interfaces/IAxelarGateway.sol
interface IAxelarGateway {
    /// @notice Emitted when a cross-chain contract call is made.
    event ContractCall(
        address indexed sender,
        string destinationChain,
        string destinationContractAddress,
        bytes32 indexed payloadHash,
        bytes payload
    );

    /// @notice Send a contract call (message) to `destinationChain`.
    function callContract(
        string calldata destinationChain,
        string calldata contractAddress,
        bytes calldata payload
    ) external;

    /// @notice Approve and consume a pending contract call, returning true only
    /// if the command is valid and not yet executed.
    function validateContractCall(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes32 payloadHash
    ) external returns (bool);

    /// @notice Whether a given command has already been executed.
    function isCommandExecuted(bytes32 commandId) external view returns (bool);
}
