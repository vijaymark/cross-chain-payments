// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBridgeAdapter, IBridgeReceiver} from "./IBridgeAdapter.sol";
import {IAxelarGateway} from "./interfaces/IAxelarGateway.sol";
import {IAxelarExecutable} from "./interfaces/IAxelarExecutable.sol";

/// @notice Axelar General Message Passing adapter for the payment router.
///
/// Implements `IBridgeAdapter` (the router's transport abstraction) on top of
/// Axelar's GMP gateway:
///
///   source chain:  router.sendMessage() -> gateway.callContract(...)
///   dest chain:    Axelar relayer -> execute() -> router.receiveMessage()
///
/// Escrow logic never changes: the router only ever calls `sendMessage` /
/// `receiveMessage`, so a mock bridge and a real bridge are interchangeable.
contract AxelarBridgeAdapter is IBridgeAdapter, IAxelarExecutable {
    error AxelarBridgeAdapter__NotOwner();
    error AxelarBridgeAdapter__NotRouter();
    error AxelarBridgeAdapter__NoRouter();
    error AxelarBridgeAdapter__UnknownChain();

    address public owner;

    /// @notice The local PaymentRouter that receives delivered messages.
    address public router;

    /// @inheritdoc IAxelarExecutable
    IAxelarGateway public immutable gateway;

    /// @notice protocol chainId -> Axelar chain name (e.g. 1500 -> "stellar-2025-q1").
    mapping(uint256 => string) public chainNames;

    /// @notice protocol chainId -> destination router address in the remote
    /// chain's native string form (Soroban contract id C…, EVM address 0x…).
    mapping(uint256 => string) public chainRouters;

    constructor(address gateway_) {
        gateway = IAxelarGateway(gateway_);
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert AxelarBridgeAdapter__NotOwner();
        _;
    }

    modifier onlyRouter() {
        if (msg.sender != router) revert AxelarBridgeAdapter__NotRouter();
        _;
    }

    // ---- configuration ----

    function setRouter(address newRouter) external onlyOwner {
        router = newRouter;
    }

    function setChainConfig(
        uint256 chainId,
        string calldata chainName,
        string calldata routerAddress
    ) external onlyOwner {
        chainNames[chainId] = chainName;
        chainRouters[chainId] = routerAddress;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    // ---- IBridgeAdapter (source chain) ----

    /// @inheritdoc IBridgeAdapter
    function sendMessage(bytes calldata payload, uint256 destChainId)
        external
        override
        onlyRouter
        returns (bytes32 deliveryId)
    {
        string memory destChain = chainNames[destChainId];
        string memory destRouter = chainRouters[destChainId];
        if (bytes(destChain).length == 0 || bytes(destRouter).length == 0) {
            revert AxelarBridgeAdapter__UnknownChain();
        }

        gateway.callContract(destChain, destRouter, payload);

        deliveryId = keccak256(payload);
        emit MessageSent(deliveryId, destChainId, payload);
    }

    // ---- IAxelarExecutable (destination chain) ----

    /// @inheritdoc IAxelarExecutable
    function execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) external override {
        if (address(router) == address(0)) revert AxelarBridgeAdapter__NoRouter();

        // Canonical Axelar flow: the command must be approved by the gateway.
        // This both authenticates the message and guarantees exactly-once
        // execution (the gateway marks the command executed on success).
        bytes32 payloadHash = keccak256(payload);
        if (!gateway.validateContractCall(commandId, sourceChain, sourceAddress, payloadHash)) {
            revert NotApprovedByGateway();
        }

        IBridgeReceiver(router).receiveMessage(payload);
    }
}
