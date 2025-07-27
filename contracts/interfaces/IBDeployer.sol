// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IBDeployer {
    function deployBorrowable(address stratusALPT, uint8 index) external returns (address borrowable);
}
