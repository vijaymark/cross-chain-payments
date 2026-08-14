// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAxelarExecutable} from "../../src/interfaces/IAxelarExecutable.sol";

/// @notice Test double for Axelar's GMP gateway. Emulates `callContract` on the
/// source chain and the relayer-driven `execute` delivery on the destination.
contract MockAxelarGateway {
    struct Call {
        string destinationChain;
        string contractAddress;
        bytes payload;
    }

    Call[] public calls;

    mapping(bytes32 => bool) public approved;
    mapping(bytes32 => bool) public executed;

    event ContractCall(
        address indexed sender,
        string destinationChain,
        string destinationContractAddress,
        bytes32 indexed payloadHash,
        bytes payload
    );

    function callContract(
        string calldata destinationChain,
        string calldata contractAddress,
        bytes calldata payload
    ) external {
        calls.push(Call({destinationChain: destinationChain, contractAddress: contractAddress, payload: payload}));
        emit ContractCall(msg.sender, destinationChain, contractAddress, keccak256(payload), payload);
    }

    /// @notice Simulate the relayer approving a command id.
    function approve(bytes32 commandId) external {
        approved[commandId] = true;
    }

    /// @notice Simulate a relayer delivering an approved message by invoking
    /// `execute` on the destination contract.
    function deliver(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        address destContract,
        bytes calldata payload
    ) external {
        approved[commandId] = true;
        IAxelarExecutable(destContract).execute(commandId, sourceChain, sourceAddress, payload);
    }

    function validateContractCall(bytes32 commandId, string calldata, string calldata, bytes32)
        external
        returns (bool)
    {
        if (!approved[commandId] || executed[commandId]) return false;
        executed[commandId] = true;
        return true;
    }

    function isCommandExecuted(bytes32 commandId) external view returns (bool) {
        return executed[commandId];
    }
}
