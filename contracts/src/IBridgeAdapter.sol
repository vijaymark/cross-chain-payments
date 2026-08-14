// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Abstraction over any cross-chain messaging/bridging provider
/// (LayerZero, Axelar, Wormhole, ...). Escrow logic depends only on this
/// interface, never on a concrete bridge, so a real bridge can be plugged in
/// later without touching escrow accounting.
///
/// The destination-side callback `receiveMessage` is implemented by the
/// `PaymentRouter` (see `IBridgeReceiver` below). The adapter calls it when a
/// message arrives on the destination chain.
interface IBridgeAdapter {
    /// @notice Deliver an encoded `Types.CrossChainMessage` payload to
    /// `destChainId`.
    /// @return deliveryId Unique identifier for the in-flight message.
    function sendMessage(bytes calldata payload, uint256 destChainId)
        external
        returns (bytes32 deliveryId);

    /// @notice Emitted when a message is handed to the bridge on the source chain.
    event MessageSent(bytes32 indexed deliveryId, uint256 indexed destChainId, bytes payload);
}

/// @notice Callback implemented by the router on the destination chain.
interface IBridgeReceiver {
    /// @notice Emitted by the router when a message is received from the bridge.
    event MessageReceived(
        bytes32 indexed deliveryId, uint256 indexed sourceChainId, uint256 destChainId
    );

    function receiveMessage(bytes calldata payload) external;
}
