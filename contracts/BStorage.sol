// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

contract BStorage {
    address public collateral;

    mapping(address => mapping(address => uint256)) public borrowAllowance;

    struct BorrowSnapshot {
        uint112 principal; // amount in underlying when the borrow was last updated
        uint112 interestIndex; // borrow index when borrow was last updated
    }
    mapping(address => BorrowSnapshot) internal borrowBalances;

    // use one memory slot
    uint112 public borrowIndex = 1e18;
    uint112 public totalBorrows;
    uint32 public accrualTimestamp;

    uint256 public exchangeRateLast;

    // use one memory slot
    uint48 public borrowRate;
    uint48 public kinkBorrowRate = 3170979200; // 10% per year
    uint32 public rateUpdateTimestamp;

    uint256 public reserveFactor = 100000000000000000; // 10%
    uint256 public kinkUtilizationRate = 700000000000000000; // 70%
    uint256 public adjustSpeed = 578703700000; // 5% per day
    address public borrowTracker;

    constructor() {
        accrualTimestamp = uint32(block.timestamp % 2**32);
        rateUpdateTimestamp = uint32(block.timestamp % 2**32);
    }
}
