// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Discriminator for the payment kind carried in a payload.
/// @dev    ABI-encoded as a `uint8` (enum), which is why it can sit inside a
///         versioned struct and round-trip through `abi.encode`/`abi.decode`.
enum PaymentType {
    Direct,
    Stream
}

/// @title PaymentCodec
/// @notice Canonical, versioned encode/decode for cross-chain payment payloads.
/// @dev    Every payload is headed by a `uint8 version` so the wire format can
///         evolve without breaking in-flight messages: a future decoder reads
///         the version first and routes to a legacy/current decoder (or rejects
///         unknown versions) before touching the remaining bytes.
library PaymentCodec {
    /// @notice Current payload version.
    uint8 public constant VERSION = 1;

    /// @notice Thrown when decoding a payload with an unsupported version.
    error UnsupportedPayloadVersion(uint8 version);

    /// @notice Fully-decoded view of a payment message.
    /// @dev    `periods`/`periodDuration` are zero for Direct payments.
    struct PaymentMessage {
        uint8 version;
        PaymentType paymentType;
        address recipient;
        address token;
        uint256 amount; // direct amount, or stream total
        uint32 periods; // stream only
        uint32 periodDuration; // stream only
    }

    /// @notice Encode a Direct payment: `(recipient, token, amount)`.
    function encodeDirect(address recipient, address token, uint256 amount) internal pure returns (bytes memory) {
        return abi.encode(VERSION, PaymentType.Direct, recipient, token, amount, uint32(0), uint32(0));
    }

    /// @notice Encode a Stream payment: `(recipient, token, totalAmount, periods, periodDuration)`.
    function encodeStream(address recipient, address token, uint256 totalAmount, uint32 periods, uint32 periodDuration)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(VERSION, PaymentType.Stream, recipient, token, totalAmount, periods, periodDuration);
    }

    /// @notice Decode a payload, reverting on an unsupported version.
    function decode(bytes calldata payload) internal pure returns (PaymentMessage memory message) {
        message = abi.decode(payload, (PaymentMessage));
        if (message.version != VERSION) revert UnsupportedPayloadVersion(message.version);
    }
}
