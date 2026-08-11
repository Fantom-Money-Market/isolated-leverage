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
/// @notice Metropolis (Liquidity Book) DLMM vault. Share accounting, pause, and reward
///         accumulator come from StratusVaultBase; this layer handles bin mint/burn,
///         valuation, and optional hook emissions on the rewarded bin range.
/// @dev Each LB bin has exact reserves (getBin). Amounts need no spot/TWAP split; only
///      the unit price in getTotalValueSafe uses the LB oracle (fails closed via UnsafePrice
///      when that oracle is unusable). Bins above active are 100% token0, below 100%
///      token1, so idle balances deploy independently — rebalance recenters the window
///      (permissionless tip from harvested METRO), it does not OTC-swap for balance.
/// @dev Active bin: dual-token mint (distributionX = distributionY = 1e18), optionally
///      pre-capped to the live ry/rx to limit composition fees. Outer bins are single-sided.
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
    /// @dev How stale the newest oracle sample may be before the TWAP is rejected. Caps the
    ///      extrapolated (activeId-derived, therefore manipulable) share of the averaging
    ///      window at 1/3 — see _trySafePrice for why extrapolation is the real risk.
    uint40 internal constant MAX_ORACLE_STALENESS = uint40(TWAP_PERIOD) / 3;
    /// @dev Share of deploy weight concentrated into the rewarded range (or, with no hook,
    ///      the single active bin) — the rest spreads evenly across the outer depth bins.
    uint256 internal constant REWARDED_WEIGHT_BPS = 5000;
    /// @dev Cap on rewarded bins the vault will track (binIds length bounded by this plus
    ///      outer depth). binIds is walked on every valuation/deposit/withdraw; an unbounded
    ///      third-party hook range would gas-limit those paths and trap withdrawals.
    ///      Metropolis rewarders typically cap near 11; we keep a slightly higher ceiling
    ///      because `hook` is pair-resolved and can change via refreshHook().
    uint256 internal constant MAX_REWARDED_BINS = 15;
    /// @dev Share of DEPLOYED value that must have fallen outside the target window before a
    ///      permissionless rebalance() is allowed — see needsRebalance(). Sized against the
    ///      deploy weights: REWARDED_WEIGHT_BPS (50%) goes to the rewarded bins and the other
    ///      50% spreads across ~10 outer depth bins, so a single bin of drift displaces
    ///      roughly 5% of the position. 20% is therefore about four bins of genuine movement
    ///      — enough that re-centring is worth the composition fee, small enough that the
    ///      window still tracks a real trend closely.
    uint256 internal constant MIN_OUT_OF_RANGE_BPS = 2000;

    /// @dev Read via getBinIds(). Kept internal (no auto-getter, no separate length getter)
    ///      purely for deployed-bytecode size — the deployer embeds this vault's creation
    ///      code and sits against the EIP-170 limit.
    uint24[] internal binIds;
    uint256 internal rewardedBinStart;
    uint256 internal rewardedBinEnd;

    /// @notice High-water mark of value per share (1e18-scaled), not total value.
    /// @dev Performance fees must track PPS: total value rises on every deposit, so a
    ///      total-value mark would tax principal. PPS is invariant to pro-rata deposit/
    ///      withdraw and moves only on real yield. Ratchets up only (no double-tax on recovery).
    uint256 public lastPricePerShare;

    /// @notice Cut (bps) of freshly-harvested hook emissions paid to the permissionless
    ///         rebalancer — from yield, not principal. Same idea as CL's rewardBountyBps.
    ///         Factory deployIdle pays 0; only rebalance() tips the caller.
    uint256 public constant rewardBountyBps = 200; // 2% of the harvest

    event Rebalance(uint24 activeId, uint256 total0, uint256 total1);
    event HookRewardsHarvested(address indexed token, uint256 grossAmount, uint256 protocolFeeAmount);
    event RebalanceBountyPaid(address indexed to, address indexed token, uint256 amount);
    event ProtocolFeeMinted(uint256 shares, uint256 valueGrowth);
    event HookRefreshed(address indexed hook);

    error NotDrifted();
    /// @notice The LB oracle cannot currently produce a manipulation-resistant price, so the
    ///         vault refuses to report a "safe" valuation rather than falling back to spot.
    error UnsafePrice();

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

    function getBinIds() external view returns (uint24[] memory) {
        return binIds;
    }

    // ===================== VENUE-HOOK IMPLEMENTATIONS =====================

    /// @inheritdoc StratusVaultBase
    function _safeValuation() internal view override returns (uint256 total0, uint256 total1, uint256 price) {
        (total0, total1) = _totalAmountsAtCurrent();
        price = _safePrice();
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
            (uint256 a0, uint256 a1) = _binAmounts(binIds[i]);
            total0 += a0;
            total1 += a1;
        }
        total0 += token0.balanceOf(address(this));
        total1 += token1.balanceOf(address(this));
    }

    /// @dev This vault's share of one bin's reserves. Shared by the valuation loop and the
    ///      rebalance gate so the two can never disagree about what a bin is worth — and so
    ///      the per-bin math is only compiled once, which matters because the deployer embeds
    ///      this vault's creation code and sits on the EIP-170 limit.
    function _binAmounts(uint24 id) internal view returns (uint256 a0, uint256 a1) {
        uint256 bal = pair.balanceOf(address(this), id);
        if (bal == 0) return (0, 0);
        uint256 supply = pair.totalSupply(id);
        if (supply == 0) return (0, 0);
        (uint128 rx, uint128 ry) = pair.getBin(id);
        a0 = Math.mulDiv(bal, rx, supply);
        a1 = Math.mulDiv(bal, ry, supply);
    }

    /// @notice True when the LB oracle can currently serve a manipulation-resistant price.
    ///         Lets callers (lens/UI) see that the market is unpriceable without reverting.
    function isSafePriceAvailable() public view returns (bool) {
        (bool ok, ) = _trySafePrice();
        return ok;
    }

    /// @dev Manipulation-resistant TWAP from the LB oracle, or (false, 0). Never falls back
    ///      to spot: activeId is swap-movable and is what Collateral would otherwise treat
    ///      as "safe". Failing closed pauses deposits/pricing until the oracle is usable.
    ///
    /// @dev Staleness: getOracleSampleAt extrapolates past the newest sample with the
    ///      current activeId. With no recent trades both TWAP endpoints share that term,
    ///      so the average collapses to spot. Require enough history AND a fresh lastUpdated
    ///      (MAX_ORACLE_STALENESS) so extrapolation is only a small slice of the window.
    function _trySafePrice() internal view returns (bool ok, uint256 price) {
        (, , uint16 activeSize, uint40 lastUpdated, uint40 firstTimestamp) = pair.getOracleParameters();
        if (activeSize == 0) return (false, 0); // oracle never activated
        uint40 nowTs = uint40(block.timestamp);
        if (nowTs < firstTimestamp + uint40(TWAP_PERIOD)) return (false, 0); // too little history
        if (lastUpdated == 0 || nowTs - lastUpdated > MAX_ORACLE_STALENESS) return (false, 0);

        try pair.getOracleSampleAt(nowTs) returns (uint64 cumNow, uint64, uint64) {
            try pair.getOracleSampleAt(nowTs - uint40(TWAP_PERIOD)) returns (uint64 cumPast, uint64, uint64) {
                if (cumNow <= cumPast) return (false, 0);
                uint24 avgId = uint24((uint256(cumNow) - uint256(cumPast)) / TWAP_PERIOD);
                return (true, LiquidityBookMath.getPriceFromId(avgId, binStep));
            } catch {
                return (false, 0);
            }
        } catch {
            return (false, 0);
        }
    }

    function _safePrice() internal view returns (uint256) {
        (bool ok, uint256 price) = _trySafePrice();
        if (!ok) revert UnsafePrice();
        return price;
    }

    /// @dev Advance the PPS high-water mark; if `takeFee`, mint the protocol cut on growth
    ///      above it to the factory.
    /// @dev When a reward stream is live, `takeFee` is false — the cut is already skimmed
    ///      in the emission token in _harvestHookRewards. Minting fee shares would raise
    ///      supply without raising value and mark down every open borrow's collateral price
    ///      (Collateral.getPrices = supply / getTotalValueSafe).
    /// @dev The mark still advances when the fee is waived, so growth during a live hook is
    ///      not retroactively taxed when the hook later stops.
    function _accruePerformanceFee(bool takeFee) internal {
        if (totalSupply() == 0) return;
        // Revenue only — never block withdraw/deposit paths. Skip (leave mark untouched)
        // while the LB oracle cannot serve a safe price; take the cut later once it can.
        if (!isSafePriceAvailable()) return;
        uint256 currentValue = getTotalValueSafe();
        uint256 denom = totalSupply() + VIRTUAL_SHARES;
        uint256 pps = Math.mulDiv(currentValue + VIRTUAL_ASSETS, PRECISION, denom);

        // Seed the first observable PPS; a zero mark means "never measured", not "worth zero".
        if (lastPricePerShare == 0) {
            lastPricePerShare = pps;
            return;
        }
        if (pps <= lastPricePerShare) return; // high-water mark: drawdowns are not refunded

        if (takeFee && protocolFee > 0) {
            uint256 growth = Math.mulDiv(pps - lastPricePerShare, denom, PRECISION);
            uint256 feeValue = Math.mulDiv(growth, protocolFee, 100);
            uint256 feeShares = Math.mulDiv(feeValue, denom, currentValue + VIRTUAL_ASSETS);
            if (feeShares > 0) {
                _mint(factory, feeShares);
                emit ProtocolFeeMinted(feeShares, growth);
                // The mint itself dilutes value per share. Re-derive the mark from the
                // POST-mint supply, or the same growth gets charged again next call.
                lastPricePerShare =
                    Math.mulDiv(currentValue + VIRTUAL_ASSETS, PRECISION, totalSupply() + VIRTUAL_SHARES);
                return;
            }
        }
        lastPricePerShare = pps;
    }

    /// @notice Harvest the hook's METRO (or whatever emission) for our rewarded-range bins,
    ///         skim the protocol cut from it, and distribute the rest.
    /// @dev Where the protocol fee comes from depends on whether a reward stream is running,
    ///      which keeps this venue consistent with the other two: Shadow skims its cut out of
    ///      the gauge harvest, Thick (no gauge) skims it out of collected swap fees, and
    ///      neither ever mints shares. With a live hook, DLMM does the same — the cut is
    ///      already taken in the emission token inside _harvestHookRewards, so the dilutive
    ///      mint is waived. Only with NO reward stream does the share mint apply, because
    ///      DLMM trading fees auto-compound straight into bin reserves (there is no explicit
    ///      collect() the way CL pools have) and there would otherwise be nothing to skim.
    function _realizeFees() internal override {
        bool rewardStreamLive = _harvestHookRewards(address(0), 0);
        _accruePerformanceFee(!rewardStreamLive);
    }

    /// @dev Claim hook emissions for rewarded-range bins. Optionally skim `cutBps` to
    ///      `bountyTo` (permissionless rebalancer tip), then protocol fee, then distribute.
    /// @return live Whether a reward stream is attached and running — i.e. whether the
    ///         protocol fee is being taken here, in the emission token. _realizeFees waives
    ///         the dilutive share mint whenever this is true.
    /// @dev `live` deliberately tracks the STREAM, not this call's proceeds. It stays true
    ///      when a claim happens to yield nothing (two calls in the same block, no qualifying
    ///      bins, a reverting claim), so the fee mechanism cannot flip between skim and
    ///      dilution on transaction timing. Every such case errs toward forgoing revenue,
    ///      which is the safe direction: the dangerous failure is diluting ALPT — and with it
    ///      every borrower's collateral — not missing a cut.
    function _harvestHookRewards(address bountyTo, uint256 cutBps) internal returns (bool live) {
        if (address(hook) == address(0)) return false;
        try hook.isStopped() returns (bool stopped) {
            if (stopped) return false;
        } catch {
            return false;
        }
        live = true;

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
        if (qCount == 0) return live;
        assembly {
            mstore(qualifying, qCount)
        }

        address rewardToken = hook.getRewardToken();
        uint256 balBefore = IERC20(rewardToken).balanceOf(address(this));
        try hook.claim(address(this), qualifying) {} catch {
            return live;
        }
        uint256 received = IERC20(rewardToken).balanceOf(address(this)) - balBefore;
        if (received == 0) return live;

        uint256 bounty = (bountyTo != address(0) && cutBps > 0) ? Math.mulDiv(received, cutBps, BASIS_POINTS) : 0;
        if (bounty > 0) {
            IERC20(rewardToken).safeTransfer(bountyTo, bounty);
            emit RebalanceBountyPaid(bountyTo, rewardToken, bounty);
        }

        uint256 rest = received - bounty;
        uint256 fee = Math.mulDiv(rest, protocolFee, 100);
        if (fee > 0) IERC20(rewardToken).safeTransfer(factory, fee);
        uint256 net = rest - fee;
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
    ///         after factory seeding, and periodically thereafter). No rebalancer bounty —
    ///         the factory is not a gas-paid keeper tip path.
    function deployIdle() external override onlyFactory nonReentrant whenNotPaused {
        _rebalance(address(0), 0);
    }

    /// @notice Permissionless recenter. Caller is tipped `rewardBountyBps` of any METRO
    ///         harvested in this tx (yield-funded, same as Shadow's gauge bounty). Reverts
    ///         with NotDrifted unless enough of the position has actually fallen out of the
    ///         target window — see needsRebalance().
    function rebalance() external nonReentrant whenNotPaused {
        if (!needsRebalance()) revert NotDrifted();
        _rebalance(msg.sender, rewardBountyBps);
    }

    function _rebalance(address bountyTo, uint256 cutBps) internal {
        // Harvest emissions from the bins we're about to burn (optionally tip the caller),
        // but defer the dilutive performance-fee mint until AFTER redeploy — pre-burn
        // valuation compares idle LP in bins against a checkpoint taken at the prior idle
        // state and can skew.
        bool rewardStreamLive = _harvestHookRewards(bountyTo, cutBps);
        _burnAll();
        _recenterBins();
        _mintFromIdle();
        _accruePerformanceFee(!rewardStreamLive);
        emit Rebalance(pair.getActiveId(), token0.balanceOf(address(this)), token1.balanceOf(address(this)));
    }

    /// @notice Whether permissionless rebalance is allowed: at least MIN_OUT_OF_RANGE_BPS
    ///         of deployed value sits outside the window we would mint to now.
    /// @dev Rebalance is not free — burn + remint pays LB composition fees on the active
    ///      bin out of principal. Gate on out-of-range value (not a one-bin exact-match or
    ///      a time cooldown) so dust swaps cannot force churn, while a real gap still opens
    ///      the gate. Self-limiting: after rebalance every deployed bin is in-window.
    /// @dev Uses spot (not safe price) so a stale oracle cannot revert and strand the vault.
    ///      Opening the gate only allows recentering onto that same active bin.
    /// @dev deployIdle() (factory) ignores this gate so operators can always recenter.
    function needsRebalance() public view returns (bool) {
        uint256 n = binIds.length;
        // Nothing deployed: there is no position to churn, so nothing to protect. Allow it
        // so idle balances (e.g. after a full withdraw, then a fresh deposit) can be put to
        // work without waiting on the factory. With no idle either, _mintFromIdle no-ops and
        // a spammer just burns their own gas.
        if (n == 0) return true;

        (uint256 wantLo, uint256 wantHi) = _targetWindow();
        uint256 price = _spotPrice();
        uint256 inValue;
        uint256 outValue;
        for (uint256 i = 0; i < n; i++) {
            uint24 id = binIds[i];
            (uint256 a0, uint256 a1) = _binAmounts(id);
            uint256 v = a1 + Math.mulDiv(a0, price, PRECISION);
            if (v == 0) continue;
            if (id >= wantLo && id <= wantHi) inValue += v;
            else outValue += v;
        }

        uint256 total = inValue + outValue;
        if (total == 0) return true; // bins tracked but all empty — same case as n == 0
        return outValue * BASIS_POINTS >= total * MIN_OUT_OF_RANGE_BPS;
    }

    /// @dev The bin window the vault wants right now: the (clamped) rewarded range plus
    ///      OUTER_BINS_EACH_SIDE of pure-fee depth either side, kept inside uint24. Single
    ///      source of truth for _recenterBins and needsRebalance — see _clampRange for why they
    ///      must never disagree.
    function _targetWindow() internal view returns (uint256 lo, uint256 hi) {
        (uint256 rStart, uint256 rEnd) = _rewardedRangeOrFallback();
        lo = rStart > OUTER_BINS_EACH_SIDE ? rStart - OUTER_BINS_EACH_SIDE : 0;
        hi = rEnd + OUTER_BINS_EACH_SIDE;
        if (hi > type(uint24).max) hi = type(uint24).max;
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
        (uint256 lo, uint256 hi) = _targetWindow();

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
                        if (e >= s && e <= type(uint24).max) return _clampRange(s, e, activeId);
                    } catch {}
                }
            } catch {}
        }
        return (activeId, activeId);
    }

    /// @dev Clamp an externally-supplied rewarded range to MAX_REWARDED_BINS, keeping the
    ///      window over the active bin — that is where volume lands, so it is where both
    ///      fees and emissions actually accrue. Applied inside _rewardedRangeOrFallback so
    ///      _recenterBins and needsRebalance agree on the target; clamping in only one of them
    ///      would leave the window permanently "not centered" and hand a griefer an
    ///      always-callable rebalance().
    function _clampRange(uint256 s, uint256 e, uint24 activeId) internal pure returns (uint256, uint256) {
        if (e + 1 - s <= MAX_REWARDED_BINS) return (s, e);
        uint256 half = MAX_REWARDED_BINS / 2;
        uint256 lo = uint256(activeId) > half ? uint256(activeId) - half : 0;
        uint256 hi = lo + MAX_REWARDED_BINS - 1;
        // The range is wider than MAX_REWARDED_BINS here, so each nudge back inside [s,e]
        // keeps the window exactly MAX_REWARDED_BINS wide and cannot re-break the other end.
        if (lo < s) (lo, hi) = (s, s + MAX_REWARDED_BINS - 1);
        if (hi > e) (lo, hi) = (e + 1 - MAX_REWARDED_BINS, e);
        return (lo, hi);
    }

    /// @dev LB mint() uses gross reserves (bin reserves + protocol fees). getReserves()
    ///      excludes protocol fees, so a tiny gross shortfall can revert mint. Repair tops
    ///      up from idle before reminting, capped at MAX_REPAIR_BPS of idle per side — enough
    ///      for dust/rounding, not an open-ended donation into the pair on a permissionless
    ///      path. Larger shortfalls let mint revert. Withdrawals use burn directly and never
    ///      hit this path.
    uint256 internal constant MAX_REPAIR_BPS = 10; // 0.1% of idle, per side, per call

    function _repairPairReserveShortfall() internal {
        (uint128 resX, uint128 resY) = pair.getReserves();
        (uint128 feeX, uint128 feeY) = pair.getProtocolFees();
        _repairSide(token0, uint256(resX) + uint256(feeX));
        _repairSide(token1, uint256(resY) + uint256(feeY));
    }

    function _repairSide(IERC20 token, uint256 need) internal {
        uint256 bal = token.balanceOf(address(pair));
        if (bal >= need) return;
        uint256 idle = token.balanceOf(address(this));
        if (idle == 0) return;
        uint256 cap = Math.mulDiv(idle, MAX_REPAIR_BPS, BASIS_POINTS);
        uint256 short = need - bal;
        uint256 amount = short < cap ? short : cap;
        if (amount > 0) token.safeTransfer(address(pair), amount);
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
    ///      One bin per mint() with distribution 1e18 (multi-bin configs in one call are
    ///      fragile across burn/remint when reserves change). Exact per-bin transfers avoid
    ///      cross-bin distribution rounding. Active bin is handled separately.
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
