// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../../contracts/Collateral.sol";
import "../harness/MockALPTUnderlying.sol";
import "../../../contracts/Stratus-ALM/test/MockERC20.sol";

/// @notice Invariant-fuzzing handler for Collateral.sol's MasterChef accumulator, driving
///         random mint/redeem/transfer/harvest/claim sequences against the REAL Collateral
///         contract (not a math-only proxy). Harvest amounts are deliberately unbounded (up
///         to 1e50) — that's the exact lever that produced the live incident (an ordinary
///         harvest landing at near-zero supply) and its worse cousin here (an extreme
///         accumulator blocking _settleVaultRewards, which seize() depends on).
///
///         Expected, benign protocol-rule reverts (zero-amount mint/redeem, insufficient
///         cash, etc.) are swallowed via a selector allowlist; anything else — in particular
///         a raw Panic(0x11) arithmetic overflow, exactly what the pre-fix code would have
///         thrown — is left to propagate and fail the invariant run.
contract CollateralRewardHandler is Test {
    Collateral public collateral;
    MockALPTUnderlying public underlying;
    MockERC20 public rewardToken;

    uint256 constant N_ACTORS = 4;
    address[N_ACTORS] public actors;

    uint256 public totalHarvested;
    uint256 public totalClaimed;

    constructor(Collateral _collateral, MockALPTUnderlying _underlying, MockERC20 _rewardToken) {
        collateral = _collateral;
        underlying = _underlying;
        rewardToken = _rewardToken;
        for (uint256 i = 0; i < N_ACTORS; i++) {
            actors[i] = address(uint160(0x2000 + i));
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % N_ACTORS];
    }

    /// @dev Allowlist of expected, benign business-rule reverts. Anything NOT in this list
    ///      (notably Panic(uint256), selector 0x4e487b71) propagates and fails the run.
    function _isExpectedRevert(bytes memory reason) internal pure returns (bool) {
        if (reason.length < 4) return false;
        bytes4 selector;
        assembly {
            selector := mload(add(reason, 32))
        }
        return selector == PoolToken.MintAmountZero.selector
            || selector == PoolToken.RedeemAmountZero.selector
            || selector == PoolToken.InsufficientCash.selector
            || selector == PoolToken.InsufficientLiquidity.selector
            || selector == Collateral.InsufficientRedeemTokens.selector
            || selector == Collateral.PriceCalculationError.selector
            || selector == PoolToken.MintAmountTooSmall.selector
            || selector == PoolToken.TransferFailed.selector
            || selector == PoolToken.Reentered.selector;
    }

    function mint(uint256 actorSeed, uint96 amt) external {
        address actor = _actor(actorSeed);
        // Full range, including dust below MINIMUM_LIQUIDITY: that now fails with the clear
        // MintAmountTooSmall (allowlisted above) instead of an opaque Panic, so this suite
        // exercises the guard itself rather than avoiding it.
        amt = uint96(bound(amt, 1, 1e24));
        underlying.mint(address(collateral), amt);
        try collateral.mint(actor) {} catch (bytes memory reason) {
            require(_isExpectedRevert(reason), "unexpected revert in mint");
        }
    }

    function redeem(uint256 actorSeed, uint256 fraction) external {
        address actor = _actor(actorSeed);
        uint256 bal = collateral.balanceOf(actor);
        if (bal == 0) return;
        uint256 amt = bound(fraction, 1, bal);
        vm.prank(actor);
        try collateral.transfer(address(collateral), amt) {} catch {
            return; // transfer itself failing isn't what we're testing here
        }
        try collateral.redeem(actor) {} catch (bytes memory reason) {
            require(_isExpectedRevert(reason), "unexpected revert in redeem");
        }
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 fraction) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 bal = collateral.balanceOf(from);
        if (bal == 0) return;
        uint256 amt = bound(fraction, 1, bal);
        vm.prank(from);
        try collateral.transfer(to, amt) {} catch (bytes memory reason) {
            require(_isExpectedRevert(reason), "unexpected revert in transfer");
        }
    }

    /// @dev Deliberately wide range — the exact lever that blew up the live accumulator.
    ///      Tracks harvested amount via the reward token's total supply (freshly minted by
    ///      the mock on every underlying claim), not Collateral's own balance — claimVaultRewards
    ///      below also triggers a harvest internally, and in that path Collateral's balance is
    ///      simultaneously credited (harvest) and debited (payout to caller) in the same call,
    ///      so a balance-delta can't isolate the harvested amount there. Total supply can.
    function harvest(uint128 net) external {
        uint256 amount = bound(net, 0, 1e50);
        underlying.setRewardPerClaim(amount);
        uint256 supplyBefore = rewardToken.totalSupply();
        collateral.harvestVaultRewards();
        totalHarvested += rewardToken.totalSupply() - supplyBefore;
    }

    function claim(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        uint256 before = rewardToken.balanceOf(actor);
        uint256 supplyBefore = rewardToken.totalSupply();
        vm.prank(actor);
        try collateral.claimVaultRewards() {} catch (bytes memory reason) {
            require(_isExpectedRevert(reason), "unexpected revert in claimVaultRewards");
            return;
        }
        // claimVaultRewards() calls harvestVaultRewards() internally first ("so a claim is
        // always up to date") — credit whatever that pulled in too.
        totalHarvested += rewardToken.totalSupply() - supplyBefore;
        totalClaimed += rewardToken.balanceOf(actor) - before;
    }

    function actorsList() external view returns (address[N_ACTORS] memory) {
        return actors;
    }
}
