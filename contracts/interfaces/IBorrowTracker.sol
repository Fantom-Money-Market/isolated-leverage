// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IBorrowTracker {
    function trackBorrow(
        address borrower,
        uint256 accountBorrows,
        uint256 borrowIndex
    ) external;
}
