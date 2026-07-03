// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../contracts/Collateral.sol";
import "./harness/MockALPTUnderlying.sol";
import "./harness/MockBorrowableForCollateral.sol";
import "./handlers/CollateralRewardHandler.sol";
import "../../contracts/Stratus-ALM/test/MockERC20.sol";

/// @notice Invariant suite for Collateral.sol's MasterChef accumulator — the same bug class
///         found in the vault, reproduced here without either fix, and worse: the raw
///         multiplication this fix replaces runs inside seize(), so an unguarded overflow
///         there would have blocked liquidation of an underwater borrower, not just one
///         user's claim.
///
///         Two invariants, checked across long random mint/redeem/transfer/harvest/claim
///         sequences (CollateralRewardHandler) against the REAL Collateral contract:
///           1. No handler call ever reverts unexpectedly (fail_on_revert = true; the
///              handler allowlists only benign business-rule reverts).
///           2. Reward conservation: nothing is claimable/claimed beyond what was actually
///              harvested.
///
///   forge test --match-contract CollateralRewardInvariantTest -vv
contract CollateralRewardInvariantTest is Test {
    Collateral collateral;
    MockALPTUnderlying underlying;
    MockERC20 rewardToken;
    MockBorrowableForCollateral borrowable0;
    MockBorrowableForCollateral borrowable1;
    CollateralRewardHandler handler;

    function setUp() public {
        rewardToken = new MockERC20("Reward", "RWD");

        underlying = new MockALPTUnderlying("Mock ALPT", "mALPT", address(rewardToken));
        // seed baseline supply/pricing so getPrices() (called from tokensUnlocked on every
        // transfer) is well-defined throughout the run.
        underlying.mint(address(0xdead), 1_000_000e18);
        underlying.setTotalValueSafe(2_000_000e18);
        underlying.setTwapPrice(1e18);

        collateral = new Collateral();
        collateral._setFactory(); // this test contract becomes `factory`

        borrowable0 = new MockBorrowableForCollateral(address(collateral));
        borrowable1 = new MockBorrowableForCollateral(address(collateral));
        collateral._initialize("cALPT", "cALPT", address(underlying), address(borrowable0), address(borrowable1));
        // borrowBalance defaults to 0 for every account on both mocks, so tokensUnlocked's
        // shortfall check always passes trivially — the handler isn't fighting collateral
        // constraints, it's exercising the reward accumulator specifically.

        handler = new CollateralRewardHandler(collateral, underlying, rewardToken);
        targetContract(address(handler));
    }

    function invariant_rewardConservation() public view {
        uint256 outstanding = 0;
        address[4] memory actors = handler.actorsList();
        for (uint256 i = 0; i < actors.length; i++) {
            outstanding += collateral.pendingVaultReward(actors[i], address(rewardToken));
        }
        assertLe(
            outstanding + handler.totalClaimed(),
            handler.totalHarvested(),
            "Collateral reward accumulator manufactured value out of thin air"
        );
    }
}
