// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    Origin,
    MessagingParams,
    MessagingFee,
    MessagingReceipt
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/// @dev Minimal surface of an OApp receiver, so the mock endpoint can invoke
///      `lzReceive` without importing the router (which would create a cycle).
interface IOAppReceiverLike {
    function lzReceive(
        Origin calldata origin,
        bytes32 guid,
        bytes calldata message,
        address executor,
        bytes calldata extraData
    ) external payable;
}

/// @title MockLayerZeroEndpoint
/// @notice Offline stand-in for LayerZero's Endpoint V2. Records the last `send`
///         and exposes `deliver`, which calls `lzReceive` on an OApp as the
///         endpoint (so the base `OnlyEndpoint` check passes).
contract MockLayerZeroEndpoint {
    struct SentMsg {
        uint32 dstEid;
        bytes32 receiver;
        bytes message;
        bool payInLzToken;
        address refundAddress;
    }

    SentMsg public lastSent;
    uint256 public sentCount;
    address public delegate;

    function setDelegate(address d) external {
        delegate = d;
    }

    function quote(MessagingParams calldata, address) external pure returns (MessagingFee memory) {
        return MessagingFee(0, 0);
    }

    function send(MessagingParams calldata p, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory)
    {
        lastSent = SentMsg(p.dstEid, p.receiver, p.message, p.payInLzToken, refundAddress);
        sentCount++;
        // casting to 'uint64' is safe because `sentCount` only ever reaches the
        // handful of messages a test sends, never >2^64.
        // forge-lint: disable-next-line(unsafe-typecast)
        return MessagingReceipt(bytes32(sentCount), uint64(sentCount), MessagingFee(msg.value, 0));
    }

    /// @dev Call `lzReceive` on `oapp` as the endpoint (msg.sender == this).
    function deliver(address oapp, Origin calldata origin, bytes32 guid, bytes calldata message) external {
        IOAppReceiverLike(oapp).lzReceive(origin, guid, message, address(this), "");
    }
}
