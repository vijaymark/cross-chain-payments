// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Shared protocol types for IPay.
/// See docs/PROTOCOL_SPEC.md for the canonical definitions.
library Types {
    /// @notice Payment primitives supported by the protocol.
    enum PaymentMode {
        OneTime, // 0 — full amount released immediately
        Stream, // 1 — linear per-second release
        Milestone // 2 — tranche-based release
    }

    /// @notice Approval mechanism for milestone tranche release.
    enum ApprovalMode {
        Multisig, // 0 — m-of-n signatures
        Vote, // 1 — simple majority of voters
        Oracle // 2 — trusted attestation key
    }

    /// @notice Canonical cross-chain message (PROTOCOL_SPEC.md §4).
    struct CrossChainMessage {
        uint256 nonce;
        uint256 sourceChainId;
        uint256 destChainId;
        address sender; // source-chain funder; scopes replay protection per sender
        bytes32 token; // canonical token id on source chain (address, left-padded)
        uint256 amount; // base-unit amount
        bytes recipient; // destination address, per-chain encoded (20B EVM / 32B Soroban)
        PaymentMode mode;
        bytes metadata; // mode-specific payload (PROTOCOL_SPEC.md §4.1)
    }
}
