// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IThickVault {
    function deposit(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) external returns (uint256 shares);

    function transfer(address to, uint256 amount) external returns (bool);

    function pool() external view returns (address);
}
