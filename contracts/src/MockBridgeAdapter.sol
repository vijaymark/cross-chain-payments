// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBridgeAdapter, IBridgeReceiver} from "./IBridgeAdapter.sol";

/// @notice In-memory bridge for local/testnet development. Simulates the async
/// `send → deliver` flow of a real bridge without an external relayer, routing
/// each message to the destination router registered for its `destChainId`.
contract MockBridgeAdapter is IBridgeAdapter {
    /// @notice chainId -> destination router that receives delivered messages.
    mapping(uint256 => address) public routers;

    struct Outbound {
        bytes payload;
        uint256 destChainId;
        bool delivered;
    }

    /// @notice deliveryId -> outbound message.
    mapping(bytes32 => Outbound) public outbox;

    /// @notice Delivery ids in send order (for introspection in tests).
    bytes32[] public queue;

    address public owner;

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    /// @notice Register the destination router for a chain id.
    function setRouter(uint256 chainId, address router) external onlyOwner {
        routers[chainId] = router;
    }

    /// @inheritdoc IBridgeAdapter
    function sendMessage(bytes calldata payload, uint256 destChainId)
        external
        override
        returns (bytes32 deliveryId)
    {
        deliveryId = keccak256(payload);
        outbox[deliveryId] = Outbound({payload: payload, destChainId: destChainId, delivered: false});
        queue.push(deliveryId);
        emit MessageSent(deliveryId, destChainId, payload);
    }

    /// @notice Simulate a relayer delivering a queued message to the router
    /// registered for its destination chain.
    function deliver(bytes32 deliveryId) external {
        Outbound storage o = outbox[deliveryId];
        require(o.payload.length > 0, "MockBridge: not queued");
        require(!o.delivered, "MockBridge: already delivered");
        address router = routers[o.destChainId];
        require(router != address(0), "MockBridge: no router for chain");
        o.delivered = true;
        IBridgeReceiver(router).receiveMessage(o.payload);
    }

    /// @notice Number of messages still awaiting delivery.
    function pending() external view returns (uint256) {
        uint256 count;
        for (uint256 i = 0; i < queue.length; i++) {
            Outbound storage o = outbox[queue[i]];
            if (o.payload.length > 0 && !o.delivered) count++;
        }
        return count;
    }
}
