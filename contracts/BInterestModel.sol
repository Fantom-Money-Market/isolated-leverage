// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./BStorage.sol";
import "./PoolToken.sol";

contract BInterestRateModel is PoolToken, BStorage {
    // --- Custom Errors ---
    error ValueTooLargeForUint112();

    // --- Constants ---
    // When utilization is 100% borrowRate is kinkBorrowRate * KINK_MULTIPLIER
    // kinkBorrowRate relative adjustment per second belongs to [1-adjustSpeed, 1+adjustSpeed*(KINK_MULTIPLIER-1)]
    uint256 public constant KINK_MULTIPLIER = 5;
    uint256 public constant KINK_BORROW_RATE_MAX = 31709792000; // 100% per year
    uint256 public constant KINK_BORROW_RATE_MIN = 317097920;   // 1% per year

    // --- Events ---
    event AccrueInterest(uint256 interestAccumulated, uint256 borrowIndex, uint256 totalBorrows);
    event CalculateKinkBorrowRate(uint256 kinkBorrowRate);
    event CalculateBorrowRate(uint256 borrowRate);

    // --- Internal Functions ---

    function _calculateBorrowRate() internal {
        uint256 _kinkUtilizationRate = kinkUtilizationRate;
        uint256 _adjustSpeed = adjustSpeed;
        uint256 _borrowRate = borrowRate;
        uint256 _kinkBorrowRate = kinkBorrowRate;
        uint32 _rateUpdateTimestamp = rateUpdateTimestamp;

        // update kinkBorrowRate using previous borrowRate
        uint32 timeElapsed;
        unchecked {
            // uint32 timestamp wrap (~year 2106) is intentional; without `unchecked` the
            // 0.8 subtraction would revert and permanently brick rate updates.
            timeElapsed = getBlockTimestamp() - _rateUpdateTimestamp;
        }
        if (timeElapsed > 0) {
            rateUpdateTimestamp = getBlockTimestamp();
            uint256 adjustFactor;

            if (_borrowRate < _kinkBorrowRate) {
                // never overflows, _kinkBorrowRate is never 0
                uint256 tmp = (((_kinkBorrowRate - _borrowRate) * 1e18) / _kinkBorrowRate * _adjustSpeed * timeElapsed) / 1e18;
                adjustFactor = tmp > 1e18 ? 0 : 1e18 - tmp;
            } else {
                // never overflows, _kinkBorrowRate is never 0
                uint256 tmp = (((_borrowRate - _kinkBorrowRate) * 1e18) / _kinkBorrowRate * _adjustSpeed * timeElapsed) / 1e18;
                adjustFactor = tmp + 1e18;
            }

            // never overflows
            _kinkBorrowRate = (_kinkBorrowRate * adjustFactor) / 1e18;
            if (_kinkBorrowRate > KINK_BORROW_RATE_MAX) _kinkBorrowRate = KINK_BORROW_RATE_MAX;
            if (_kinkBorrowRate < KINK_BORROW_RATE_MIN) _kinkBorrowRate = KINK_BORROW_RATE_MIN;

            kinkBorrowRate = uint48(_kinkBorrowRate);
            emit CalculateKinkBorrowRate(_kinkBorrowRate);
        }

        uint256 _utilizationRate;
        { // avoid stack too deep
            uint256 _totalBorrows = totalBorrows; // gas savings
            uint256 _actualBalance = totalBalance + _totalBorrows;
            _utilizationRate = (_actualBalance == 0) ? 0 : (_totalBorrows * 1e18) / _actualBalance;
        }

        // update borrowRate using the new kinkBorrowRate
        if (_utilizationRate <= _kinkUtilizationRate) {
            // never overflows, _kinkUtilizationRate is never 0
            _borrowRate = (_kinkBorrowRate * _utilizationRate) / _kinkUtilizationRate;
        } else {
            // never overflows, _kinkUtilizationRate is always < 1e18
            uint256 overUtilization = ((_utilizationRate - _kinkUtilizationRate) * 1e18) / (1e18 - _kinkUtilizationRate);
            // never overflows
            _borrowRate = (((KINK_MULTIPLIER - 1) * overUtilization + 1e18) * _kinkBorrowRate) / 1e18;
        }
        borrowRate = uint48(_borrowRate);
        emit CalculateBorrowRate(_borrowRate);
    }

    // --- Public Functions ---

    // applies accrued interest to total borrows and reserves
    function accrueInterest() public virtual {
        uint256 _borrowIndex = borrowIndex;
        uint256 _totalBorrows = totalBorrows;
        uint32 _accrualTimestamp = accrualTimestamp;

        uint32 blockTimestamp = getBlockTimestamp();
        if (_accrualTimestamp == blockTimestamp) return;
        uint32 timeElapsed;
        unchecked {
            // wrap at the uint32 timestamp boundary is intentional (see _calculateBorrowRate).
            timeElapsed = blockTimestamp - _accrualTimestamp;
        }
        accrualTimestamp = blockTimestamp;

        uint256 interestFactor = uint256(borrowRate) * timeElapsed;
        uint256 interestAccumulated = (interestFactor * _totalBorrows) / 1e18;
        _totalBorrows += interestAccumulated;
        _borrowIndex += (interestFactor * _borrowIndex) / 1e18;

        borrowIndex = safe112(_borrowIndex);
        totalBorrows = safe112(_totalBorrows);
        emit AccrueInterest(interestAccumulated, _borrowIndex, _totalBorrows);
    }

    function getBlockTimestamp() public view returns (uint32) {
        return uint32(block.timestamp % 2**32);
    }

    // --- Helper Functions ---
    function safe112(uint256 n) internal pure virtual returns (uint112) {
        if (n >= 2**112) revert ValueTooLargeForUint112();
        return uint112(n);
    }
}
