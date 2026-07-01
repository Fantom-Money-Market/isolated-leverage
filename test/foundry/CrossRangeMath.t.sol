// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "./harness/MockCLPool.sol";
import "./harness/CrossRangeHarness.sol";
import "../../contracts/Stratus-ALM/test/MockERC20.sol";
import "../../contracts/Stratus-ALM/libraries/TickMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Fuzz coverage for the bespoke cross-range allocation math (StratusCLVaultBase).
///         The headline property comes straight from a live bug report: previewRebalance()
///         used to report a "two-sided deficit" (need0>0 AND need1>0 simultaneously) because
///         splitting the idle pot by weight forced every range to the same global ratio,
///         double-counting cross-range misallocation as missing external inventory. The fix
///         made the result strictly one-sided; this suite fuzzes that property across random
///         ticks, spot/TWAP divergence, per-range position sizes, and idle balances.
///
///   forge test --match-contract CrossRangeMathTest -vv
contract CrossRangeMathTest is Test {
    MockERC20 token0;
    MockERC20 token1;
    MockCLPool pool;
    CrossRangeHarness harness;

    int24 constant TICK_SPACING = 50;
    int24 constant TICK_BOUND = 850_000; // safely inside TickMath's +-887272 with range-width margin

    function setUp() public {
        MockERC20 a = new MockERC20("Token A", "A");
        MockERC20 b = new MockERC20("Token B", "B");
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

        pool = new MockCLPool(address(token0), address(token1), 3000, TICK_SPACING);
        pool.setSlot0(TickMath.getSqrtRatioAtTick(0), 0);
        pool.setTwapTick(0);

        // upwardBias=100 (symmetric ranges); asymmetric bias (50/200) is already covered by
        // the Hardhat edge-case fork suite (test/stratus/edge-cases.fork.test.ts).
        harness = new CrossRangeHarness(address(this), address(pool), 100, 5);
    }

    function _boundTick(int24 t) internal pure returns (int24) {
        return int24(bound(int256(t), -int256(TICK_BOUND), int256(TICK_BOUND)));
    }

    /// @dev THE regression property: previewRebalance() must never report a simultaneous
    ///      two-sided deficit (or surplus) — exactly one of {balanced, need0+surplus1,
    ///      need1+surplus0} holds, for any tick, spot/TWAP divergence, per-range position
    ///      size, or idle balance.
    function testFuzz_previewRebalance_oneSided(
        int24 twapTick,
        int24 spotDriftTicks,
        uint128 liq0,
        uint128 liq1,
        uint128 liq2,
        uint96 idle0,
        uint96 idle1
    ) public {
        twapTick = _boundTick(twapTick);
        int256 drift = bound(int256(spotDriftTicks), -50_000, 50_000);
        int24 spotTick = _boundTick(int24(int256(twapTick) + drift));

        pool.setSlot0(TickMath.getSqrtRatioAtTick(spotTick), spotTick);
        pool.setTwapTick(twapTick);

        liq0 = uint128(bound(liq0, 0, 1e30));
        liq1 = uint128(bound(liq1, 0, 1e30));
        liq2 = uint128(bound(liq2, 0, 1e30));
        pool.setPosition(harness.rangeLower(0), harness.rangeUpper(0), liq0, 0, 0);
        pool.setPosition(harness.rangeLower(1), harness.rangeUpper(1), liq1, 0, 0);
        pool.setPosition(harness.rangeLower(2), harness.rangeUpper(2), liq2, 0, 0);

        idle0 = uint96(bound(idle0, 0, 1e30));
        idle1 = uint96(bound(idle1, 0, 1e30));
        if (idle0 > 0) token0.mint(address(harness), idle0);
        if (idle1 > 0) token1.mint(address(harness), idle1);

        (uint256 need0, uint256 need1, uint256 surplus0, uint256 surplus1) = harness.previewRebalance();

        // The exact property the live bug violated: never a simultaneous two-sided deficit,
        // and never a simultaneous two-sided surplus. (need0 can legitimately floor to 0 while
        // surplus1 is the full one-sided amount when A0 is dust relative to A1 — that's still
        // one-sided, just sub-wei on the deficit side, so this must NOT require need0>0
        // strictly whenever surplus1>0.)
        assertFalse(need0 > 0 && need1 > 0, "previewRebalance reported a simultaneous two-sided deficit");
        assertFalse(surplus0 > 0 && surplus1 > 0, "previewRebalance reported a simultaneous two-sided surplus");
    }

    /// @dev The balancing-swap quote can never ask the caller for more surplus token than
    ///      the vault actually holds.
    function testFuzz_quoteSwap_neverExceedsSurplus(
        uint128 surplusBal,
        uint128 deficitBal,
        uint128 needDeficit,
        uint128 priceSurplusInDeficit
    ) public view {
        surplusBal = uint128(bound(surplusBal, 1, type(uint96).max));
        deficitBal = uint128(bound(deficitBal, 0, type(uint96).max));
        needDeficit = uint128(bound(needDeficit, 1, type(uint96).max));
        priceSurplusInDeficit = uint128(bound(priceSurplusInDeficit, 1e9, 1e27));

        (uint256 surplusOut, ) = harness.exposeQuoteSwap(surplusBal, deficitBal, needDeficit, priceSurplusInDeficit);

        assertLe(surplusOut, surplusBal, "quote asked for more surplus than the vault holds");
    }

    /// @dev Sanity-checked earlier by hand for the clean one-sided case (deficitBal=0): the
    ///      quote should use roughly HALF the surplus to balance, not all of it (1:1 OTC would
    ///      just recreate the original imbalance on the other side). Fuzzed here across a wide
    ///      range of surplus sizes and prices.
    function testFuzz_quoteSwap_halfOfSurplus_cleanCase(uint128 surplusBal, uint128 price) public view {
        // surplusBal floor is set so needDeficit = surplusBal*price/1e18 can't dust to 0 even
        // at the lowest fuzzed price (1e9) — that degenerate case isn't what this property is
        // about (it's covered separately: a needDeficit==0 quote is correctly a no-op).
        surplusBal = uint128(bound(surplusBal, 1e15, type(uint96).max));
        price = uint128(bound(price, 1e9, 1e27));

        uint256 needDeficit = Math.mulDiv(surplusBal, price, 1e18);
        (uint256 surplusOut, ) = harness.exposeQuoteSwap(surplusBal, 0, needDeficit, price);

        assertApproxEqRel(surplusOut, uint256(surplusBal) / 2, 0.01e18, "clean one-sided quote should use ~half the surplus");
    }
}
