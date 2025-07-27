// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface ICollateral {
    // --- Events ---
    event NewSafetyMargin(uint256 newSafetyMarginSqrt);
    event NewLiquidationIncentive(uint256 newLiquidationIncentive);

    // --- View Functions ---
    function getPrices() external view returns (uint256 price0, uint256 price1);
    function tokensUnlocked(address from, uint256 value) external returns (bool);
    function accountLiquidityAmounts(address borrower, uint256 amount0, uint256 amount1) external returns (uint256 liquidity, uint256 shortfall);
    function accountLiquidity(address borrower) external returns (uint256 liquidity, uint256 shortfall);
    function canBorrow(address borrower, address borrowable, uint256 accountBorrows) external returns (bool);
    function exchangeRate() external returns (uint256);

    // --- State-Changing Functions ---
    function _initialize(string calldata _name, string calldata _symbol, address _underlying, address _borrowable0, address _borrowable1) external;
    function _setFactory() external;
    function seize(address liquidator, address borrower, uint256 repayAmount) external returns (uint256 seizeTokens);
    function flashRedeem(address redeemer, uint256 redeemAmount, bytes calldata data) external;
    function mint(address minter) external returns (uint256 mintTokens);
    function redeem(address redeemer) external returns (uint256 redeemAmount);
}
