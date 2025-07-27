// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./interfaces/IFactory.sol";
import "./interfaces/IStratusALPT.sol";
import "./interfaces/IBorrowable.sol";
import "./LendingPoolStruct.sol";
import "./BStorage.sol";
import "./PoolToken.sol";

/// @title TarotLens
/// @notice A read-only contract to provide view functions for the Tarot protocol.
/// @dev This contract does not hold any state other than the factory address and does not require any funds.
contract TarotLens {
    IFactory public immutable factory;

    /// @notice A struct to hold detailed information about a borrowable pool.
    struct BorrowableInfo {
        address borrowable;      // The address of the borrowable contract
        address collateral;      // The address of the corresponding collateral contract
        address underlying;      // The address of the underlying token you can borrow/lend
        address otherUnderlying; // The address of the other token in the LP pair
        address stratusALPT;     // The address of the Stratus ALPT vault
        uint256 utilization;     // Utilization rate (1e18 precision)
        uint256 totalBorrows;    // Total amount borrowed from the pool
        uint256 totalSupply;     // Total supply in the pool (borrows + cash)
    }

    constructor(address _factory) {
        factory = IFactory(_factory);
    }

    /// @notice Gets the top 5 borrowable pools for a specific token, ranked by utilization rate.
    /// @param _underlyingToken The ERC20 token address to find borrowable pools for.
    /// @return A memory array of up to 5 BorrowableInfo structs, sorted by utilization descending.
    function getTop5BorrowablesByUtilization(address _underlyingToken)
        external
        view
        returns (BorrowableInfo[] memory)
    {
        uint256 poolCount = factory.allLendingPoolsLength();

        BorrowableInfo[5] memory topInfos;
        uint256[5] memory topUtils;
        uint256 topCount = 0;

        for (uint i = 0; i < poolCount; i++) {
            address stratusALPT = factory.allLendingPools(i);
            LendingPool memory lPool = factory.getLendingPool(stratusALPT);

            if (!lPool.initialized) {
                continue;
            }

            address token0 = IStratusALPT(stratusALPT).token0();
            address token1 = IStratusALPT(stratusALPT).token1();

            BorrowableInfo memory currentInfo;
            bool tokenMatch = false;

            if (token0 == _underlyingToken) {
                currentInfo = _getBorrowableInfo(
                    lPool.borrowable0,
                    lPool.collateral,
                    token0,
                    token1,
                    stratusALPT
                );
                tokenMatch = true;
            } else if (token1 == _underlyingToken) {
                currentInfo = _getBorrowableInfo(
                    lPool.borrowable1,
                    lPool.collateral,
                    token1,
                    token0,
                    stratusALPT
                );
                tokenMatch = true;
            }

            if (tokenMatch) {
                _insertIntoTop(topInfos, topUtils, currentInfo, currentInfo.utilization);
                if (topCount < 5) {
                    topCount++;
                }
            }
        }

        BorrowableInfo[] memory result = new BorrowableInfo[](topCount);
        for (uint i = 0; i < topCount; i++) {
            result[i] = topInfos[i];
        }

        return result;
    }

    /// @notice Gets all borrowable pools for a specific underlying token, including their utilization.
    /// @param _underlyingToken The ERC20 token address to find borrowable pools for.
    /// @return A memory array of BorrowableInfo structs for all matching pools.
    function getBorrowablesForToken(address _underlyingToken)
        external
        view
        returns (BorrowableInfo[] memory)
    {
        uint256 poolCount = factory.allLendingPoolsLength();

        // First pass: count matching pools to allocate exact array size
        uint256 matchCount = 0;
        for (uint i = 0; i < poolCount; i++) {
            address stratusALPT = factory.allLendingPools(i);
            LendingPool memory lPool = factory.getLendingPool(stratusALPT);
            
            if (!lPool.initialized) continue;
            
            address token0 = IStratusALPT(stratusALPT).token0();
            address token1 = IStratusALPT(stratusALPT).token1();
            
            if (token0 == _underlyingToken || token1 == _underlyingToken) {
                matchCount++;
            }
        }
        
        // Create result array with exact size needed
        BorrowableInfo[] memory result = new BorrowableInfo[](matchCount);
        uint256 resultIndex = 0;
        
        // Second pass: populate the result array
        for (uint i = 0; i < poolCount && resultIndex < matchCount; i++) {
            address stratusALPT = factory.allLendingPools(i);
            LendingPool memory lPool = factory.getLendingPool(stratusALPT);
            
            if (!lPool.initialized) continue;
            
            address token0 = IStratusALPT(stratusALPT).token0();
            address token1 = IStratusALPT(stratusALPT).token1();
            
            if (token0 == _underlyingToken) {
                result[resultIndex++] = _getBorrowableInfo(
                    lPool.borrowable0,
                    lPool.collateral,
                    token0,
                    token1,
                    stratusALPT
                );
            } else if (token1 == _underlyingToken) {
                result[resultIndex++] = _getBorrowableInfo(
                    lPool.borrowable1,
                    lPool.collateral,
                    token1,
                    token0,
                    stratusALPT
                );
            }
        }
        
        return result;
    }

    /// @dev Internal helper to fetch details for a single borrowable.
    function _getBorrowableInfo(
        address borrowableAddress,
        address collateralAddress,
        address underlyingToken,
        address otherToken,
        address stratusALPTAddress
    ) internal view returns (BorrowableInfo memory) {
        IBorrowable borrowable = IBorrowable(borrowableAddress);
        uint256 totalBorrows = BStorage(borrowableAddress).totalBorrows();
        uint256 totalCash = PoolToken(borrowableAddress).totalBalance();
        uint256 totalSupply = totalBorrows + totalCash;
        uint256 utilization = 0;
        if (totalSupply > 0) {
            utilization = (totalBorrows * 1e18) / totalSupply;
        }

        return BorrowableInfo({
            borrowable: borrowableAddress,
            collateral: collateralAddress,
            underlying: underlyingToken,
            otherUnderlying: otherToken,
            stratusALPT: stratusALPTAddress,
            utilization: utilization,
            totalBorrows: totalBorrows,
            totalSupply: totalSupply
        });
    }

    /// @dev Internal helper to insert a pool into the top 5, sorted by utilization.
    function _insertIntoTop(
        BorrowableInfo[5] memory topInfos,
        uint256[5] memory topUtils,
        BorrowableInfo memory info,
        uint256 util
    ) internal pure {
        for (uint i = 0; i < 5; i++) {
            if (util > topUtils[i]) {
                for (uint j = 4; j > i; j--) {
                    topInfos[j] = topInfos[j - 1];
                    topUtils[j] = topUtils[j - 1];
                }
                topInfos[i] = info;
                topUtils[i] = util;
                break;
            }
        }
    }
}