// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {PaymentCodec} from "../src/libraries/PaymentCodec.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockLayerZeroEndpoint} from "./mocks/MockLayerZeroEndpoint.sol";
import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/// @dev Exposes the internal vesting math for direct fuzzing.
contract PaymentRouterHarness is PaymentRouter {
    constructor(address endpoint, address owner) PaymentRouter(endpoint, owner) {}

    function exposedVestedAmount(uint128 total, uint40 start, uint32 periods, uint32 periodDuration)
        external
        view
        returns (uint256)
    {
        return _vestedAmount(total, 0, start, periods, periodDuration);
    }

    function exposedVestedAmountWithClaimed(
        uint128 total,
        uint128 claimed,
        uint40 start,
        uint32 periods,
        uint32 periodDuration
    ) external view returns (uint256) {
        return _vestedAmount(total, claimed, start, periods, periodDuration);
    }
}

contract PaymentRouterFuzzTest is Test {
    PaymentRouterHarness harness;
    MockLayerZeroEndpoint endpoint;

    uint32 constant SRC_EID = 40161;
    bytes32 constant SRC_PEER = bytes32(uint256(uint160(address(0x1111))));

    function setUp() public {
        endpoint = new MockLayerZeroEndpoint();
        harness = new PaymentRouterHarness(address(endpoint), address(this));
    }

    /* ------------------ pure vesting-math fuzzing -------------------- */

    function testFuzz_vestedNeverExceedsTotal(
        uint128 total,
        uint40 start,
        uint32 periods,
        uint32 periodDuration,
        uint32 elapsed
    ) public {
        vm.assume(periods != 0 && periodDuration != 0);
        vm.warp(uint256(start) + elapsed);
        uint256 vested = harness.exposedVestedAmount(total, start, periods, periodDuration);
        assertLe(vested, total);
    }

    function testFuzz_fullyVestedReturnsTotal(uint128 total, uint40 start, uint32 periods, uint32 periodDuration)
        public
    {
        vm.assume(periods != 0 && periodDuration != 0);
        uint256 duration = uint256(periods) * uint256(periodDuration);
        vm.warp(uint256(start) + duration);
        assertEq(harness.exposedVestedAmount(total, start, periods, periodDuration), total);
    }

    /* ------------ defensive vesting-math branch coverage ------------ */

    function test_vestedAmount_claimedReachesTotal() public view {
        assertEq(harness.exposedVestedAmountWithClaimed(100, 100, 0, 10, 1 days), 100);
    }

    function test_vestedAmount_zeroDurationFallsBackToTotal() public view {
        // Defensive branch: unreachable via `claim()` (apply() validates periods /
        // periodDuration != 0), but exercised here so the guard is provably covered.
        assertEq(harness.exposedVestedAmount(100, 0, 0, 1 days), 100);
    }

    /* ------------- full-path claim amount fuzzing -------------------- */

    function testFuzz_claimMatchesVesting(uint128 total, uint32 periods, uint32 periodDuration, uint32 elapsed) public {
        vm.assume(periods != 0 && periodDuration != 0 && total != 0);
        uint256 duration = uint256(periods) * uint256(periodDuration);

        MockUSDC token = new MockUSDC();
        PaymentRouter router = new PaymentRouter(address(endpoint), address(this));
        router.setSupportedToken(address(token), true);
        router.setPeer(SRC_EID, SRC_PEER);

        address recipient = makeAddr("recipient");
        token.mint(address(router), total);

        endpoint.deliver(
            address(router),
            Origin(SRC_EID, SRC_PEER, 1),
            bytes32(uint256(1)),
            PaymentCodec.encodeStream(recipient, address(token), total, periods, periodDuration)
        );

        (, uint40 start,,,,,) = router.streams(0);

        uint256 expected = elapsed >= duration ? total : (uint256(total) * elapsed) / duration;
        vm.warp(uint256(start) + elapsed);

        if (expected == 0) {
            // Nothing vested yet -> claim must revert, not silently pay zero.
            vm.prank(recipient);
            vm.expectRevert(abi.encodeWithSignature("NothingToClaim()"));
            router.claim(0);
        } else {
            vm.prank(recipient);
            router.claim(0);
            assertEq(token.balanceOf(recipient), expected);
        }
    }
}
