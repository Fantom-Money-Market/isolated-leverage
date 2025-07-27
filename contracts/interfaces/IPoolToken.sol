// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IPoolToken {
    event Mint(address indexed sender, address indexed minter, uint256 mintAmount, uint256 mintTokens);
    event Redeem(address indexed sender, address indexed redeemer, uint256 redeemAmount, uint256 redeemTokens);
    event Sync(uint256 totalBalance);

    function _setFactory() external;
    function exchangeRate() external returns (uint256);
    function mint(address minter) external returns (uint256 mintTokens);
    function redeem(address redeemer) external returns (uint256 redeemAmount);
    function skim(address to) external;
    function sync() external;
}
