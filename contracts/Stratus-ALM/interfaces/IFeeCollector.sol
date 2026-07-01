// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IFeeCollector {
    function collectFees(uint256 tokenId) external returns (uint256 amount0, uint256 amount1);
    function collectFees(uint256 tokenId, uint256 amount0Max, uint256 amount1Max) external returns (uint256 amount0, uint256 amount1);
}
