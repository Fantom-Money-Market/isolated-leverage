// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface ILendingStrategy {
    function getDistribution(uint256 amount)
        external
        view
        returns (address[] memory pools, uint256[] memory amounts);
}
