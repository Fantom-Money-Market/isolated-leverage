// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface ITarotPriceOracle {
    function getResult(address underlying)
        external
        view
        returns (uint224 twapPrice112x112, uint32 lastUpdate);

    function getPair(address stratusALPT)
        external
        view
        returns (
            address token0,
            address token1,
            uint32 period,
            uint32 lastUpdate,
            uint224 price,
            bool initialized
        );

    function initialize(address stratusALPT) external;
}
