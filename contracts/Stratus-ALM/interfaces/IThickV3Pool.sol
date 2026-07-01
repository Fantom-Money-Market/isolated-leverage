// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IThickV3Pool
/// @notice Minimal Thick (Equalizer "Thickv2") CL pool interface. Thick is a FAITHFUL
///         Uniswap V3 fork: mint/burn/collect carry NO `index` parameter (unlike Shadow),
///         the position key is keccak256(abi.encodePacked(owner, tickLower, tickUpper)),
///         positions() returns the standard 5 fields, and the pool keys by tickSpacing.
/// @dev Confirmed on Sonic against the Thick CL factory 0x7Ca1dCCFB4f49564b8f13E18a67747fd428F1C40
///      (getPool(tokenA, tokenB, int24 tickSpacing)) and pool 0xb1BC…8038 (12-field NFP
///      positions => vanilla V3 core).
interface IThickV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    /// @notice Position state, keyed by keccak256(abi.encodePacked(owner, tickLower, tickUpper)).
    function positions(bytes32 key)
        external
        view
        returns (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    // ----- actions (vanilla Uniswap V3: no index) -----

    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1);

    function burn(int24 tickLower, int24 tickUpper, uint128 amount)
        external
        returns (uint256 amount0, uint256 amount1);

    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external returns (uint128 amount0, uint128 amount1);
}

/// @title IThickV3Factory
/// @notice Resolves a Thick CL pool from its token pair + tick spacing, so the Stratus
///         factory needs no pre-known pool addresses.
interface IThickV3Factory {
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address pool);
}
