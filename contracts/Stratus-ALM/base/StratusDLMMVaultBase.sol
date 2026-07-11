// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./StratusVaultBase.sol";
import "../interfaces/ILBPair.sol";
import "../libraries/LiquidityBookMath.sol";

/// @title StratusDLMMVaultBase
/// @notice Bin-based sibling to StratusCLVaultBase: manages a Metropolis (Trader Joe
///         Liquidity Book) DLMM position instead of a Uniswap-V3-style tick range.
///         Share accounting, valuation surface, pause, and reward accumulator all come
///         from StratusVaultBase unchanged; this layer supplies bin-specific mint/burn/
///         valuation and (optionally) harvests a Metropolis "reward hook" that pays an
///         emission token to whichever bins currently sit in its rewarded range.
/// @dev KEY STRUCTURAL DIFFERENCE from CL: an LB bin is not a curve position — each bin
///      is a constant-sum pot with EXACT, unambiguous reserves (getBin(id)). That makes
///      the vault's token0/token1 AMOUNTS unambiguous regardless of price (no spot-vs-TWAP
///      split needed for amounts, unlike CL); only the PRICE used to value those amounts
///      in one unit (getTotalValueSafe) needs a manipulation-resistant source (the LB
///      built-in oracle, falling back to spot on a low-activity pair).
/// @dev ALSO STRUCTURAL: every bin strictly above the active id is 100% token0 (X), every
///      bin strictly below is 100% token1 (Y) — only the active bin itself holds a mix.
///      That means deploying idle balances into the bin window wastes nothing regardless
///      of the token0:token1 ratio on hand (each side deploys independently into its own
///      bins) — DLMM has none of CL's "one-sided imbalance stays idle" problem, so there
///      is no swap-funded rebalance here. The only real rebalancing need is RECENTERING
///      the bin window as the active bin drifts, which deployIdle()/rebalance() both do
///      in full (burn old window, recenter, redeploy 100% of whatever's on hand).
/// @dev Active-bin minting: LB accepts any X:Y into the active bin and trims to the live
///      reserve ratio (refunding leftovers). Off-ratio deposits cost composition fees, they
///      do NOT cause PackedUint128Math__SubUnderflow. The vault mints the active bin in a
///      dedicated dual-token pair.mint() (distributionX = distributionY = 1e18), optionally
///      pre-capped to getBin(activeId)'s ry/rx to minimize those fees. Outer bins stay on
///      the single-sided one-bin-per-mint path.
abstract contract StratusDLMMVaultBase is StratusVaultBase {
    using SafeERC20 for IERC20;

    // ----- pair -----
    ILBPair public immutable pair;
    uint16 public immutable binStep;

    /// @notice The Metropolis reward-hook attached to this pair at construction (address(0)
    ///         if none). Resolved from the pair's own hooksParameters, not hardcoded, and
    ///         re-syncable via refreshHook() if it's ever changed.
    ILBHooksRewarder public hook;

    // ----- bin window -----
    /// @dev How many extra bins each side of the (owner-configurable) rewarded range get
    ///      depth, purely for fee income — they earn no hook emissions but still take
    ///      swap flow as price moves through them before the next recenter.
    uint256 internal constant OUTER_BINS_EACH_SIDE = 5;
    /// @dev Share of deploy weight concentrated into the rewarded range (or, with no hook,
    ///      the single active bin) — the rest spreads evenly across the outer depth bins.
    uint256 internal constant REWARDED_WEIGHT_BPS = 5000;

    uint24[] public binIds;
    uint256 internal rewardedBinStart;
    uint256 internal rewardedBinEnd;

    /// @notice Ratchets up only — a temporary value drawdown must never make the next
    ///         recovery back to the same level look like fresh "growth" and get taxed again.
    uint256 public lastValueCheckpoint;

    event Rebalance(uint24 activeId, uint256 total0, uint256 total1);
    event HookRewardsHarvested(address indexed token, uint256 grossAmount, uint256 protocolFeeAmount);
    event ProtocolFeeMinted(uint256 shares, uint256 valueGrowth);
    event HookRefreshed(address indexed hook);

    error NotDrifted();

    constructor(
        address _factory,
        address _pair,
        uint256 _upwardBias,
        uint8 _protocolFee,
        string memory _name,
        string memory _symbol
    )
        StratusVaultBase(
            _factory,
            ILBPair(_pair).getTokenX(),
            ILBPair(_pair).getTokenY(),
            _upwardBias,
            _protocolFee,
            _name,
            _symbol
        )
    {
        pair = ILBPair(_pair);
        binStep = ILBPair(_pair).getBinStep();
        hook = ILBHooksRewarder(LiquidityBookMath.getHooksAddress(ILBPair(_pair).getLBHooksParameters()));
        _recenterBins();
    }

    /// @notice Re-sync the reward hook from the pair (e.g. if Metropolis governance attaches
    ///         or replaces it after this vault was created). Permissionless — reads public
    ///         on-chain truth, nothing trust-sensitive about refreshing a pointer to it.
    function refreshHook() external {
        hook = ILBHooksRewarder(LiquidityBookMath.getHooksAddress(pair.getLBHooksParameters()));
        emit HookRefreshed(address(hook));
    }

    function binIdsLength() external view returns (uint256) {
        return binIds.length;
    }

    function getBinIds() external view returns (uint24[] memory) {
        return binIds;
    }

    // ===================== VENUE-HOOK IMPLEMENTATIONS =====================

    /// @inheritdoc StratusVaultBase
    function _safeValuation() internal view override returns (uint256 total0, uint256 total1, uint256 price) {
        (total0, total1) = _totalAmountsAtCurrent();
        price = _twapPriceOrSpot();
    }

    /// @inheritdoc StratusVaultBase
    function _totalAmountsSpot() internal view override returns (uint256 total0, uint256 total1) {
        return _totalAmountsAtCurrent();
    }

    /// @inheritdoc StratusVaultBase
    function _spotPrice() internal view override returns (uint256) {
        return LiquidityBookMath.getPriceFromId(pair.getActiveId(), binStep);
    }

    /// @dev Bin reserves are exact (no curve), so amounts don't depend on which price you'd
    ///      evaluate at — only the price used to VALUE them (in _safeValuation) does.
    function _totalAmountsAtCurrent() internal view returns (uint256 total0, uint256 total1) {
        uint256 n = binIds.length;
        for (uint256 i = 0; i < n; i++) {
            uint24 id = binIds[i];
            uint256 bal = pair.balanceOf(address(this), id);
            if (bal == 0) continue;
            uint256 supply = pair.totalSupply(id);
            if (supply == 0) continue;
            (uint128 rx, uint128 ry) = pair.getBin(id);
            total0 += Math.mulDiv(bal, rx, supply);
            total1 += Math.mulDiv(bal, ry, supply);
        }
        total0 += token0.balanceOf(address(this));
        total1 += token1.balanceOf(address(this));
    }

    /// @dev LB's built-in oracle (v2.1+) needs two cumulative-id samples to average, exactly
    ///      like Uniswap V3's observe(). Falls back to spot if the pair has no/insufficient
    ///      history yet (fresh pair, or a low-activity one) — same bootstrapping limitation
    ///      a freshly-seeded CL vault has before its own TWAP window fills in.
    function _twapPriceOrSpot() internal view returns (uint256) {
        (, , uint16 activeSize, , uint40 firstTimestamp) = pair.getOracleParameters();
        if (activeSize == 0) return _spotPrice();
        uint40 nowTs = uint40(block.timestamp);
        if (nowTs < firstTimestamp + uint40(TWAP_PERIOD)) return _spotPrice();

        try pair.getOracleSampleAt(nowTs) returns (uint64 cumNow, uint64, uint64) {
            try pair.getOracleSampleAt(nowTs - uint40(TWAP_PERIOD)) returns (uint64 cumPast, uint64, uint64) {
                if (cumNow <= cumPast) return _spotPrice();
                uint24 avgId = uint24((uint256(cumNow) - uint256(cumPast)) / TWAP_PERIOD);
                return LiquidityBookMath.getPriceFromId(avgId, binStep);
            } catch {
                return _spotPrice();
            }
        } catch {
            return _spotPrice();
        }
    }

    function _mintPerformanceFee() internal {
        uint256 currentValue = getTotalValueSafe();
        if (currentValue > lastValueCheckpoint && protocolFee > 0 && totalSupply() > 0) {
            uint256 growth = currentValue - lastValueCheckpoint;
            uint256 feeValue = Math.mulDiv(growth, protocolFee, 100);
            uint256 feeShares = Math.mulDiv(feeValue, totalSupply() + VIRTUAL_SHARES, currentValue + VIRTUAL_ASSETS);
            if (feeShares > 0) {
                _mint(factory, feeShares);
                emit ProtocolFeeMinted(feeShares, growth);
            }
        }
        if (currentValue > lastValueCheckpoint) lastValueCheckpoint = currentValue;
    }

    /// @notice Harvest the hook's METRO (or whatever emission) for our rewarded-range bins,
    ///         skim the protocol cut, distribute the rest, and mint the factory a dilutive
    ///         performance-fee share of any value growth since the last checkpoint. Fees
    ///         auto-compound directly into bin reserves here (no explicit collect() the way
    ///         CL pools have), so the checkpoint-based mint is the only way to realize a cut.
    function _realizeFees() internal override {
        _harvestHookRewards();
        _mintPerformanceFee();
    }

    function _harvestHookRewards() internal {
        if (address(hook) == address(0)) return;
        try hook.isStopped() returns (bool stopped) {
            if (stopped) return;
        } catch {
            return;
        }

        (uint256 rStart, uint256 rEnd) = (rewardedBinStart, rewardedBinEnd);
        uint256 n = binIds.length;
        uint256[] memory qualifying = new uint256[](n);
        uint256 qCount = 0;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = binIds[i];
            if (id >= rStart && id <= rEnd && pair.balanceOf(address(this), uint24(id)) > 0) {
                qualifying[qCount++] = id;
            }
        }
        if (qCount == 0) return;
        assembly {
            mstore(qualifying, qCount)
        }

        address rewardToken = hook.getRewardToken();
        uint256 balBefore = IERC20(rewardToken).balanceOf(address(this));
        try hook.claim(address(this), qualifying) {} catch {
            return;
        }
        uint256 received = IERC20(rewardToken).balanceOf(address(this)) - balBefore;
        if (received == 0) return;

        uint256 fee = Math.mulDiv(received, protocolFee, 100);
        if (fee > 0) IERC20(rewardToken).safeTransfer(factory, fee);
        uint256 net = received - fee;
        _distributeReward(rewardToken, net);
        emit HookRewardsHarvested(rewardToken, received, fee);
    }

    /// @inheritdoc StratusVaultBase
    function _withdrawPositions(uint256 shares, uint256 totalWithVirtual, address to)
        internal
        override
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 n = binIds.length;
        uint256[] memory ids = new uint256[](n);
        uint256[] memory amounts = new uint256[](n);
        uint256 count = 0;
        for (uint256 i = 0; i < n; i++) {
            uint24 id = binIds[i];
            uint256 bal = pair.balanceOf(address(this), id);
            if (bal == 0) continue;
            uint256 toBurn = Math.mulDiv(bal, shares, totalWithVirtual);
            if (toBurn > 0) {
                ids[count] = id;
                amounts[count] = toBurn;
                count++;
            }
        }
        if (count == 0) return (0, 0);
        assembly {
            mstore(ids, count)
            mstore(amounts, count)
        }
        bytes32[] memory paid = pair.burn(address(this), to, ids, amounts);
        for (uint256 i = 0; i < paid.length; i++) {
            (uint256 x, uint256 y) = LiquidityBookMath.decodeAmounts(paid[i]);
            amount0 += x;
            amount1 += y;
        }
    }

    // ===================== REBALANCE =====================

    /// @notice Recenter the bin window and redeploy 100% of idle balances. Keeper/factory
    ///         only, matching the other venues' deployIdle signature (called once right
    ///         after factory seeding, and periodically thereafter).
    function deployIdle() external override onlyFactory nonReentrant whenNotPaused {
        _rebalance();
    }

    /// @notice Permissionless recenter — safe to expose without a keeper because, unlike
    ///         CL's rebalanceViaSwap, there is no swap/bounty/anti-drain economics needed
    ///         (see contract-level dev comment): recentering never leaves genuine value
    ///         idle, so there's nothing for a caller to drain. Reverts if the bin window
    ///         is already centered on the current rewarded range, to block gas-wasting spam.
    function rebalance() external nonReentrant whenNotPaused {
        if (_isCentered()) revert NotDrifted();
        _rebalance();
    }

    function _rebalance() internal {
        // Harvest emissions from the bins we're about to burn, but defer the dilutive
        // performance-fee mint until AFTER redeploy — pre-burn valuation compares idle
        // LP in bins against a checkpoint taken at the prior idle state and can skew.
        _harvestHookRewards();
        _burnAll();
        _recenterBins();
        _mintFromIdle();
        _mintPerformanceFee();
        emit Rebalance(pair.getActiveId(), token0.balanceOf(address(this)), token1.balanceOf(address(this)));
    }

    function _isCentered() internal view returns (bool) {
        if (binIds.length == 0) return false;
        (uint256 rStart, uint256 rEnd) = _rewardedRangeOrFallback();
        uint256 wantLo = rStart > OUTER_BINS_EACH_SIDE ? rStart - OUTER_BINS_EACH_SIDE : 0;
        uint256 wantHi = rEnd + OUTER_BINS_EACH_SIDE;
        return uint256(binIds[0]) == wantLo && uint256(binIds[binIds.length - 1]) == wantHi;
    }

    function _burnAll() internal {
        uint256 n = binIds.length;
        uint256[] memory ids = new uint256[](n);
        uint256[] memory amounts = new uint256[](n);
        uint256 count = 0;
        for (uint256 i = 0; i < n; i++) {
            uint24 id = binIds[i];
            uint256 bal = pair.balanceOf(address(this), id);
            if (bal > 0) {
                ids[count] = id;
                amounts[count] = bal;
                count++;
            }
        }
        if (count == 0) return;
        assembly {
            mstore(ids, count)
            mstore(amounts, count)
        }
        pair.burn(address(this), address(this), ids, amounts);
    }

    function _recenterBins() internal {
        (uint256 rStart, uint256 rEnd) = _rewardedRangeOrFallback();
        uint256 lo = rStart > OUTER_BINS_EACH_SIDE ? rStart - OUTER_BINS_EACH_SIDE : 0;
        uint256 hi = rEnd + OUTER_BINS_EACH_SIDE;

        delete binIds;
        for (uint256 id = lo; id <= hi; id++) {
            binIds.push(uint24(id));
        }
        rewardedBinStart = rStart;
        rewardedBinEnd = rEnd;
    }

    /// @dev Falls back to a single-bin "rewarded range" (just the active bin) when there's
    ///      no hook, or it's stopped, or the call reverts — still concentrates deploy weight
    ///      sensibly rather than spreading uniformly with no venue-specific reasoning at all.
    function _rewardedRangeOrFallback() internal view returns (uint256 rStart, uint256 rEnd) {
        uint24 activeId = pair.getActiveId();
        if (address(hook) != address(0)) {
            try hook.isStopped() returns (bool stopped) {
                if (!stopped) {
                    try hook.getRewardedRange() returns (uint256 s, uint256 e) {
                        return (s, e);
                    } catch {}
                }
            } catch {}
        }
        return (activeId, activeId);
    }

    /// @dev Metropolis LB mint() computes `received = balance - _reserves` where `_reserves`
    ///      is the GROSS accounting (bin reserves + protocol fees). `getReserves()` returns
    ///      `_reserves - protocolFees`, so comparing balance to getReserves() alone can miss
    ///      a shortfall that still makes mint() revert with PackedUint128Math__SubUnderflow.
    ///      Top up from idle balances before reminting. Cap at vault idle so an externally
    ///      drained pair (e.g. fork tests that pull tokens out of the pair) can't brick
    ///      rebalance with ERC20InsufficientBalance — mint will still fail loudly if the
    ///      shortfall exceeds what we can cover.
    function _repairPairReserveShortfall() internal {
        (uint128 resX, uint128 resY) = pair.getReserves();
        (uint128 feeX, uint128 feeY) = pair.getProtocolFees();
        uint256 needX = uint256(resX) + uint256(feeX);
        uint256 needY = uint256(resY) + uint256(feeY);
        uint256 balX = token0.balanceOf(address(pair));
        uint256 balY = token1.balanceOf(address(pair));
        if (balX < needX) {
            uint256 short = needX - balX;
            uint256 idle = token0.balanceOf(address(this));
            if (idle > 0) token0.safeTransfer(address(pair), short < idle ? short : idle);
        }
        if (balY < needY) {
            uint256 short = needY - balY;
            uint256 idle = token1.balanceOf(address(this));
            if (idle > 0) token1.safeTransfer(address(pair), short < idle ? short : idle);
        }
    }

    /// @dev Deploy idle balances across the bin window. Outer bins (above/below active) are
    ///      single-sided one-bin-per-mint; the active bin is a dual-token mint. Multi-bin
    ///      configs in one mint() over-allocate against amountsReceived and can revert.
    function _mintFromIdle() internal {
        _repairPairReserveShortfall();

        uint256 bal0 = token0.balanceOf(address(this));
        uint256 bal1 = token1.balanceOf(address(this));
        if (bal0 == 0 && bal1 == 0) return;

        uint256 n = binIds.length;
        if (n == 0) return;

        uint24 activeId = pair.getActiveId();
        (uint256[] memory weight, uint256 xOuterTotal, uint256 yOuterTotal, uint256 wActive) =
            _binDeployWeights(activeId, n);

        uint256 xSideTotal = xOuterTotal + wActive;
        uint256 ySideTotal = yOuterTotal + wActive;

        // Spend only the outer share of each side; active claim is whatever remains after.
        if (bal0 > 0 && xOuterTotal > 0 && xSideTotal > 0) {
            _mintOneSide(true, activeId, Math.mulDiv(bal0, xOuterTotal, xSideTotal), n, weight, xOuterTotal);
        }
        if (bal1 > 0 && yOuterTotal > 0 && ySideTotal > 0) {
            _mintOneSide(false, activeId, Math.mulDiv(bal1, yOuterTotal, ySideTotal), n, weight, yOuterTotal);
        }

        if (wActive > 0) {
            _mintActiveBin(activeId, token0.balanceOf(address(this)), token1.balanceOf(address(this)));
        }
    }

    /// @dev Per-bin weights for the current window. Rewarded bins (including the active bin
    ///      when it sits in the rewarded range) share REWARDED_WEIGHT_BPS; outer depth bins
    ///      split the rest. Returns outer-only side totals plus the active bin's weight so
    ///      callers can split idle between single-sided outer mints and the dual-token active mint.
    function _binDeployWeights(uint24 activeId, uint256 n)
        internal
        view
        returns (uint256[] memory weight, uint256 xOuterTotal, uint256 yOuterTotal, uint256 wActive)
    {
        weight = new uint256[](n);

        uint256 rewardedDeployable;
        uint256 outerCount;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = binIds[i];
            bool inRewarded = id >= rewardedBinStart && id <= rewardedBinEnd;
            if (inRewarded) rewardedDeployable++;
            else outerCount++;
        }

        uint256 wRewarded = rewardedDeployable == 0 ? 0 : REWARDED_WEIGHT_BPS / rewardedDeployable;
        uint256 wOuter = outerCount == 0 ? 0 : (BASIS_POINTS - REWARDED_WEIGHT_BPS) / outerCount;

        for (uint256 i = 0; i < n; i++) {
            uint256 id = binIds[i];
            bool inRewarded = id >= rewardedBinStart && id <= rewardedBinEnd;
            weight[i] = inRewarded ? wRewarded : wOuter;
            if (id == activeId) {
                wActive = weight[i];
            } else if (id > activeId) {
                xOuterTotal += weight[i];
            } else {
                yOuterTotal += weight[i];
            }
        }
    }

    /// @dev Dual-token mint into the active bin. LB trims to the live reserve ratio and
    ///      refunds leftovers to `refundTo`; we pre-cap to ry/rx to cut composition fees.
    function _mintActiveBin(uint24 activeId, uint256 allocX, uint256 allocY) internal {
        if (allocX == 0 && allocY == 0) return;

        (uint128 rx, uint128 ry) = pair.getBin(activeId);
        (uint256 depositX, uint256 depositY) = _capToBinRatio(allocX, allocY, rx, ry);
        if (depositX == 0 && depositY == 0) return;

        // Outer mints may have left a tiny gross-reserve gap; repair before this mint too.
        _repairPairReserveShortfall();

        if (depositX > 0) token0.safeTransfer(address(pair), depositX);
        if (depositY > 0) token1.safeTransfer(address(pair), depositY);

        bytes32[] memory oneConfig = new bytes32[](1);
        if (depositX == 0) {
            oneConfig[0] = LiquidityBookMath.encodeLiquidityConfig(0, uint64(PRECISION), activeId);
        } else if (depositY == 0) {
            oneConfig[0] = LiquidityBookMath.encodeLiquidityConfig(uint64(PRECISION), 0, activeId);
        } else {
            oneConfig[0] = LiquidityBookMath.encodeLiquidityConfig(uint64(PRECISION), uint64(PRECISION), activeId);
        }
        pair.mint(address(this), oneConfig, address(this));
    }

    /// @dev Cap a dual-sided deposit to the active bin's live reserve ratio so LB does not
    ///      have to trim (and charge composition fees) as aggressively. Empty / one-sided
    ///      bins pass through unchanged.
    function _capToBinRatio(uint256 allocX, uint256 allocY, uint128 rx, uint128 ry)
        internal
        pure
        returns (uint256 depositX, uint256 depositY)
    {
        if (allocX == 0) return (0, allocY);
        if (allocY == 0) return (allocX, 0);
        if (rx == 0 && ry == 0) return (allocX, allocY);
        if (rx == 0) return (0, allocY);
        if (ry == 0) return (allocX, 0);

        uint256 yFromX = Math.mulDiv(allocX, ry, rx);
        if (yFromX <= allocY) return (allocX, yFromX);
        return (Math.mulDiv(allocY, rx, ry), allocY);
    }

    /// @dev Single-sided LB mint: `isX` true deposits token0 into bins above `activeId`.
    ///      One bin per mint() call with distribution 1e18 — multi-bin configs in a single
    ///      mint() trip Metropolis' PackedUint128Math__SubUnderflow on redeploy after burn
    ///      (bin reserves change between first deploy and remint). Exact per-bin transfers
    ///      avoid cross-bin distribution rounding entirely. Active bin is handled separately.
    function _mintOneSide(
        bool isX,
        uint24 activeId,
        uint256 balance,
        uint256 n,
        uint256[] memory weight,
        uint256 sideTotal
    ) internal {
        if (balance == 0 || sideTotal == 0) return;

        uint256 eligibleCount;
        for (uint256 i = 0; i < n; i++) {
            uint24 id = binIds[i];
            if (isX ? id <= activeId : id >= activeId) continue;
            if (weight[i] == 0) continue;
            eligibleCount++;
        }
        if (eligibleCount == 0) return;

        bytes32[] memory oneConfig = new bytes32[](1);
        IERC20 sideToken = isX ? token0 : token1;
        uint256 allocated;
        uint256 processed;

        for (uint256 i = 0; i < n; i++) {
            uint24 id = binIds[i];
            if (isX ? id <= activeId : id >= activeId) continue;
            if (weight[i] == 0) continue;

            processed++;
            uint256 amount = processed == eligibleCount ? balance - allocated : Math.mulDiv(balance, weight[i], sideTotal);
            allocated += amount;
            if (amount == 0) continue;

            oneConfig[0] = isX
                ? LiquidityBookMath.encodeLiquidityConfig(uint64(PRECISION), 0, id)
                : LiquidityBookMath.encodeLiquidityConfig(0, uint64(PRECISION), id);

            sideToken.safeTransfer(address(pair), amount);
            pair.mint(address(this), oneConfig, address(this));
        }
    }
}
