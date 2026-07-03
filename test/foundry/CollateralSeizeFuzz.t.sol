// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../../contracts/Collateral.sol";
import "./harness/MockALPTUnderlying.sol";
import "./harness/MockBorrowableForCollateral.sol";
import "../../contracts/Stratus-ALM/test/MockERC20.sol";

/// @notice Surgical fuzz test isolating the single most severe consequence of the accumulator
///         bug: _settleVaultRewards runs inside seize(), so an unguarded overflow there would
///         block liquidation of an underwater borrower — a direct threat to solvency, not
///         just a UX annoyance. The liquidation setup here (shortfall, repayAmount vs.
///         borrower balance) is deterministic and always valid by construction, so the
///         fuzzer's entire budget goes into stressing the ONE thing that should matter here:
///         how extreme the reward accumulator is when seize() is called.
///
///   forge test --match-contract CollateralSeizeFuzzTest -vv
contract CollateralSeizeFuzzTest is Test {
    Collateral collateral;
    MockALPTUnderlying underlying;
    MockERC20 rewardToken;
    MockBorrowableForCollateral borrowable0;
    MockBorrowableForCollateral borrowable1;

    address borrower = address(0xB0);
    address liquidator = address(0x11);

    function setUp() public {
        rewardToken = new MockERC20("Reward", "RWD");

        underlying = new MockALPTUnderlying("Mock ALPT", "mALPT", address(rewardToken));
        underlying.mint(address(0xdead), 1_000_000e18);
        underlying.setTotalValueSafe(2_000_000e18);
        underlying.setTwapPrice(1e18);

        collateral = new Collateral();
        collateral._setFactory();
        borrowable0 = new MockBorrowableForCollateral(address(collateral));
        borrowable1 = new MockBorrowableForCollateral(address(collateral));
        collateral._initialize("cALPT", "cALPT", address(underlying), address(borrowable0), address(borrowable1));

        // borrower posts collateral; liquidator also holds some (so both get a real
        // pre-extreme-harvest checkpoint via _settleVaultRewards inside mint()).
        underlying.mint(address(collateral), 10_000e18);
        collateral.mint(borrower);
        underlying.mint(address(collateral), 5_000e18);
        collateral.mint(liquidator);

        // guarantee the borrower is underwater regardless of price specifics: an
        // astronomically large mocked debt trivially exceeds any collateral value.
        borrowable0.setBorrowBalance(borrower, 1e30);
    }

    function testFuzz_seize_survivesExtremeAccumulator(uint256 harvestAmount, uint256 secondHarvestAmount) public {
        harvestAmount = bound(harvestAmount, 0, 1e60);
        secondHarvestAmount = bound(secondHarvestAmount, 0, 1e60);

        // sanity: genuinely underwater before we touch rewards at all.
        (, uint256 shortfallBefore) = collateral.accountLiquidity(borrower);
        assertGt(shortfallBefore, 0, "setup sanity: borrower must be underwater");

        // fuzzed accumulator stress, potentially compounding across two harvests (closer to
        // how the live bug actually grows: repeated tiny/large harvests over time, not one
        // single event).
        underlying.setRewardPerClaim(harvestAmount);
        collateral.harvestVaultRewards();
        underlying.setRewardPerClaim(secondHarvestAmount);
        collateral.harvestVaultRewards();

        // liquidation must still succeed: repay a small, safe fraction of the debt so
        // seizeTokens is guaranteed to stay under the borrower's balance regardless of price.
        uint256 borrowerBalance = collateral.balanceOf(borrower);
        (uint256 price0, ) = collateral.getPrices();
        uint256 liquidationIncentive = collateral.liquidationIncentive();
        uint256 exchangeRate = collateral.exchangeRate();
        // invert seizeTokens = repayAmount * liquidationIncentive / 1e18 * price0 / exchangeRate
        // targeting seizeTokens == borrowerBalance / 20 (5%), comfortably under the cap.
        uint256 targetSeize = borrowerBalance / 20;
        uint256 repayAmount = Math.mulDiv(targetSeize, exchangeRate, Math.mulDiv(liquidationIncentive, price0, 1e18));
        vm.assume(repayAmount > 0);

        uint256 liqBalBefore = collateral.balanceOf(liquidator);
        uint256 seizeTokens = borrowable0.callSeize(liquidator, borrower, repayAmount);

        assertLe(seizeTokens, borrowerBalance, "seize must never take more than the borrower has");
        assertEq(
            collateral.balanceOf(liquidator) - liqBalBefore,
            seizeTokens,
            "liquidator must receive exactly the seized amount"
        );
    }
}
