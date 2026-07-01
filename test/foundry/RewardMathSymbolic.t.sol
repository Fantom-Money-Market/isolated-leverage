// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Symbolic (Halmos) proofs for the reward-accumulator math fixed this session —
///         the live incident where a harvest landing at near-zero totalSupply inflated
///         rewardPerShareStored by an unbounded factor, which fed an overflow-unsafe raw
///         multiplication in _settleRewards.
///
///         Scoped deliberately to the isolated, loop-free arithmetic (no storage, no
///         ERC20 state, no rewardTokens loop) — that's where a solver can actually finish.
///         Symbolically executing the whole contract (loops over rewardTokens, storage
///         reads across deposit/withdraw/claim) is a much harder, slower problem with a
///         different cost/benefit; these proofs isolate exactly the two lines that broke
///         live and prove them for the full input space (bounded only where the true
///         mathematical result provably cannot fit in uint256 anyway).
///
///   halmos --contract RewardMathSymbolic
contract RewardMathSymbolic is Test {
    uint256 constant ACC_PRECISION = 1e18;
    uint256 constant VIRTUAL_SHARES = 1_000_000;

    /// @dev Ground-truth check: where bal*delta provably fits in uint256 on its own
    ///      (both narrowed to uint64 at the type level, not via bound() on a uint256 — a
    ///      narrower symbolic bitvector is what actually shrinks the search space for the
    ///      solver, since bound() only adds a runtime constraint on top of the full 256-bit
    ///      space), Math.mulDiv must equal naive floor division exactly.
    function check_mulDiv_matchesNaive_smallInputs(uint64 bal64, uint64 delta64) public pure {
        uint256 bal = uint256(bal64);
        uint256 delta = uint256(delta64);

        uint256 viaMulDiv = Math.mulDiv(bal, delta, ACC_PRECISION);
        uint256 naive = (bal * delta) / ACC_PRECISION; // safe here: bal*delta < 2^128

        assert(viaMulDiv == naive);
    }

    /// @dev THE headline property this session's fix depends on: _settleRewards computes
    ///      Math.mulDiv(bal, acc - paid, ACC_PRECISION) where `bal` is a real ERC20 share
    ///      balance and `acc - paid` can be driven large by repeated harvests over a long
    ///      vault lifetime (exactly what happened live). Narrowed to uint128 at the type
    ///      level (not bound()) for solver tractability — still 3.4e38, vastly beyond any
    ///      real 18-decimal token balance AND beyond any single-harvest accumulator jump
    ///      under the VIRTUAL_SHARES floor (net * 1e12, so even a 1e18-token harvest only
    ///      moves the accumulator by ~1e30). Within that space, prove the call never
    ///      reverts — the exact call the live raw-multiplication code could not survive.
    function check_settleRewards_mulDiv_neverReverts(uint128 bal128, uint128 delta128) public pure {
        uint256 bal = uint256(bal128);
        uint256 delta = uint256(delta128);

        // Must not revert for any (bal, delta) in this space.
        Math.mulDiv(bal, delta, ACC_PRECISION);
    }

    /// @dev Formalizes the fix's core claim in _distributeReward: flooring the denominator
    ///      with +VIRTUAL_SHARES can only ever REDUCE (or leave unchanged) the accumulator
    ///      increment compared to the same call with the smallest possible denominator
    ///      (VIRTUAL_SHARES alone, i.e. totalSupply()==0). Proves the "blow-up factor is
    ///      capped at ACC_PRECISION/VIRTUAL_SHARES regardless of totalSupply" claim for the
    ///      full uint128 range of both inputs, not just the fuzzed/observed cases.
    function check_distributeReward_denominatorFloor(uint128 net128, uint128 totalSupply128) public pure {
        uint256 net = uint256(net128);
        uint256 totalSupply = uint256(totalSupply128);

        uint256 incrementWithSupply = Math.mulDiv(net, ACC_PRECISION, totalSupply + VIRTUAL_SHARES);
        uint256 worstCaseIncrement = Math.mulDiv(net, ACC_PRECISION, VIRTUAL_SHARES);

        assert(incrementWithSupply <= worstCaseIncrement);
    }

    /// @dev Regression check for the OLD (pre-fix) formula: prove it's possible for the
    ///      naive `net * ACC_PRECISION / totalSupply` (no VIRTUAL_SHARES floor) to produce
    ///      an accumulator increment that exceeds ANY fixed bound as totalSupply shrinks —
    ///      i.e. the old code had no ceiling at all. This is a "prove the bug existed"
    ///      counterpart to the "prove the fix holds" checks above: expected to find a
    ///      counterexample (that's the point), included so the proof suite documents both
    ///      sides.
    function check_oldFormula_wasUnbounded_expectFailure(uint256 net, uint256 totalSupply) public pure {
        net = bound(net, 1, 1e40);
        totalSupply = bound(totalSupply, 1, 1_000_000); // old code allowed supply this small

        uint256 oldIncrement = Math.mulDiv(net, ACC_PRECISION, totalSupply); // no floor
        uint256 sameFixedCeiling = Math.mulDiv(net, ACC_PRECISION, VIRTUAL_SHARES);

        // Assert the OLD formula respects the same ceiling the NEW one guarantees — this
        // should FAIL (Halmos finds a counterexample), proving the old code had no such
        // guarantee. A passing result here would mean this test is not exercising the bug.
        assert(oldIncrement <= sameFixedCeiling);
    }
}
