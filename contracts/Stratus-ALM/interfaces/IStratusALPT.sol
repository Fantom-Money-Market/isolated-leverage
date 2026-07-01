// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IStratusALPT {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}
