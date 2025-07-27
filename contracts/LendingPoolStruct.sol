// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title LendingPoolStruct
/// @notice Defines the structure for a LendingPool.
struct LendingPool {
    bool initialized;
    uint24 lendingPoolId;
    address collateral;
    address borrowable0;
    address borrowable1;
}
