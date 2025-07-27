// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface ITarotCallee {
    function tarotBorrow(
        address sender,
        address borrower,
        uint256 amount,
        bytes calldata data
    ) external;

    function tarotRedeem(
        address sender,
        uint256 amount,
        bytes calldata data
    ) external;
}
