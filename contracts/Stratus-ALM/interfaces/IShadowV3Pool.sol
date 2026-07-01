// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IShadowV3Pool
/// @notice Minimal Shadow (Ramses V3 fork) CL pool interface for direct-pool
///         liquidity management (Gamma Hypervisor model), with the Shadow-specific
///         `index` parameter on mint/burn/collect.
/// @dev Verified against Shadow/shadow-core/contracts/CL/core/RamsesV3Pool.sol.
///      KEY DIFFERENCE vs Uniswap V3: mint/burn/collect carry a `uint256 index`,
///      and the position key is keccak256(abi.encodePacked(owner, index, tickLower, tickUpper)).
interface IShadowV3Pool {
    // ----- immutables / state -----
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

    /// @notice TWAP oracle. tickCumulatives[1]-tickCumulatives[0] over the window / window = time-weighted tick.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    /// @notice Position state, keyed by keccak256(abi.encodePacked(owner, index, tickLower, tickUpper)).
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

    // ----- actions (note the `index` parameter) -----

    /// @notice Mint liquidity; the pool calls back uniswapV3MintCallback to pull payment.
    function mint(
        address recipient,
        uint256 index,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1);

    /// @notice Burn liquidity (use amount=0 to force a fee recompute before collect).
    function burn(
        uint256 index,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external returns (uint256 amount0, uint256 amount1);

    /// @notice Collect tokens owed (fees and/or burned principal) for a position.
    function collect(
        address recipient,
        uint256 index,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external returns (uint128 amount0, uint128 amount1);

    /// @notice Swap; the pool calls back uniswapV3SwapCallback to pull the input.
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

/// @notice Shadow keeps the Uniswap V3 callback selector names (verified in RamsesV3Pool.sol).
interface IUniswapV3MintCallback {
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external;
}

interface IUniswapV3SwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// @title IShadowGaugeV3
/// @notice Minimal Shadow CL gauge interface for claiming emissions on a
///         directly-held pool position (no NFT required).
/// @dev Verified against Shadow/shadow-core/contracts/CL/gauge/GaugeV3.sol.
///      positionHash(owner, index, tickLower, tickUpper) == the pool position key,
///      so one (owner, index, ticks) identifies both the liquidity and its rewards.
interface IShadowGaugeV3 {
    /// @notice The CL pool this gauge rewards (lets callers resolve pool from gauge).
    function pool() external view returns (address);

    function getRewardTokens() external view returns (address[] memory);

    function positionHash(
        address owner,
        uint256 index,
        int24 tickLower,
        int24 tickUpper
    ) external pure returns (bytes32);

    function earned(address token, uint256 tokenId) external view returns (uint256 reward);

    /// @notice Claim emissions for a directly-held pool position. Caller must be `owner`.
    function getReward(
        address owner,
        uint256 index,
        int24 tickLower,
        int24 tickUpper,
        address[] calldata tokens,
        address receiver
    ) external;
}

/// @title IShadowVoter
/// @notice Minimal Shadow voter interface to resolve a CL pool's gauge from its
///         token pair + tick spacing, so the factory needs no pool/gauge addresses.
/// @dev Verified against Shadow/shadow-core/contracts/Voter.sol.
interface IShadowVoter {
    function gaugeForClPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address);
    function mainTickSpacingForPair(address tokenA, address tokenB) external view returns (int24);
}
