// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../interfaces/ILendingStrategy.sol";
import "../interfaces/IFactory.sol";
import "../interfaces/IBorrowable.sol";
import "../LendingPoolStruct.sol";

contract SimpleLendingStrategy is ILendingStrategy {
    IFactory public immutable factory;
    address public immutable underlying;

    constructor(address _factory, address _underlying) {
        factory = IFactory(_factory);
        underlying = _underlying;
    }

    function getDistribution(uint256 amount)
        external
        view
        override
        returns (address[] memory pools, uint256[] memory amounts)
    {
        uint256 poolCount = factory.allLendingPoolsLength();
        address[] memory validPools = new address[](poolCount);
        uint256 validPoolIndex = 0;

        for (uint i = 0; i < poolCount; i++) {
            address poolAddress = factory.allLendingPools(i);
            // This is a simplified check. A real implementation would need to
            // check which of the two borrowables corresponds to the underlying.
            // For now, we assume borrowable0 is the one we want.
            LendingPool memory lendingPool = factory.getLendingPool(poolAddress);
            if (lendingPool.borrowable0 != address(0)) {
                IBorrowable borrowable = IBorrowable(lendingPool.borrowable0);
                // This check is also simplified. We need to get the underlying of the borrowable.
                // Assuming a function `getUnderlying()` exists on IBorrowable.
                // if (borrowable.getUnderlying() == underlying) {
                //     validPools[validPoolIndex] = lendingPool.borrowable0;
                //     validPoolIndex++;
                // }
            }
        }

        if (validPoolIndex == 0) {
            return (new address[](0), new uint256[](0));
        }

        pools = new address[](validPoolIndex);
        amounts = new uint256[](validPoolIndex);
        uint256 amountPerPool = amount / validPoolIndex;

        for (uint i = 0; i < validPoolIndex; i++) {
            pools[i] = validPools[i];
            amounts[i] = amountPerPool;
        }
    }
}
