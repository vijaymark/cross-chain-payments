// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ICrossChainTransport
/// @notice Transport abstraction between payment logic and the messaging layer.
/// @dev    Payment logic depends only on this interface, never on a specific
///         bridge. The MVP implements it with LayerZero's OApp standard
///         (`PaymentRouter` inherits `OApp`). To swap to CCIP/Hyperlane, provide
///         a different implementation of `sendMessage`/`receiveMessage` without
///         touching the escrow, vesting, or claim logic.
interface ICrossChainTransport {
    /// @notice Emitted when a payload is dispatched to the peer on `dstEid`.
    event MessageSent(uint32 indexed dstEid, bytes32 indexed guid, bytes payload);

    /// @notice Emitted when a peer-verified payload from `srcEid` is applied.
    event MessageReceived(uint32 indexed srcEid, bytes32 indexed guid, bytes payload);

    /// @notice Send an encoded payment payload to the trusted peer on `dstEid`.
    /// @dev    Payable: `msg.value` is forwarded as the LayerZero native fee; any
    ///         excess is returned to `refundAddress`.
    /// @param dstEid        Destination chain's LayerZero endpoint ID.
    /// @param payload       ABI-encoded payment payload.
    /// @param refundAddress Address that receives any excess native fee.
    /// @return guid The unique identifier of the sent message.
    function sendMessage(uint32 dstEid, bytes calldata payload, address refundAddress)
        external
        payable
        returns (bytes32 guid);

    /// @notice Apply a peer-verified inbound payload to payment state.
    /// @dev    MUST only be invocable after the transport has verified that the
    ///         message origin is a registered peer. In the MVP this is the
    ///         `OAppReceiver.lzReceive` endpoint + peer check.
    /// @param srcEid  Source chain's LayerZero endpoint ID.
    /// @param guid    Unique identifier of the received message.
    /// @param payload ABI-encoded payment payload.
    function receiveMessage(uint32 srcEid, bytes32 guid, bytes calldata payload) external;
}
