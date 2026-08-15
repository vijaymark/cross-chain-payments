// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {IPaymentRouter} from "../src/interfaces/IPaymentRouter.sol";
import {PaymentCodec, PaymentType} from "../src/libraries/PaymentCodec.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockLayerZeroEndpoint} from "./mocks/MockLayerZeroEndpoint.sol";
import {MaliciousReentrantToken} from "./mocks/MaliciousReentrantToken.sol";
import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

contract PaymentRouterTest is Test {
    address owner;
    address funder;
    address recipient;
    MockLayerZeroEndpoint endpoint;
    MockUSDC token;
    PaymentRouter router;

    uint32 constant SRC_EID = 40161; // Ethereum Sepolia
    uint32 constant DST_EID = 40245; // Base Sepolia
    address constant SRC_ROUTER = address(0x1111);
    address constant DST_ROUTER = address(0x2222);

    function setUp() public {
        owner = address(this);
        funder = makeAddr("funder");
        recipient = makeAddr("recipient");

        endpoint = new MockLayerZeroEndpoint();
        token = new MockUSDC();
        router = new PaymentRouter(address(endpoint), owner);

        router.setSupportedToken(address(token), true);
        router.setPeer(SRC_EID, bytes32(uint256(uint160(SRC_ROUTER))));
        router.setPeer(DST_EID, bytes32(uint256(uint160(DST_ROUTER))));
    }

    /* --------------------------- helpers ----------------------------- */

    function _peer() internal pure returns (bytes32) {
        return bytes32(uint256(uint160(SRC_ROUTER)));
    }

    function _deliverDirect(address to, address tok, uint256 amount) internal {
        endpoint.deliver(
            address(router),
            Origin(SRC_EID, _peer(), 1),
            bytes32(uint256(1)),
            PaymentCodec.encodeDirect(to, tok, amount)
        );
    }

    function _deliverStream(address to, address tok, uint256 total, uint32 periods, uint32 periodDuration) internal {
        endpoint.deliver(
            address(router),
            Origin(SRC_EID, _peer(), 1),
            bytes32(uint256(1)),
            PaymentCodec.encodeStream(to, tok, total, periods, periodDuration)
        );
    }

    /* ------------------------ sendPayment ---------------------------- */

    function test_sendPayment_locksAndSends() public {
        token.mint(funder, 100e6);

        vm.startPrank(funder);
        token.approve(address(router), 100e6);

        vm.expectEmit(true, true, true, true);
        emit IPaymentRouter.PaymentSent(DST_EID, recipient, address(token), 40e6, PaymentType.Direct);
        router.sendPayment(DST_EID, recipient, address(token), 40e6);
        vm.stopPrank();

        assertEq(token.balanceOf(address(router)), 40e6);
        assertEq(token.balanceOf(funder), 60e6);

        (uint32 dstEid, bytes32 receiver, bytes memory message, bool payInLzToken, address refundAddress) =
            endpoint.lastSent();
        assertEq(dstEid, DST_EID);
        assertEq(receiver, bytes32(uint256(uint160(DST_ROUTER))));
        assertEq(message, PaymentCodec.encodeDirect(recipient, address(token), 40e6));
        assertEq(payInLzToken, false);
        assertEq(refundAddress, funder);
    }

    function test_sendPayment_zeroAmountReverts() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        router.sendPayment(DST_EID, recipient, address(token), 0);
    }

    function test_sendPayment_zeroRecipientReverts() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        router.sendPayment(DST_EID, address(0), address(token), 1e6);
    }

    function test_sendPayment_unsupportedTokenReverts() public {
        MockUSDC other = new MockUSDC();
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken()"));
        router.sendPayment(DST_EID, recipient, address(other), 1e6);
    }

    /* ---------------------- sendStreamedPayment ---------------------- */

    function test_sendStreamedPayment_locksAndSends() public {
        token.mint(funder, 100e6);

        vm.startPrank(funder);
        token.approve(address(router), 100e6);
        router.sendStreamedPayment(DST_EID, recipient, address(token), 100e6, 10, 1 days);
        vm.stopPrank();

        assertEq(token.balanceOf(address(router)), 100e6);

        (uint32 dstEid,, bytes memory message,, address refundAddress) = endpoint.lastSent();
        assertEq(dstEid, DST_EID);
        assertEq(message, PaymentCodec.encodeStream(recipient, address(token), 100e6, 10, 1 days));
        assertEq(refundAddress, funder);
    }

    function test_sendStreamedPayment_zeroPeriodsReverts() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidPeriods()"));
        router.sendStreamedPayment(DST_EID, recipient, address(token), 1e6, 0, 1 days);
    }

    function test_sendStreamedPayment_zeroDurationReverts() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidPeriods()"));
        router.sendStreamedPayment(DST_EID, recipient, address(token), 1e6, 10, 0);
    }

    /* --------------------- receive + direct claim -------------------- */

    function test_directPayment_creditsAndClaims() public {
        token.mint(address(router), 100e6);

        vm.expectEmit(true, true, true, true);
        emit IPaymentRouter.PaymentReceived(SRC_EID, bytes32(uint256(1)), recipient, address(token), 30e6);
        _deliverDirect(recipient, address(token), 30e6);

        assertEq(router.claimable(recipient, address(token)), 30e6);

        vm.prank(recipient);
        router.claimDirect(address(token));

        assertEq(token.balanceOf(recipient), 30e6);
        assertEq(router.claimable(recipient, address(token)), 0);
    }

    function test_claimDirect_nothingReverts() public {
        vm.expectRevert(abi.encodeWithSignature("NothingToClaim()"));
        router.claimDirect(address(token));
    }

    /* ----------------------- stream + claims ------------------------- */

    function test_stream_claimPartialThenFull() public {
        uint256 total = 100e6;
        uint32 periods = 10;
        uint32 periodDuration = 1 days;

        token.mint(address(router), total);
        _deliverStream(recipient, address(token), total, periods, periodDuration);

        (, uint40 start,,,,, uint128 claimed) = router.streams(0);
        assertEq(start, uint40(block.timestamp));
        assertEq(claimed, 0);

        // Mid-stream: 5 of 10 periods vested.
        vm.warp(start + 5 * periodDuration);
        vm.prank(recipient);
        router.claim(0);
        assertEq(token.balanceOf(recipient), 50e6);

        // Fully vested.
        vm.warp(start + 10 * periodDuration);
        vm.prank(recipient);
        router.claim(0);
        assertEq(token.balanceOf(recipient), 100e6);

        // Double-claim protection: nothing left to claim.
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSignature("NothingToClaim()"));
        router.claim(0);
    }

    function test_claim_notRecipientReverts() public {
        token.mint(address(router), 100e6);
        _deliverStream(recipient, address(token), 100e6, 10, 1 days);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("NotStreamRecipient()"));
        router.claim(0);
    }

    /* ------------------------- access control ------------------------ */

    function test_adminFunctions_onlyOwner() public {
        address nonOwner = makeAddr("nonOwner");
        vm.startPrank(nonOwner);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        router.setSupportedToken(address(token), false);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        router.pause();

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        router.setPeer(DST_EID, bytes32(0));

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        router.rescueTokens(address(token), 1, nonOwner);

        vm.stopPrank();
    }

    function test_ownable2Step_transferOwnership() public {
        address newOwner = makeAddr("newOwner");

        router.transferOwnership(newOwner);
        assertEq(router.pendingOwner(), newOwner);
        assertEq(router.owner(), address(this));

        vm.prank(newOwner);
        router.acceptOwnership();
        assertEq(router.owner(), newOwner);
    }

    function test_setSupportedToken_toggles() public {
        assertTrue(router.supportedTokens(address(token)));
        router.setSupportedToken(address(token), false);
        assertFalse(router.supportedTokens(address(token)));
        router.setSupportedToken(address(token), true);
        assertTrue(router.supportedTokens(address(token)));
    }

    /* ----------------------------- pause ----------------------------- */

    function test_pause_blocksSend() public {
        router.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        router.sendPayment(DST_EID, recipient, address(token), 1e6);
    }

    function test_pause_blocksReceive() public {
        router.pause();
        token.mint(address(router), 100e6);

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        _deliverDirect(recipient, address(token), 10e6);
    }

    function test_pause_claimsStillWork() public {
        token.mint(address(router), 100e6);
        _deliverDirect(recipient, address(token), 10e6);

        router.pause();

        vm.prank(recipient);
        router.claimDirect(address(token));
        assertEq(token.balanceOf(recipient), 10e6);
    }

    function test_unpause_reEnablesSend() public {
        router.pause();
        router.unpause();

        token.mint(funder, 100e6);
        vm.startPrank(funder);
        token.approve(address(router), 100e6);
        router.sendPayment(DST_EID, recipient, address(token), 10e6);
        vm.stopPrank();

        assertEq(token.balanceOf(address(router)), 10e6);
    }

    /* --------------------------- reentrancy -------------------------- */

    function test_reentrancy_claimDirect_blocked() public {
        MaliciousReentrantToken t = new MaliciousReentrantToken();
        router.setSupportedToken(address(t), true);

        address attacker = makeAddr("attacker");
        t.mint(address(router), 100e6);
        _deliverDirect(attacker, address(t), 100e6);

        t.setRouter(address(router));
        t.arm();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        router.claimDirect(address(t));

        // Entire call reverted: attacker holds nothing, claimable intact.
        assertEq(t.balanceOf(attacker), 0);
        assertEq(router.claimable(attacker, address(t)), 100e6);
    }

    /* ------------------------- peer spoofing ------------------------- */

    function test_lzReceive_unregisteredPeerReverts() public {
        bytes32 wrongSender = bytes32(uint256(uint160(address(0xBEEF))));
        bytes memory payload = PaymentCodec.encodeDirect(recipient, address(token), 1e6);

        vm.expectRevert(abi.encodeWithSignature("UnauthorizedPeer()"));
        endpoint.deliver(address(router), Origin(SRC_EID, wrongSender, 1), bytes32(uint256(1)), payload);
    }

    function test_lzReceive_nonEndpointReverts() public {
        vm.expectRevert(abi.encodeWithSignature("OnlyEndpoint(address)", address(this)));
        this._lzReceiveDirect(PaymentCodec.encodeDirect(recipient, address(token), 1e6));
    }

    /// @dev External helper so the payload reaches `lzReceive` as calldata while
    ///      `msg.sender` is this test contract (i.e. NOT the endpoint).
    function _lzReceiveDirect(bytes calldata payload) external {
        router.lzReceive(Origin(SRC_EID, _peer(), 1), bytes32(uint256(1)), payload, address(this), "");
    }

    /* ----------------------------- quotes ---------------------------- */

    function test_quoteSendPayment() public view {
        assertEq(router.quoteSendPayment(DST_EID, recipient, address(token), 1e6), 0);
    }

    function test_quoteSendStreamedPayment() public view {
        assertEq(router.quoteSendStreamedPayment(DST_EID, recipient, address(token), 1e6, 10, 1 days), 0);
    }

    /* --------------------------- rescueTokens ------------------------ */

    function test_rescueTokens_revertsForSupported() public {
        token.mint(address(router), 1e6);
        vm.expectRevert(abi.encodeWithSignature("TokenIsSupported()"));
        router.rescueTokens(address(token), 1e6, owner);
    }

    function test_rescueTokens_succeedsForUnsupported() public {
        MockUSDC stranger = new MockUSDC();
        stranger.mint(address(router), 5e6); // "accidentally" sent to the router

        router.rescueTokens(address(stranger), 5e6, owner);

        assertEq(stranger.balanceOf(owner), 5e6);
        assertEq(stranger.balanceOf(address(router)), 0);
    }

    function test_rescueTokens_zeroToReverts() public {
        MockUSDC stranger = new MockUSDC();
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        router.rescueTokens(address(stranger), 1e6, address(0));
    }

    /* ------------------- extra guard branch coverage ----------------- */

    function test_sendStreamedPayment_zeroRecipientReverts() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        router.sendStreamedPayment(DST_EID, address(0), address(token), 1e6, 10, 1 days);
    }

    function test_sendStreamedPayment_zeroAmountReverts() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        router.sendStreamedPayment(DST_EID, recipient, address(token), 0, 10, 1 days);
    }

    function test_sendStreamedPayment_unsupportedTokenReverts() public {
        MockUSDC other = new MockUSDC();
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken()"));
        router.sendStreamedPayment(DST_EID, recipient, address(other), 1e6, 10, 1 days);
    }

    function test_sendMessage_onlySelfReverts() public {
        bytes memory payload = PaymentCodec.encodeDirect(recipient, address(token), 1e6);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedCaller(address)", address(this)));
        router.sendMessage(DST_EID, payload, funder);
    }

    function test_receiveMessage_onlySelfReverts() public {
        bytes memory payload = PaymentCodec.encodeDirect(recipient, address(token), 1e6);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedCaller(address)", address(this)));
        router.receiveMessage(SRC_EID, bytes32(uint256(1)), payload);
    }

    function test_acceptOwnership_unauthorizedReverts() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        router.acceptOwnership();
    }

    function test_receive_unsupportedDirectTokenReverts() public {
        MockUSDC other = new MockUSDC();
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken()"));
        _deliverDirect(recipient, address(other), 1e6);
    }

    function test_receive_zeroDirectAmountReverts() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        _deliverDirect(recipient, address(token), 0);
    }

    function test_receive_unsupportedStreamTokenReverts() public {
        MockUSDC other = new MockUSDC();
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken()"));
        _deliverStream(recipient, address(other), 1e6, 10, 1 days);
    }

    function test_receive_zeroStreamAmountReverts() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        _deliverStream(recipient, address(token), 0, 10, 1 days);
    }

    function test_receive_zeroStreamPeriodsReverts() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidPeriods()"));
        _deliverStream(recipient, address(token), 1e6, 0, 1 days);
    }

    function test_receive_streamAmountTooLargeReverts() public {
        uint256 huge = uint256(type(uint128).max) + 1;
        vm.expectRevert(abi.encodeWithSignature("AmountTooLarge()"));
        _deliverStream(recipient, address(token), huge, 10, 1 days);
    }

    function test_receive_unsupportedPayloadVersionReverts() public {
        bytes memory payload =
            abi.encode(uint8(2), PaymentType.Direct, recipient, address(token), 1e6, uint32(0), uint32(0));

        vm.expectRevert(abi.encodeWithSignature("UnsupportedPayloadVersion(uint8)", uint8(2)));
        endpoint.deliver(address(router), Origin(SRC_EID, _peer(), 1), bytes32(uint256(1)), payload);
    }
}
