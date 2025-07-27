// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IBorrowable {
    // --- Events ---
    event Borrow(address indexed sender, address indexed borrower, address indexed receiver, uint256 borrowAmount, uint256 repayAmount, uint256 accountBorrowsPrior, uint256 accountBorrows, uint256 totalBorrows);
    event Liquidate(address indexed sender, address indexed borrower, address indexed liquidator, uint256 seizeTokens, uint256 repayAmount, uint256 accountBorrowsPrior, uint256 accountBorrows, uint256 totalBorrows);
    event NewReserveFactor(uint256 newReserveFactor);
    event NewKinkUtilizationRate(uint256 newKinkUtilizationRate);
    event NewAdjustSpeed(uint256 newAdjustSpeed);
    event NewBorrowTracker(address newBorrowTracker);
    event BorrowApproval(address indexed owner, address indexed spender, uint256 value);

    // --- View Functions ---
    function borrowBalance(address borrower) external view returns (uint256);
    function exchangeRate() external returns (uint256);
    // totalBorrows() is provided by public state variable in BStorage
    // totalBalance() is provided by public state variable in PoolToken

    // --- State-Changing Functions ---
    function _initialize(string calldata _name, string calldata _symbol, address _underlying, address _collateral) external;
    function _setFactory() external;
    // balanceOf() is provided by public mapping in TarotERC20
    function borrow(address borrower, address receiver, uint256 borrowAmount, bytes calldata data) external;
    // borrowRate() is provided by public state variable in BStorage
    function liquidate(address borrower, address liquidator) external returns (uint256 seizeTokens);
    function borrowApprove(address spender, uint256 value) external returns (bool);
    function borrowPermit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
    function trackBorrow(address borrower) external;
    function accrueInterest() external;
    function sync() external;
    function mint(address minter) external returns (uint256 mintTokens);
    function redeem(address redeemer) external returns (uint256 redeemAmount);
}
