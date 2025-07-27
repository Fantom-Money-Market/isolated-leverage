// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface ITarotLens {
    struct BorrowableInfo {
        address borrowable;
        address collateral;
        address underlying;
        address otherUnderlying;
        address stratusALPT;
        uint256 utilization;
        uint256 totalBorrows;
        uint256 totalSupply;
    }

    function getTop5BorrowablesByUtilization(address _underlyingToken)
        external
        view
        returns (BorrowableInfo[] memory);
}
