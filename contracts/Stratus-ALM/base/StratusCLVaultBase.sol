// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./StratusVaultBase.sol";
import "../libraries/TickMath.sol";
import "../libraries/LiquidityAmounts.sol";
import "../../helpers/UniswapV3PriceHelper.sol";

/// @notice Read-only surface common to every Uniswap-V3-style CL pool (Shadow, Thick).
///         The MUTATING ops (mint/burn/collect) differ between forks — Shadow threads a
///         `uint256 index`, vanilla Uni V3 does not — so those are left abstract.
interface ICLPoolView {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
    function positions(bytes32 key)
        external
        view
        returns (uint128 liquidity, uint256, uint256, uint128 tokensOwed0, uint128 tokensOwed1);
}

/// @title StratusCLVaultBase
/// @notice Shared concentrated-liquidity engine for Stratus ALPT vaults: three weighted
///         overlapping ranges managed DIRECTLY through the pool (Gamma Hypervisor model,
///         no NFTs), TWAP-based manipulation-resistant valuation, rebalancing, and
///         fee realization. Identical for every Uni-V3-style fork.
/// @dev A fork is plugged in by implementing only the four raw pool ops below. Everything
///      that touches share accounting, valuation, or rewards lives in StratusVaultBase and
///      is therefore guaranteed identical across forks.
abstract contract StratusCLVaultBase is StratusVaultBase {
    using SafeERC20 for IERC20;

    // ----- pool -----
    address public immutable pool;
    int24 public immutable tickSpacing;
    uint24 public immutable poolFee;

    // ----- positions (3 weighted overlapping ranges) -----
    uint256 internal constant N_RANGES = 3;
    /// @dev Reference liquidity scale for cross-range allocation; cancels out of the result,
    ///      only keeps intermediate token amounts above dust.
    uint256 internal constant REQ_SCALE = 1e15;
    uint256 internal constant Q96 = 0x1000000000000000000000000; // 2**96
    int24[3] public rangeLower;
    int24[3] public rangeUpper;

    bool internal mintCalled; // guards uniswapV3MintCallback

    event Rebalance(int24 tick, uint256 total0, uint256 total1);
    event FeesCollected(uint256 fees0, uint256 fees1, uint256 protocol0, uint256 protocol1);
    event RebalanceSwap(address indexed caller, address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut);

    // Swap-rebalance economics — operator-tunable via setRebalanceParams (factory-gated).
    /// @notice Max spot-vs-TWAP price divergence (bps) tolerated by rebalanceViaSwap (manip guard).
    uint256 public deviationCapBps = 50; // 0.5%
    /// @notice Fallback bounty: a surplus-token premium (bps), paid from equity only when there
    ///         are no gauge rewards to pay from. Small, to bound the principal "slow bleed".
    uint256 public bountyBps = 10; // 0.1%
    /// @notice Preferred bounty: a cut (bps) of the freshly-harvested gauge rewards, paid to the
    ///         rebalancer in the reward token — comes from yield, not principal (no bleed).
    uint256 public rewardBountyBps = 200; // 2% of the harvest
    /// @notice Min skew (bps) for a swap-rebalance: the pot's dominant token must be at least this
    ///         share of total value, else revert. This is the SOLE anti-drain gate — and it is
    ///         self-limiting: a swap balances the pot, so the next call sees skew < threshold and
    ///         reverts. There is deliberately NO time cooldown: the vault must be free to rebalance
    ///         whenever it is genuinely skewed (e.g. every block during a fast move / out-of-range);
    ///         a time lock would strand it out-of-range. A tiny per-trade drift never trips it.
    uint256 public minSkewBps = 8000; // 80%

    event RebalanceParamsSet(uint256 deviationCapBps, uint256 bountyBps, uint256 rewardBountyBps, uint256 minSkewBps);

    error Deviation();
    error Balanced();
    error BadCallback();
    error Overflow();
    error NotSkewed();

    constructor(
        address _factory,
        address _pool,
        uint256 _upwardBias,
        uint8 _protocolFee,
        string memory _name,
        string memory _symbol
    )
        StratusVaultBase(
            _factory,
            ICLPoolView(_pool).token0(),
            ICLPoolView(_pool).token1(),
            _upwardBias,
            _protocolFee,
            _name,
            _symbol
        )
    {
        pool = _pool;
        tickSpacing = ICLPoolView(_pool).tickSpacing();
        poolFee = ICLPoolView(_pool).fee();

        (, int24 tick, , , , , ) = ICLPoolView(_pool).slot0();
        _setRanges(tick);
    }

    // ===================== FORK HOOKS (the only per-venue code) =====================

    /// @notice Live position state for the vault's (this, [index,] tickLower, tickUpper).
    function _clPosition(int24 tickLower, int24 tickUpper)
        internal
        view
        virtual
        returns (uint128 liquidity, uint128 tokensOwed0, uint128 tokensOwed1);

    /// @notice Mint `liquidity`; the pool calls back uniswapV3MintCallback to pull payment.
    function _clMint(int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        virtual
        returns (uint256 amount0, uint256 amount1);

    /// @notice Burn `liquidity` (amount=0 forces a fee recompute before collect).
    function _clBurn(int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        virtual
        returns (uint256 owed0, uint256 owed1);

    /// @notice Collect owed tokens (fees and/or burned principal) for a position.
    function _clCollect(int24 tickLower, int24 tickUpper, address to, uint128 c0, uint128 c1)
        internal
        virtual
        returns (uint256 amount0, uint256 amount1);

    // ===================== VENUE-HOOK IMPLEMENTATIONS =====================

    /// @inheritdoc StratusVaultBase
    function _safeValuation() internal view override returns (uint256 total0, uint256 total1, uint256 price) {
        // One observe(): reuse the TWAP tick for both the position split and the price.
        int24 twapTick = UniswapV3PriceHelper.getTWAPTick(pool, TWAP_PERIOD);
        (total0, total1) = _totalAmountsAtSqrt(TickMath.getSqrtRatioAtTick(twapTick));
        price = UniswapV3PriceHelper.tickToPrice(twapTick);
    }

    /// @inheritdoc StratusVaultBase
    function _totalAmountsSpot() internal view override returns (uint256 total0, uint256 total1) {
        (uint160 sqrtP, , , , , , ) = ICLPoolView(pool).slot0();
        (total0, total1) = _totalAmountsAtSqrt(sqrtP);
    }

    /// @inheritdoc StratusVaultBase
    function _spotPrice() internal view override returns (uint256) {
        return UniswapV3PriceHelper.getSpotPrice(pool);
    }

    /// @inheritdoc StratusVaultBase
    function _withdrawPositions(uint256 shares, uint256 total, address to)
        internal
        override
        returns (uint256 amount0, uint256 amount1)
    {
        for (uint256 i = 0; i < N_RANGES; i++) {
            (uint128 liq, , ) = _clPosition(rangeLower[i], rangeUpper[i]);
            uint128 liqToBurn = uint128(Math.mulDiv(liq, shares, total));
            if (liqToBurn > 0) {
                (uint256 a0, uint256 a1) = _burnLiquidity(rangeLower[i], rangeUpper[i], liqToBurn, to, false);
                amount0 += a0;
                amount1 += a1;
            }
        }
    }

    /// @notice Realize trading fees for all ranges and skim the protocol cut. The net
    ///         stays as idle balance and is compounded on the next rebalance.
    /// @dev burn(0) forces the pool to recompute owed fees; collect pulls them. On a
    ///      gauged pool (Shadow) fees route to the FeeCollector, so this yields ~0 and the
    ///      LP earns emissions instead. On a fee-only pool (Thick) this is the yield.
    function _realizeFees() internal override {
        uint256 totalFee0;
        uint256 totalFee1;
        for (uint256 i = 0; i < N_RANGES; i++) {
            (uint128 liq, , ) = _clPosition(rangeLower[i], rangeUpper[i]);
            if (liq == 0) continue;
            _clBurn(rangeLower[i], rangeUpper[i], 0);
            (uint256 owed0, uint256 owed1) =
                _clCollect(rangeLower[i], rangeUpper[i], address(this), type(uint128).max, type(uint128).max);
            if (owed0 == 0 && owed1 == 0) continue;
            uint256 fee0 = (owed0 * protocolFee) / 100;
            uint256 fee1 = (owed1 * protocolFee) / 100;
            if (fee0 > 0) token0.safeTransfer(factory, fee0);
            if (fee1 > 0) token1.safeTransfer(factory, fee1);
            totalFee0 += fee0;
            totalFee1 += fee1;
        }
        if (totalFee0 > 0 || totalFee1 > 0) emit FeesCollected(totalFee0, totalFee1, totalFee0, totalFee1);
    }

    // ===================== REBALANCE =====================

    /// @notice Realize fees, withdraw all liquidity, recompute ranges around the TWAP
    ///         tick, and redeploy idle balances by weight. Keeper/factory only.
    /// @dev No in-vault swap: leftover from ratio mismatch stays idle and is counted in
    ///      getTotalAmounts. This is the "recenter + redeploy what's idle" primitive, not
    ///      the main rebalancing path — that's rebalanceViaSwap() below, which is
    ///      permissionless and actually closes a one-sided imbalance via a swap.
    function deployIdle() external override onlyFactory nonReentrant whenNotPaused {
        _realizeFees();
        _burnAll();
        int24 tick = UniswapV3PriceHelper.getTWAPTick(pool, TWAP_PERIOD);
        _setRanges(tick);
        _deployByWeight();
        emit Rebalance(tick, token0.balanceOf(address(this)), token1.balanceOf(address(this)));
    }

    /// @notice Permissionless, swap-funded rebalance — the "agnostic quirk". Anyone (a keeper,
    ///         a flash-loaner, a layer built on top) can balance the idle inventory by being the
    ///         swap counterparty: they hand over the deficit token and receive the surplus token
    ///         plus a small bounty, at the spot price, after which the vault deploys fully. The
    ///         vault never references any lending market — it just offers an oracle-priced swap
    ///         with a tip. Value-preserving except the bounty (a bounded cost of rebalancing).
    /// @dev Swap executes at SPOT, gated by a max-divergence-from-TWAP circuit breaker, so a
    ///      manipulated spot is rejected. Quote it first with previewRebalanceSwap.
    /// @param maxIn Max deficit token the caller will provide (partial swap if the full balance
    ///        needs more). @param minOut Min surplus token the caller will accept (slippage).
    function rebalanceViaSwap(uint256 maxIn, uint256 minOut)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amountIn, uint256 amountOut)
    {
        _realizeFees();

        // Manipulation guard: spot must be within DEVIATION_CAP_BPS of the TWAP.
        uint256 pSpot = UniswapV3PriceHelper.getSpotPrice(pool);
        if (!_withinDeviation(pSpot)) revert Deviation();

        (uint256 need0, uint256 need1, , ) = previewRebalance();
        bool callerProvides1 = need1 > 0;
        if (!callerProvides1 && need0 == 0) revert Balanced();

        // Anti-drain gate: only allow when the pot is genuinely one-sided (dominant token's value
        // share >= minSkewBps). Checked pre-burn so a non-skewed call fails before any harvest/burn.
        {
            (uint256 tot0, uint256 tot1) = getTotalAmounts();
            uint256 v0 = Math.mulDiv(tot0, pSpot, PRECISION); // token0 value in token1 terms
            uint256 totalV = v0 + tot1;
            uint256 dom = v0 > tot1 ? v0 : tot1;
            if (totalV == 0 || dom * BASIS_POINTS < totalV * minSkewBps) revert NotSkewed();
        }

        // Preferred bounty: a cut of freshly-harvested gauge rewards (from yield, no bleed).
        // Harvest while the positions are still deployed; falls back to a surplus-token
        // premium below only if no reward accrued. Venue-agnostic: the base default is "no
        // venue rewards" (Thick), so it always takes the fallback.
        bool rewarded = _payRebalanceBounty(msg.sender);

        _burnAll();

        // Fair swap (no premium) on the now-idle inventory, priced at spot.
        uint256 bal0 = token0.balanceOf(address(this));
        uint256 bal1 = token1.balanceOf(address(this));
        if (callerProvides1) {
            (amountOut, amountIn) = _quoteSwap(bal0, bal1, need1, pSpot);
        } else {
            (amountOut, amountIn) = _quoteSwap(bal1, bal0, need0, Math.mulDiv(PRECISION, PRECISION, pSpot));
        }
        if (amountIn == 0) revert Balanced();

        // Fallback bounty: only if no gauge reward was paid, add the surplus-token premium.
        if (!rewarded) amountOut += Math.mulDiv(amountOut, bountyBps, BASIS_POINTS);

        // Cap by the caller's budget (partial swap leaves a little idle — fine).
        if (amountIn > maxIn) {
            amountOut = Math.mulDiv(amountOut, maxIn, amountIn);
            amountIn = maxIn;
        }
        if (amountOut < minOut) revert Slippage();

        if (callerProvides1) {
            token1.safeTransferFrom(msg.sender, address(this), amountIn);
            token0.safeTransfer(msg.sender, amountOut);
            emit RebalanceSwap(msg.sender, address(token1), amountIn, address(token0), amountOut);
        } else {
            token0.safeTransferFrom(msg.sender, address(this), amountIn);
            token1.safeTransfer(msg.sender, amountOut);
            emit RebalanceSwap(msg.sender, address(token0), amountIn, address(token1), amountOut);
        }

        int24 tick = UniswapV3PriceHelper.getTWAPTick(pool, TWAP_PERIOD);
        _setRanges(tick);
        _deployByWeight();
        emit Rebalance(tick, token0.balanceOf(address(this)), token1.balanceOf(address(this)));
    }

    function _withinDeviation(uint256 pSpot) internal view returns (bool) {
        uint256 pTwap = UniswapV3PriceHelper.getTWAPPrice(pool, TWAP_PERIOD);
        if (pTwap == 0) return false;
        uint256 dev = pSpot > pTwap ? pSpot - pTwap : pTwap - pSpot;
        return dev * BASIS_POINTS <= pTwap * deviationCapBps;
    }

    /// @notice Hook: pay the rebalance bounty from venue rewards (e.g. gauge emissions),
    ///         returning whether it did. Default (Thick / no gauge): false → the caller gets
    ///         the surplus-token premium fallback instead. Shadow overrides to harvest the gauge.
    function _payRebalanceBounty(address) internal virtual returns (bool) {
        return false;
    }

    error InvalidRebalanceParam();

    /// @notice Tune the swap-rebalance economics (factory-gated). Bounds keep them sane:
    ///         deviation <= 10%, fallback bounty <= 2%, reward bounty <= 30%, cooldown <= 1 day.
    function setRebalanceParams(
        uint256 _deviationCapBps,
        uint256 _bountyBps,
        uint256 _rewardBountyBps,
        uint256 _minSkewBps
    ) external onlyFactory {
        if (_deviationCapBps > 1000 || _bountyBps > 200 || _rewardBountyBps > 3000 || _minSkewBps > BASIS_POINTS) {
            revert InvalidRebalanceParam();
        }
        deviationCapBps = _deviationCapBps;
        bountyBps = _bountyBps;
        rewardBountyBps = _rewardBountyBps;
        minSkewBps = _minSkewBps;
        emit RebalanceParamsSet(_deviationCapBps, _bountyBps, _rewardBountyBps, _minSkewBps);
    }

    /// @notice Quote the balancing swap rebalanceViaSwap would execute right now: the caller
    ///         provides `amountIn` of one token and receives `amountOut` of the other (incl. the
    ///         bounty). `callerProvidesToken1` says which side. Estimate (pre-burn), like previewRebalance.
    function previewRebalanceSwap()
        external
        view
        returns (bool callerProvidesToken1, uint256 amountIn, uint256 amountOut)
    {
        (uint256 need0, uint256 need1, , ) = previewRebalance();
        uint256 pSpot = UniswapV3PriceHelper.getSpotPrice(pool);
        (uint160 sqrtP, , , , , , ) = ICLPoolView(pool).slot0();
        (uint256 bal0, uint256 bal1) = _totalAmountsAtSqrt(sqrtP);
        if (need1 > 0) {
            (amountOut, amountIn) = _quoteSwap(bal0, bal1, need1, pSpot);
            callerProvidesToken1 = true;
        } else if (need0 > 0) {
            (amountOut, amountIn) = _quoteSwap(bal1, bal0, need0, Math.mulDiv(PRECISION, PRECISION, pSpot));
        }
    }

    /// @dev Balancing-swap quote. `surplusBal`/`deficitBal` are the over-/under-weight token
    ///      balances, `needDeficit` the deficit to fully deploy (from previewRebalance), and
    ///      `priceSurplusInDeficit` the surplus token's price in deficit-token terms (1e18).
    /// @return surplusOut surplus token to hand the caller at FAIR value (bounty added by caller)
    /// @return deficitIn  deficit token pulled from the caller (fair value)
    function _quoteSwap(uint256 surplusBal, uint256 deficitBal, uint256 needDeficit, uint256 priceSurplusInDeficit)
        internal
        pure
        returns (uint256 surplusOut, uint256 deficitIn)
    {
        if (needDeficit == 0 || surplusBal == 0 || priceSurplusInDeficit == 0) return (0, 0);
        // Target balanced ratio (deficit per surplus, 1e18): deploying all surplus needs
        // (deficitBal + needDeficit) of the deficit token. Swapping toward it (rather than
        // injecting) also shrinks the surplus, so the swap is smaller than needDeficit.
        uint256 rs = Math.mulDiv(deficitBal + needDeficit, PRECISION, surplusBal);
        surplusOut = Math.mulDiv(needDeficit, PRECISION, rs + priceSurplusInDeficit); // surplus token, fair
        deficitIn = Math.mulDiv(surplusOut, priceSurplusInDeficit, PRECISION);
    }

    /// @dev Burn all current range liquidity into idle (teardown half of a rebalance).
    function _burnAll() internal {
        for (uint256 i = 0; i < N_RANGES; i++) {
            (uint128 liq, , ) = _clPosition(rangeLower[i], rangeUpper[i]);
            if (liq > 0) {
                _burnLiquidity(rangeLower[i], rangeUpper[i], liq, address(this), true);
            }
        }
    }

    /// @dev Deploy the idle pot across the current ranges by CAPITAL weight (_weight(i), e.g.
    ///      50/30/20 narrow/medium/wide) — each range takes its OWN natural token mix at spot,
    ///      pre-scaled by _reqAtRange so the range's VALUE (not raw liquidity) matches its
    ///      weight, then all ranges are scaled together by one global factor so the binding
    ///      token is fully used. (An earlier version split each token by weight directly,
    ///      forcing every range to the global ratio and stranding inventory on whichever side
    ///      each range didn't bind — a misallocation that masqueraded as a two-sided deficit.
    ///      A later bug fed the weight straight in as a liquidity unit count instead of a
    ///      value share, which silently inverted the split since wide ranges need far more
    ///      token amount per unit of liquidity than narrow ones — see _reqAtRange.)
    function _deployByWeight() internal {
        (uint160 sqrtP, , , , , , ) = ICLPoolView(pool).slot0();
        uint256 bal0 = token0.balanceOf(address(this));
        uint256 bal1 = token1.balanceOf(address(this));

        // Token amounts each weighted range wants at a common reference scale.
        uint256[N_RANGES] memory req0;
        uint256[N_RANGES] memory req1;
        uint256 A0;
        uint256 A1;
        for (uint256 i = 0; i < N_RANGES; i++) {
            (req0[i], req1[i]) = _reqAtRange(rangeLower[i], rangeUpper[i], sqrtP, _weight(i));
            A0 += req0[i];
            A1 += req1[i];
        }

        // One scale factor so the binding token is fully deployed. The other side, if any, is the
        // genuine one-sided global imbalance — it stays idle (or is swapped separately). A small
        // buffer + round-down getLiquidityForAmounts keep the total within balances (mint rounds up).
        uint256 f0 = A0 == 0 ? type(uint256).max : Math.mulDiv(bal0, PRECISION, A0);
        uint256 f1 = A1 == 0 ? type(uint256).max : Math.mulDiv(bal1, PRECISION, A1);
        uint256 f = f0 < f1 ? f0 : f1;
        if (f == 0 || f == type(uint256).max) return;
        f = Math.mulDiv(f, BASIS_POINTS - 10, BASIS_POINTS); // 0.1% buffer for per-range mint round-up

        for (uint256 i = 0; i < N_RANGES; i++) {
            uint256 b0 = Math.mulDiv(req0[i], f, PRECISION);
            uint256 b1 = Math.mulDiv(req1[i], f, PRECISION);
            uint128 liq = _liquidityForAmounts(rangeLower[i], rangeUpper[i], b0, b1);
            if (liq > 0) {
                _mintLiquidity(rangeLower[i], rangeUpper[i], liq, 0, 0);
            }
        }
    }

    /// @dev Token0/token1 a range of weight `w` wants, sized so the range's VALUE (not raw
    ///      liquidity) is proportional to `w`. First computes this range's natural token mix
    ///      at a fixed reference liquidity (REQ_SCALE), values that mix in token1 terms at
    ///      the current price, then scales by w/refValue.
    /// @dev Uniswap V3 liquidity is not value-linear across range widths — a wide range needs
    ///      far more token amount than a narrow one to represent the same liquidity (that's
    ///      the whole point of concentration). Scaling by raw liquidity units alone (feeding
    ///      w*REQ_SCALE directly into getAmountsForLiquidity, the previous implementation)
    ///      silently inverted the intended weight split: the nominal 50/30/20 (narrow/medium/
    ///      wide) weights actually deployed ~13/31/56 of real capital, because the wide range
    ///      consumes disproportionately more tokens per unit of liquidity. Scaling by value
    ///      instead makes the deployed capital share match the configured weight directly.
    function _reqAtRange(int24 lower, int24 upper, uint160 sqrtP, uint256 w)
        internal
        pure
        returns (uint256 r0, uint256 r1)
    {
        (uint256 u0, uint256 u1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtP,
            TickMath.getSqrtRatioAtTick(lower),
            TickMath.getSqrtRatioAtTick(upper),
            uint128(REQ_SCALE)
        );
        uint256 refValue = u1 + Math.mulDiv(u0, _priceAtSqrt(sqrtP), PRECISION);
        if (refValue == 0) return (0, 0);
        r0 = Math.mulDiv(u0, w * REQ_SCALE, refValue);
        r1 = Math.mulDiv(u1, w * REQ_SCALE, refValue);
    }

    /// @dev sqrtPriceX96 -> token0-in-token1 price (1e18 scale). Same formula as
    ///      UniswapV3PriceHelper._sqrtPriceX96ToPrice, inlined here since that helper is
    ///      private to its library and this avoids an extra external call per range.
    function _priceAtSqrt(uint160 sqrtP) internal pure returns (uint256 price) {
        uint256 ratioX96 = Math.mulDiv(uint256(sqrtP), uint256(sqrtP), Q96);
        price = Math.mulDiv(ratioX96, PRECISION, Q96);
    }

    /// @notice Preview the next rebalance's GENUINE token imbalance. After a full burn the vault
    ///         is one idle pot; deploying by capital weight (see _deployByWeight) uses the
    ///         binding token fully and leaves the OTHER side over. This reports that one-sided
    ///         residual: `need*` is how much of the deficit token to inject to deploy everything,
    ///         `surplus*` is what stays idle if nothing is injected. Exactly one of need0/need1
    ///         (and of surplus0/surplus1) is non-zero — it is a global ratio mismatch between the
    ///         idle pot and what the ranges collectively want, never a simultaneous two-sided
    ///         deficit (that earlier artefact was per-range misallocation, now fixed internally).
    /// @dev Estimate over idle + current positions, at the TWAP-tick ranges (as rebalance sets
    ///      them) and spot price (as it deploys). Ignores the small protocol-fee skim on fees.
    function previewRebalance()
        public
        view
        returns (uint256 need0, uint256 need1, uint256 surplus0, uint256 surplus1)
    {
        int24 twapTick = UniswapV3PriceHelper.getTWAPTick(pool, TWAP_PERIOD);
        (uint160 sqrtP, , , , , , ) = ICLPoolView(pool).slot0();
        // total deployable after a full burn = positions (at spot) + owed + idle
        (uint256 bal0, uint256 bal1) = _totalAmountsAtSqrt(sqrtP);

        // Aggregate token mix the weighted ranges collectively want (wanted ratio R = A1/A0).
        uint256 A0;
        uint256 A1;
        for (uint256 i = 0; i < N_RANGES; i++) {
            (int24 lower, int24 upper) = _computeRange(i, twapTick);
            (uint256 r0, uint256 r1) = _reqAtRange(lower, upper, sqrtP, _weight(i));
            A0 += r0;
            A1 += r1;
        }
        if (A0 == 0 || A1 == 0) return (0, 0, 0, 0);

        // Compare the idle ratio bal1/bal0 to the wanted ratio A1/A0 (cross-multiplied).
        uint256 wantT1 = Math.mulDiv(bal0, A1, A0); // token1 needed to balance against bal0 of token0
        if (bal1 < wantT1) {
            // token0 surplus, token1 deficit (one-sided)
            need1 = wantT1 - bal1;
            surplus0 = bal0 - Math.mulDiv(bal1, A0, A1);
        } else if (bal1 > wantT1) {
            // token1 surplus, token0 deficit (one-sided)
            need0 = Math.mulDiv(bal1, A0, A1) - bal0;
            surplus1 = bal1 - wantT1;
        }
    }

    // ===================== POSITION PRIMITIVES =====================

    function _totalAmountsAtSqrt(uint160 sqrtRatioX96) internal view returns (uint256 total0, uint256 total1) {
        for (uint256 i = 0; i < N_RANGES; i++) {
            (uint128 liq, uint128 owed0, uint128 owed1) = _clPosition(rangeLower[i], rangeUpper[i]);
            (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtRatioX96,
                TickMath.getSqrtRatioAtTick(rangeLower[i]),
                TickMath.getSqrtRatioAtTick(rangeUpper[i]),
                liq
            );
            total0 += a0 + owed0;
            total1 += a1 + owed1;
        }
        total0 += token0.balanceOf(address(this));
        total1 += token1.balanceOf(address(this));
    }

    function _mintLiquidity(int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 min0, uint256 min1)
        internal
    {
        if (liquidity == 0) return;
        mintCalled = true;
        (uint256 amount0, uint256 amount1) = _clMint(tickLower, tickUpper, liquidity);
        if (amount0 < min0 || amount1 < min1) revert Slippage();
    }

    function _burnLiquidity(int24 tickLower, int24 tickUpper, uint128 liquidity, address to, bool collectAll)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        if (liquidity == 0) return (0, 0);

        uint128 c0;
        uint128 c1;
        {
            // pool.burn has no swap, so owed amounts are exact. Cap the collect to the
            // burned principal unless collectAll (rebalance teardown sweeps fees too).
            (uint256 owed0, uint256 owed1) = _clBurn(tickLower, tickUpper, liquidity);
            c0 = collectAll ? type(uint128).max : _toUint128(owed0);
            c1 = collectAll ? type(uint128).max : _toUint128(owed1);
        }
        if (c0 > 0 || c1 > 0) {
            (amount0, amount1) = _clCollect(tickLower, tickUpper, to, c0, c1);
        }
    }

    /// @notice Pool mint callback: pay what is owed from the vault's balance.
    /// @dev Shadow and Thick pools both call this exact selector.
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external {
        if (msg.sender != pool) revert BadCallback();
        if (!mintCalled) revert BadCallback();
        mintCalled = false;
        if (amount0Owed > 0) token0.safeTransfer(pool, amount0Owed);
        if (amount1Owed > 0) token1.safeTransfer(pool, amount1Owed);
    }

    function _liquidityForAmounts(int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1)
        internal
        view
        returns (uint128)
    {
        (uint160 sqrtP, , , , , , ) = ICLPoolView(pool).slot0();
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtP,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            amount0,
            amount1
        );
    }

    // ===================== RANGES =====================

    function _setRanges(int24 currentTick) internal {
        for (uint256 i = 0; i < N_RANGES; i++) {
            (rangeLower[i], rangeUpper[i]) = _computeRange(i, currentTick);
        }
    }

    /// @dev Pure range computation (no state write) — shared by _setRanges and previewRebalance.
    function _computeRange(uint256 i, int24 currentTick) internal view returns (int24 lower, int24 upper) {
        int24 w = tickSpacing * _halfWidthMult(i);
        // Asymmetric: bias the lower side by upwardBias (100 = symmetric).
        int24 lowerW = int24((int256(w) * int256(upwardBias)) / 100);
        lower = _align(currentTick - lowerW);
        upper = _align(currentTick + w);
        if (lower >= upper) upper = lower + tickSpacing;
    }

    /// @dev Align a tick DOWN to the nearest multiple of tickSpacing. Solidity integer
    ///      division truncates toward zero, which for negative ticks rounds UP — so a bare
    ///      (tick / tickSpacing) * tickSpacing would misplace ranges on the negative side of
    ///      the price. Adjust by one spacing when there's a negative remainder to true-floor.
    function _align(int24 tick) internal view returns (int24) {
        int24 aligned = (tick / tickSpacing) * tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) aligned -= tickSpacing;
        return aligned;
    }

    function _halfWidthMult(uint256 i) private pure returns (int24) {
        if (i == 0) return 10;  // narrow
        if (i == 1) return 40;  // medium
        return 120;             // wide
    }

    function _weight(uint256 i) private pure returns (uint256) {
        if (i == 0) return 5000; // 50%
        if (i == 1) return 3000; // 30%
        return 2000;             // 20%
    }

    function _toUint128(uint256 x) internal pure returns (uint128) {
        if (x > type(uint128).max) revert Overflow();
        return uint128(x);
    }
}
