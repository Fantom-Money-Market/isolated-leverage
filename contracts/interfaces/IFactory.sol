// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./IBDeployer.sol";
import "./ICDeployer.sol";
import "../LendingPoolStruct.sol";

interface IFactory {

    // --- View Functions ---
    function admin() external view returns (address);
    function pendingAdmin() external view returns (address);
    function reservesAdmin() external view returns (address);
    function reservesPendingAdmin() external view returns (address);
    function reservesManager() external view returns (address);
    function getLendingPool(address stratusALPT) external view returns (LendingPool memory);
    function allLendingPools(uint256 index) external view returns (address);
    function allLendingPoolsLength() external view returns (uint256);
    function bDeployer() external view returns (IBDeployer);
    function cDeployer() external view returns (ICDeployer);

    // --- State-Changing Functions ---
    function createCollateral(address stratusALPT) external returns (address collateral);
    function createBorrowable0(address stratusALPT) external returns (address borrowable0);
    function createBorrowable1(address stratusALPT) external returns (address borrowable1);
    function initializeLendingPool(address stratusALPT) external;
    function _setPendingAdmin(address newPendingAdmin) external;
    function _acceptAdmin() external;
    function _setReservesPendingAdmin(address newReservesPendingAdmin) external;
    function _acceptReservesAdmin() external;
    function _setReservesManager(address newReservesManager) external;
}
