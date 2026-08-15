// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {PaymentCodec} from "../src/libraries/PaymentCodec.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockLayerZeroEndpoint} from "./mocks/MockLayerZeroEndpoint.sol";
import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/// @dev Invariant actor. Mints-to-router and delivers Direct/Stream messages
///      (acting as both the source peer and the recipient), then claims. Tracks
///      credited totals so the invariants can be checked without iterating
///      unbounded storage.
contract InvariantHandler {
    PaymentRouter public router;
    MockUSDC public token;
    MockLayerZeroEndpoint public endpoint;

    uint32 constant SRC_EID = 40161;
    bytes32 public peer;

    uint256 public streamTotalSum;
    uint256 public directCreditedSum;
    uint256 public streamCount;

    constructor(PaymentRouter _router, MockUSDC _token, MockLayerZeroEndpoint _endpoint) {
        router = _router;
        token = _token;
        endpoint = _endpoint;
        // The handler is the source peer (for the peer check) and the recipient.
        peer = bytes32(uint256(uint160(address(this))));
    }

    function deliverDirect(uint96 amount) external {
        if (amount == 0) return;
        token.mint(address(router), amount);
        endpoint.deliver(
            address(router),
            Origin(SRC_EID, peer, 1),
            bytes32(uint256(directCreditedSum + 1)),
            PaymentCodec.encodeDirect(address(this), address(token), amount)
        );
        directCreditedSum += amount;
    }

    function deliverStream(uint96 total, uint32 periods, uint32 periodDuration) external {
        if (total == 0 || periods == 0 || periodDuration == 0) return;
        token.mint(address(router), total);
        endpoint.deliver(
            address(router),
            Origin(SRC_EID, peer, 1),
            bytes32(uint256(streamCount + 1)),
            PaymentCodec.encodeStream(address(this), address(token), total, periods, periodDuration)
        );
        streamTotalSum += total;
        streamCount++;
    }

    function claimDirect() external {
        router.claimDirect(address(token));
    }

    function claimStream(uint256 id) external {
        if (streamCount == 0) return;
        router.claim(id % streamCount);
    }
}

contract PaymentRouterInvariantTest is Test {
    uint32 constant SRC_EID = 40161;

    MockLayerZeroEndpoint endpoint;
    MockUSDC token;
    PaymentRouter router;
    InvariantHandler handler;

    function setUp() public {
        endpoint = new MockLayerZeroEndpoint();
        token = new MockUSDC();
        router = new PaymentRouter(address(endpoint), address(this));
        router.setSupportedToken(address(token), true);

        handler = new InvariantHandler(router, token, endpoint);
        router.setPeer(SRC_EID, bytes32(uint256(uint160(address(handler)))));

        targetContract(address(handler));
    }

    /// @dev The router's token balance must always cover its liabilities:
    ///      (unclaimed stream amounts) + (unclaimed direct amounts).
    function invariant_balanceCoversLiabilities() public view {
        // handler token balance == total amount ever claimed (it only receives
        // via claim/claimDirect), so liabilities = credited - claimed.
        uint256 liabilities = handler.streamTotalSum() + handler.directCreditedSum() - token.balanceOf(address(handler));
        assertGe(token.balanceOf(address(router)), liabilities);
    }

    /// @dev Total claimed can never exceed the total amount locked/credited.
    function invariant_claimedNeverExceedsLocked() public view {
        assertLe(token.balanceOf(address(handler)), handler.streamTotalSum() + handler.directCreditedSum());
    }
}
