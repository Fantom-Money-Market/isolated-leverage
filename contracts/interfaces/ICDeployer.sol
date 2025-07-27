// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface ICDeployer {
    function deployCollateral(address stratusALPT) external returns (address collateral);
}
