// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {MockBridgeAdapter} from "../src/MockBridgeAdapter.sol";
import {Types} from "../src/Types.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FailingToken} from "./mocks/FailingToken.sol";
import {RejectingToken} from "./mocks/RejectingToken.sol";

contract PaymentRouterTest is Test {
    PaymentRouter sourceRouter; // chain 1 (Ethereum)
    PaymentRouter destRouter; // chain 1500 (Stellar/Soroban)
    MockBridgeAdapter bridge;
    MockERC20 token;

    address funder = address(0xF00D);
    address recipient = address(0xB0B);
    address stranger = address(0x5A0A);

    bytes32 constant DEST_TOKEN = bytes32(uint256(0xDEAD));
    uint256 constant SOURCE_CHAIN = 1;
    uint256 constant DEST_CHAIN = 1500;

    function setUp() public {
        sourceRouter = new PaymentRouter(SOURCE_CHAIN);
        destRouter = new PaymentRouter(DEST_CHAIN);
        bridge = new MockBridgeAdapter();
        bridge.setRouter(SOURCE_CHAIN, address(sourceRouter));
        bridge.setRouter(DEST_CHAIN, address(destRouter));
        sourceRouter.setBridge(address(bridge));
        destRouter.setBridge(address(bridge));

        token = new MockERC20();
        token.mint(funder, 1000 ether);

        // Register the token mapping (source) and destination allowlist.
        sourceRouter.setTokenMapping(address(token), DEST_CHAIN, DEST_TOKEN);
        destRouter.setAllowedDestToken(DEST_TOKEN, true);
    }

    function _approve(uint256 amount) internal {
        vm.prank(funder);
        token.approve(address(sourceRouter), amount);
    }

    function _queuedPayload() internal view returns (bytes32 deliveryId, bytes memory payload) {
        deliveryId = bridge.queue(0);
        (payload,,) = bridge.outbox(deliveryId);
    }

    // ---- one-time ----

    function test_sendPayment_locksAndSends() public {
        _approve(100 ether);
        vm.prank(funder);
        bytes32 messageId = sourceRouter.sendPayment(
            address(token), 100 ether, DEST_TOKEN, recipient, DEST_CHAIN, block.timestamp + 100
        );

        assertEq(sourceRouter.nonces(funder), 1);
        assertEq(token.balanceOf(address(sourceRouter)), 100 ether);

        (address sender, address tok, uint256 amount, uint256 timeout, bool settled, bool refunded) =
            sourceRouter.oneTimeLocks(messageId);
        assertEq(sender, funder);
        assertEq(tok, address(token));
        assertEq(amount, 100 ether);
        assertGt(timeout, block.timestamp);
        assertFalse(settled);
        assertFalse(refunded);
    }

    function test_refundOneTime_afterTimeout() public {
        _approve(100 ether);
        vm.prank(funder);
        bytes32 messageId = sourceRouter.sendPayment(
            address(token), 100 ether, DEST_TOKEN, recipient, DEST_CHAIN, block.timestamp + 100
        );

        vm.warp(block.timestamp + 101);
        vm.prank(funder);
        sourceRouter.refundOneTime(messageId);

        assertEq(token.balanceOf(funder), 1000 ether);
        assertEq(token.balanceOf(address(sourceRouter)), 0);
    }

    function test_refundOneTime_beforeTimeoutReverts() public {
        _approve(100 ether);
        vm.prank(funder);
        bytes32 messageId = sourceRouter.sendPayment(
            address(token), 100 ether, DEST_TOKEN, recipient, DEST_CHAIN, block.timestamp + 100
        );

        vm.expectRevert(PaymentRouter.PaymentRouter__BeforeTimeout.selector);
        vm.prank(funder);
        sourceRouter.refundOneTime(messageId);
    }

    function test_refundOneTime_settledReverts() public {
        _approve(100 ether);
        vm.prank(funder);
        bytes32 messageId = sourceRouter.sendPayment(
            address(token), 100 ether, DEST_TOKEN, recipient, DEST_CHAIN, block.timestamp + 100
        );

        vm.prank(address(bridge));
        sourceRouter.settleOneTime(messageId); // destination confirmed delivery

        vm.warp(block.timestamp + 101);
        vm.expectRevert(PaymentRouter.PaymentRouter__AlreadySettled.selector);
        vm.prank(funder);
        sourceRouter.refundOneTime(messageId);
    }

    // ---- stream ----

    function test_streamPayment_createsFundedEscrow() public {
        _approve(100 ether);
        vm.prank(funder);
        (bytes32 messageId, address escrowAddress) = sourceRouter.streamPayment(
            address(token), 100 ether, DEST_TOKEN, recipient, DEST_CHAIN, 100, block.timestamp + 100
        );

        assertTrue(messageId != bytes32(0), "zero messageId");
        assertEq(token.balanceOf(escrowAddress), 100 ether);

        vm.warp(block.timestamp + 50);
        vm.prank(recipient);
        (bool ok,) = escrowAddress.call(abi.encodeWithSignature("withdraw()"));
        assertTrue(ok);
        assertEq(token.balanceOf(recipient), 50 ether);
    }

    // ---- milestone ----

    function test_createMilestonePayment_fullFlow() public {
        uint256[] memory tranches = new uint256[](2);
        tranches[0] = 60 ether;
        tranches[1] = 40 ether;
        address[] memory approvers = new address[](2);
        approvers[0] = address(0xA);
        approvers[1] = address(0xB);

        _approve(100 ether);
        vm.prank(funder);
        (bytes32 messageId, address escrowAddress) = sourceRouter.createMilestonePayment(
            address(token),
            100 ether,
            DEST_TOKEN,
            recipient,
            DEST_CHAIN,
            tranches,
            Types.ApprovalMode.Multisig,
            approvers,
            2,
            address(0),
            block.timestamp + 1000,
            block.timestamp + 100
        );

        assertTrue(messageId != bytes32(0), "zero messageId");
        assertEq(token.balanceOf(escrowAddress), 100 ether);

        vm.prank(approvers[0]);
        (bool ok0,) = escrowAddress.call(abi.encodeWithSignature("approveMilestone(uint256)", 0));
        assertTrue(ok0);
        vm.prank(approvers[1]);
        (bool ok1,) = escrowAddress.call(abi.encodeWithSignature("approveMilestone(uint256)", 0));
        assertTrue(ok1);
        (bool ok2,) = escrowAddress.call(abi.encodeWithSignature("releaseMilestone(uint256)", 0));
        assertTrue(ok2);

        assertEq(token.balanceOf(recipient), 60 ether);
    }

    // ---- receiveMessage ----

    function test_receiveMessage_deliversAndAnnounces() public {
        _approve(100 ether);
        vm.prank(funder);
        sourceRouter.sendPayment(address(token), 100 ether, DEST_TOKEN, recipient, DEST_CHAIN, block.timestamp + 100);

        (bytes32 deliveryId, bytes memory payload) = _queuedPayload();
        bridge.deliver(deliveryId);

        Types.CrossChainMessage memory msg1 = destRouter.announced(keccak256(payload));
        assertEq(msg1.amount, 100 ether);
        assertEq(uint256(msg1.mode), uint256(Types.PaymentMode.OneTime));
        assertTrue(destRouter.delivered(SOURCE_CHAIN, funder, 0), "nonce 0 should be delivered");
        assertEq(bridge.pending(), 0);
    }

    function test_receiveMessage_replayReverts() public {
        _approve(100 ether);
        vm.prank(funder);
        sourceRouter.sendPayment(address(token), 100 ether, DEST_TOKEN, recipient, DEST_CHAIN, block.timestamp + 100);

        (bytes32 deliveryId, bytes memory payload) = _queuedPayload();
        bridge.deliver(deliveryId);

        vm.expectRevert(PaymentRouter.PaymentRouter__Replay.selector);
        vm.prank(address(bridge));
        destRouter.receiveMessage(payload);
    }

    function test_receiveMessage_wrongDestChainReverts() public {
        Types.CrossChainMessage memory message = Types.CrossChainMessage({
            nonce: 0,
            sourceChainId: SOURCE_CHAIN,
            destChainId: 999, // not this router's chain
            sender: funder,
            token: DEST_TOKEN,
            amount: 1 ether,
            recipient: abi.encodePacked(recipient),
            mode: Types.PaymentMode.OneTime,
            metadata: ""
        });

        vm.expectRevert(PaymentRouter.PaymentRouter__WrongDestChain.selector);
        vm.prank(address(bridge));
        destRouter.receiveMessage(abi.encode(message));
    }

    function test_receiveMessage_onlyBridge() public {
        Types.CrossChainMessage memory message = Types.CrossChainMessage({
            nonce: 0,
            sourceChainId: SOURCE_CHAIN,
            destChainId: DEST_CHAIN,
            sender: funder,
            token: DEST_TOKEN,
            amount: 1 ether,
            recipient: abi.encodePacked(recipient),
            mode: Types.PaymentMode.OneTime,
            metadata: ""
        });

        vm.expectRevert(PaymentRouter.PaymentRouter__NotBridge.selector);
        destRouter.receiveMessage(abi.encode(message));
    }

    function test_setBridge_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(PaymentRouter.PaymentRouter__NotOwner.selector);
        sourceRouter.setBridge(stranger);
    }

    // ---- token allowlist ----

    function test_sendPayment_tokenNotAllowedReverts() public {
        _approve(100 ether);
        vm.prank(funder);
        vm.expectRevert(PaymentRouter.PaymentRouter__TokenNotAllowed.selector);
        sourceRouter.sendPayment(
            address(token), 100 ether, bytes32(uint256(0xBADC0DE)), recipient, DEST_CHAIN, block.timestamp + 100
        );
    }

    /// @notice An unregistered token mapping reads as bytes32(0); passing a
    /// zero destToken must not slip through the allowlist.
    function _unmappedToken() internal returns (MockERC20 t) {
        t = new MockERC20();
        t.mint(funder, 100 ether);
        vm.prank(funder);
        t.approve(address(sourceRouter), 100 ether);
    }

    function test_sendPayment_zeroDestTokenBypassReverts() public {
        MockERC20 t = _unmappedToken();
        vm.prank(funder);
        vm.expectRevert(PaymentRouter.PaymentRouter__TokenNotAllowed.selector);
        sourceRouter.sendPayment(address(t), 100 ether, bytes32(0), recipient, DEST_CHAIN, block.timestamp + 100);
    }

    function test_streamPayment_zeroDestTokenBypassReverts() public {
        MockERC20 t = _unmappedToken();
        vm.prank(funder);
        vm.expectRevert(PaymentRouter.PaymentRouter__TokenNotAllowed.selector);
        sourceRouter.streamPayment(address(t), 100 ether, bytes32(0), recipient, DEST_CHAIN, 100, block.timestamp + 100);
    }

    function test_createMilestonePayment_zeroDestTokenBypassReverts() public {
        MockERC20 t = _unmappedToken();
        uint256[] memory tranches = new uint256[](1);
        tranches[0] = 100 ether;
        address[] memory approvers = new address[](1);
        approvers[0] = address(0xA);

        vm.prank(funder);
        vm.expectRevert(PaymentRouter.PaymentRouter__TokenNotAllowed.selector);
        sourceRouter.createMilestonePayment(
            address(t), 100 ether, bytes32(0), recipient, DEST_CHAIN, tranches,
            Types.ApprovalMode.Multisig, approvers, 1, address(0), block.timestamp + 1000, block.timestamp + 100
        );
    }

    function test_receiveMessage_tokenNotAllowedReverts() public {
        Types.CrossChainMessage memory message = Types.CrossChainMessage({
            nonce: 0,
            sourceChainId: SOURCE_CHAIN,
            destChainId: DEST_CHAIN,
            sender: funder,
            token: bytes32(uint256(0xBADC0DE)), // not allowlisted on dest
            amount: 1 ether,
            recipient: abi.encodePacked(recipient),
            mode: Types.PaymentMode.OneTime,
            metadata: ""
        });

        vm.expectRevert(PaymentRouter.PaymentRouter__TokenNotAllowed.selector);
        vm.prank(address(bridge));
        destRouter.receiveMessage(abi.encode(message));
    }

    function test_setTokenMapping_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(PaymentRouter.PaymentRouter__NotOwner.selector);
        sourceRouter.setTokenMapping(address(token), DEST_CHAIN, DEST_TOKEN);
    }

    // ---- input guards ----

    function test_sendPayment_zeroAmountReverts() public {
        vm.prank(funder);
        vm.expectRevert(PaymentRouter.PaymentRouter__ZeroAmount.selector);
        sourceRouter.sendPayment(address(token), 0, DEST_TOKEN, recipient, DEST_CHAIN, block.timestamp + 100);
    }

    function test_sendPayment_zeroRecipientReverts() public {
        vm.prank(funder);
        vm.expectRevert(PaymentRouter.PaymentRouter__ZeroRecipient.selector);
        sourceRouter.sendPayment(address(token), 1 ether, DEST_TOKEN, address(0), DEST_CHAIN, block.timestamp + 100);
    }

    function test_sendPayment_timeoutInPastReverts() public {
        vm.prank(funder);
        vm.expectRevert(PaymentRouter.PaymentRouter__TimeoutInPast.selector);
        sourceRouter.sendPayment(address(token), 1 ether, DEST_TOKEN, recipient, DEST_CHAIN, block.timestamp);
    }

    function test_streamPayment_zeroAmountReverts() public {
        vm.prank(funder);
        vm.expectRevert(PaymentRouter.PaymentRouter__ZeroAmount.selector);
        sourceRouter.streamPayment(address(token), 0, DEST_TOKEN, recipient, DEST_CHAIN, 100, block.timestamp + 100);
    }

    function test_streamPayment_zeroDurationReverts() public {
        vm.prank(funder);
        vm.expectRevert(PaymentRouter.PaymentRouter__ZeroDuration.selector);
        sourceRouter.streamPayment(address(token), 1 ether, DEST_TOKEN, recipient, DEST_CHAIN, 0, block.timestamp + 100);
    }

    function test_streamPayment_timeoutInPastReverts() public {
        vm.prank(funder);
        vm.expectRevert(PaymentRouter.PaymentRouter__TimeoutInPast.selector);
        sourceRouter.streamPayment(address(token), 1 ether, DEST_TOKEN, recipient, DEST_CHAIN, 100, block.timestamp);
    }

    function test_createMilestonePayment_zeroAmountReverts() public {
        uint256[] memory tranches = new uint256[](1);
        tranches[0] = 1 ether;
        address[] memory approvers = new address[](1);
        approvers[0] = address(0xA);

        vm.prank(funder);
        vm.expectRevert(PaymentRouter.PaymentRouter__ZeroAmount.selector);
        sourceRouter.createMilestonePayment(
            address(token), 0, DEST_TOKEN, recipient, DEST_CHAIN, tranches,
            Types.ApprovalMode.Multisig, approvers, 1, address(0), block.timestamp + 1000, block.timestamp + 100
        );
    }

    function test_sendPayment_noBridgeReverts() public {
        PaymentRouter r = new PaymentRouter(SOURCE_CHAIN);
        r.setTokenMapping(address(token), DEST_CHAIN, DEST_TOKEN);
        vm.expectRevert(PaymentRouter.PaymentRouter__NoBridge.selector);
        r.sendPayment(address(token), 1 ether, DEST_TOKEN, recipient, DEST_CHAIN, block.timestamp + 100);
    }

    // ---- refund / settle guards ----

    function test_refundOneTime_notSenderReverts() public {
        _approve(100 ether);
        vm.prank(funder);
        bytes32 messageId = sourceRouter.sendPayment(address(token), 100 ether, DEST_TOKEN, recipient, DEST_CHAIN, block.timestamp + 100);

        vm.warp(block.timestamp + 101);
        vm.prank(stranger);
        vm.expectRevert(PaymentRouter.PaymentRouter__NotSender.selector);
        sourceRouter.refundOneTime(messageId);
    }

    function test_refundOneTime_alreadyRefundedReverts() public {
        _approve(100 ether);
        vm.prank(funder);
        bytes32 messageId = sourceRouter.sendPayment(address(token), 100 ether, DEST_TOKEN, recipient, DEST_CHAIN, block.timestamp + 100);

        vm.warp(block.timestamp + 101);
        vm.prank(funder);
        sourceRouter.refundOneTime(messageId);

        vm.expectRevert(PaymentRouter.PaymentRouter__AlreadyRefunded.selector);
        vm.prank(funder);
        sourceRouter.refundOneTime(messageId);
    }

    function test_settleOneTime_unknownLockReverts() public {
        vm.prank(address(bridge));
        vm.expectRevert(PaymentRouter.PaymentRouter__UnknownLock.selector);
        sourceRouter.settleOneTime(bytes32(uint256(0xDEADBEEF)));
    }

    function test_transferOwnership_zeroOwnerReverts() public {
        vm.expectRevert(PaymentRouter.PaymentRouter__ZeroOwner.selector);
        sourceRouter.transferOwnership(address(0));
    }

    function test_transferOwnership_success() public {
        address newOwner = address(0xC0FFEE);
        sourceRouter.transferOwnership(newOwner);
        assertEq(sourceRouter.owner(), newOwner);
    }

    // ---- stream / milestone input guards (remaining) ----

    function test_streamPayment_zeroRecipientReverts() public {
        vm.prank(funder);
        vm.expectRevert(PaymentRouter.PaymentRouter__ZeroRecipient.selector);
        sourceRouter.streamPayment(address(token), 1 ether, DEST_TOKEN, address(0), DEST_CHAIN, 100, block.timestamp + 100);
    }

    function test_streamPayment_tokenNotAllowedReverts() public {
        vm.prank(funder);
        vm.expectRevert(PaymentRouter.PaymentRouter__TokenNotAllowed.selector);
        sourceRouter.streamPayment(address(token), 1 ether, bytes32(uint256(0xBADC0DE)), recipient, DEST_CHAIN, 100, block.timestamp + 100);
    }

    function test_createMilestonePayment_zeroRecipientReverts() public {
        uint256[] memory tranches = new uint256[](1);
        tranches[0] = 1 ether;
        address[] memory approvers = new address[](1);
        approvers[0] = address(0xA);

        vm.prank(funder);
        vm.expectRevert(PaymentRouter.PaymentRouter__ZeroRecipient.selector);
        sourceRouter.createMilestonePayment(
            address(token), 1 ether, DEST_TOKEN, address(0), DEST_CHAIN, tranches,
            Types.ApprovalMode.Multisig, approvers, 1, address(0), block.timestamp + 1000, block.timestamp + 100
        );
    }

    function test_createMilestonePayment_timeoutInPastReverts() public {
        uint256[] memory tranches = new uint256[](1);
        tranches[0] = 1 ether;
        address[] memory approvers = new address[](1);
        approvers[0] = address(0xA);

        vm.prank(funder);
        vm.expectRevert(PaymentRouter.PaymentRouter__TimeoutInPast.selector);
        sourceRouter.createMilestonePayment(
            address(token), 1 ether, DEST_TOKEN, recipient, DEST_CHAIN, tranches,
            Types.ApprovalMode.Multisig, approvers, 1, address(0), block.timestamp + 1000, block.timestamp
        );
    }

    function test_createMilestonePayment_tokenNotAllowedReverts() public {
        uint256[] memory tranches = new uint256[](1);
        tranches[0] = 1 ether;
        address[] memory approvers = new address[](1);
        approvers[0] = address(0xA);

        vm.prank(funder);
        vm.expectRevert(PaymentRouter.PaymentRouter__TokenNotAllowed.selector);
        sourceRouter.createMilestonePayment(
            address(token), 1 ether, bytes32(uint256(0xBADC0DE)), recipient, DEST_CHAIN, tranches,
            Types.ApprovalMode.Multisig, approvers, 1, address(0), block.timestamp + 1000, block.timestamp + 100
        );
    }

    // ---- transfer-failure branches ----

    function test_sendPayment_transferFailsReverts() public {
        RejectingToken rt = new RejectingToken();
        sourceRouter.setTokenMapping(address(rt), DEST_CHAIN, DEST_TOKEN);
        rt.mint(funder, 100 ether);
        vm.prank(funder);
        rt.approve(address(sourceRouter), 100 ether);

        vm.prank(funder);
        vm.expectRevert(PaymentRouter.PaymentRouter__TransferFailed.selector);
        sourceRouter.sendPayment(address(rt), 100 ether, DEST_TOKEN, recipient, DEST_CHAIN, block.timestamp + 100);
    }

    function test_streamPayment_transferFailsReverts() public {
        RejectingToken rt = new RejectingToken();
        sourceRouter.setTokenMapping(address(rt), DEST_CHAIN, DEST_TOKEN);
        rt.mint(funder, 100 ether);
        vm.prank(funder);
        rt.approve(address(sourceRouter), 100 ether);

        vm.prank(funder);
        vm.expectRevert(PaymentRouter.PaymentRouter__TransferFailed.selector);
        sourceRouter.streamPayment(address(rt), 100 ether, DEST_TOKEN, recipient, DEST_CHAIN, 100, block.timestamp + 100);
    }

    function test_createMilestonePayment_transferFailsReverts() public {
        uint256[] memory tranches = new uint256[](1);
        tranches[0] = 100 ether;
        address[] memory approvers = new address[](1);
        approvers[0] = address(0xA);

        RejectingToken rt = new RejectingToken();
        sourceRouter.setTokenMapping(address(rt), DEST_CHAIN, DEST_TOKEN);
        rt.mint(funder, 100 ether);
        vm.prank(funder);
        rt.approve(address(sourceRouter), 100 ether);

        vm.prank(funder);
        vm.expectRevert(PaymentRouter.PaymentRouter__TransferFailed.selector);
        sourceRouter.createMilestonePayment(
            address(rt), 100 ether, DEST_TOKEN, recipient, DEST_CHAIN, tranches,
            Types.ApprovalMode.Multisig, approvers, 1, address(0), block.timestamp + 1000, block.timestamp + 100
        );
    }

    function test_refundOneTime_transferFailsReverts() public {
        FailingToken ft = new FailingToken();
        sourceRouter.setTokenMapping(address(ft), DEST_CHAIN, DEST_TOKEN);
        ft.mint(funder, 100 ether);
        vm.prank(funder);
        ft.approve(address(sourceRouter), 100 ether);

        vm.prank(funder);
        bytes32 messageId = sourceRouter.sendPayment(
            address(ft), 100 ether, DEST_TOKEN, recipient, DEST_CHAIN, block.timestamp + 100
        );

        vm.warp(block.timestamp + 101);
        vm.prank(funder);
        vm.expectRevert(PaymentRouter.PaymentRouter__TransferFailed.selector);
        sourceRouter.refundOneTime(messageId);
    }

    // ---- token mapping revocation + bridge-not-set branches ----

    function test_removeTokenMapping_revokesMapping() public {
        sourceRouter.removeTokenMapping(address(token), DEST_CHAIN);
        _approve(100 ether);
        vm.prank(funder);
        vm.expectRevert(PaymentRouter.PaymentRouter__TokenNotAllowed.selector);
        sourceRouter.sendPayment(address(token), 100 ether, DEST_TOKEN, recipient, DEST_CHAIN, block.timestamp + 100);
    }

    function test_receiveMessage_noBridgeSetReverts() public {
        PaymentRouter r = new PaymentRouter(DEST_CHAIN);
        Types.CrossChainMessage memory message = Types.CrossChainMessage({
            nonce: 0,
            sourceChainId: SOURCE_CHAIN,
            destChainId: DEST_CHAIN,
            sender: funder,
            token: DEST_TOKEN,
            amount: 1 ether,
            recipient: abi.encodePacked(recipient),
            mode: Types.PaymentMode.OneTime,
            metadata: ""
        });
        vm.expectRevert(PaymentRouter.PaymentRouter__NotBridge.selector);
        r.receiveMessage(abi.encode(message));
    }

    function test_getters_exposeMappings() public view {
        assertEq(sourceRouter.tokenMap(address(token), DEST_CHAIN), DEST_TOKEN);
        assertTrue(destRouter.allowedDestTokens(DEST_TOKEN));
    }
}
