// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ICollateralSeize {
    function seize(address liquidator, address borrower, uint256 repayAmount) external returns (uint256);
}

/// @notice Foundry-only stand-in for a Tarot Borrowable, minimal enough for Collateral.sol's
///         accountLiquidity/seize paths: a settable borrowBalance per account, and a wrapper
///         that calls Collateral.seize() as this contract (satisfying the
///         `msg.sender == borrowable0 || borrowable1` check).
contract MockBorrowableForCollateral {
    mapping(address => uint256) public borrowBalance;
    address public immutable collateral;

    constructor(address _collateral) {
        collateral = _collateral;
    }

    function setBorrowBalance(address who, uint256 amt) external {
        borrowBalance[who] = amt;
    }

    function callSeize(address liquidator, address borrower, uint256 repayAmount) external returns (uint256) {
        return ICollateralSeize(collateral).seize(liquidator, borrower, repayAmount);
    }
}
