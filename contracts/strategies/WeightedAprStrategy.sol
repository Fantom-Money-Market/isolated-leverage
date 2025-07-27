// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../interfaces/ILendingStrategy.sol";
import "../interfaces/ITarotLens.sol";
import "../interfaces/IBorrowable.sol";
import "../BStorage.sol";

/// @title WeightedAprStrategy
/// @notice A lending strategy that distributes assets to pools with the highest time-weighted average borrow rates.
/// @dev This strategy uses the TarotLens to find high-utilization pools, then ranks them by TWAP APR.
contract WeightedAprStrategy is ILendingStrategy {
    struct PoolInfo {
        uint256 lastUpdateTime;
        uint256 rateAccumulator;
        uint256 lastBorrowRate;
    }

    ITarotLens public immutable lens;
    address public immutable underlying;
    mapping(address => PoolInfo) public poolInfo;

    /// @param _lens The address of the deployed TarotLens contract.
    /// @param _underlying The address of the underlying token this strategy will manage.
    constructor(address _lens, address _underlying) {
        lens = ITarotLens(_lens);
        underlying = _underlying;
    }

    /// @notice Determines the distribution of a given amount across lending pools, weighted by TWAP borrow APR.
    /// @param amount The total amount of the underlying token to be distributed.
    /// @return pools An array of borrowable contract addresses to lend to.
    /// @return amounts An array of corresponding amounts to lend to each pool.
    function getDistribution(uint256 amount)
        external
        view
        override
        returns (address[] memory pools, uint256[] memory amounts)
    {
        ITarotLens.BorrowableInfo[] memory topPoolsByUtil = lens.getTop5BorrowablesByUtilization(underlying);
        uint256 poolsLength = topPoolsByUtil.length;

        if (poolsLength == 0) {
            return (new address[](0), new uint256[](0));
        }

        pools = new address[](poolsLength);
        uint256[] memory twaps = new uint256[](poolsLength);
        uint256 totalTwap = 0;

        for (uint i = 0; i < poolsLength; i++) {
            address poolAddress = topPoolsByUtil[i].borrowable;
            pools[i] = poolAddress;
            uint256 twap = getTwap(poolAddress);
            twaps[i] = twap;
            totalTwap += twap;
        }

        amounts = new uint256[](poolsLength);
        if (totalTwap == 0) {
            // If total TWAP is zero, distribute evenly.
            uint256 amountPerPool = amount / poolsLength;
            for (uint i = 0; i < poolsLength; i++) {
                amounts[i] = amountPerPool;
            }
            amounts[0] += amount % poolsLength;
            return (pools, amounts);
        }

        uint256 amountDistributed = 0;
        for (uint i = 0; i < poolsLength; i++) {
            if (i == poolsLength - 1) {
                amounts[i] = amount - amountDistributed;
            } else {
                uint256 weightedAmount = (amount * twaps[i]) / totalTwap;
                amounts[i] = weightedAmount;
                amountDistributed += weightedAmount;
            }
        }
    }

    /// @notice Calculates the Time-Weighted Average borrow rate for a pool.
    /// @param pool The address of the borrowable contract.
    /// @return The TWAP of the borrow rate.
    function getTwap(address pool) public view returns (uint256) {
        PoolInfo memory info = poolInfo[pool];
        uint256 currentRate = BStorage(pool).borrowRate();
        uint256 timeElapsed = block.timestamp - info.lastUpdateTime;
        
        if (timeElapsed == 0 || info.lastUpdateTime == 0) {
            // If no time has passed or it's the first time, return the current rate.
            return currentRate;
        }

        // The accumulator stores the sum of (rate * time_elapsed) for each period.
        // The TWAP is the total accumulated value divided by the total time.
        return (info.rateAccumulator + (info.lastBorrowRate * timeElapsed)) / timeElapsed;
    }

    /// @notice Updates the rate accumulator for a pool. Should be called periodically.
    /// @param pool The address of the borrowable contract to update.
    function update(address pool) external {
        PoolInfo storage info = poolInfo[pool];
        uint256 lastUpdate = info.lastUpdateTime;

        if (lastUpdate == 0) {
            // First time updating this pool
            info.lastUpdateTime = block.timestamp;
        } else {
            uint256 timeElapsed = block.timestamp - lastUpdate;
            if (timeElapsed > 0) {
                // This calculation prevents the accumulator from growing indefinitely
                // and weights more recent rates higher over the long term.
                // A simpler `info.rateAccumulator += info.lastBorrowRate * timeElapsed` could also be used.
                info.rateAccumulator = (info.rateAccumulator + (info.lastBorrowRate * timeElapsed)) / 2;
                info.lastUpdateTime = block.timestamp;
            }
        }
        info.lastBorrowRate = BStorage(pool).borrowRate();
    }
}
