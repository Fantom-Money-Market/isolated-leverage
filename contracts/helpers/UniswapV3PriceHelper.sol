// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "../Stratus-ALM/libraries/TickMath.sol";
import "../Stratus-ALM/interfaces/IRamsesV3Pool.sol";

/// @title Uniswap V3 Price Helper Library
/// @notice Helper library for extracting price data from Uniswap V3 pools
/// @dev V3 pools ARE oracles - this library abstracts how to query them
library UniswapV3PriceHelper {
    /// @notice Precision constant for price calculations (18 decimals)
    uint256 private constant PRICE_PRECISION = 1e18;

    /// @notice 2**96, the scaling factor used by Q64.96 sqrt prices
    uint256 private constant Q96 = 0x1000000000000000000000000;
    
    /// @notice Get current spot price from V3 pool
    /// @param pool Address of the V3 pool
    /// @return price Price in normalized format (token1 per token0, 1e18 precision)
    /// @dev Uses slot0() to get current sqrtPriceX96, then converts to standard price
    function getSpotPrice(address pool) public view returns (uint256 price) {
        // IRamsesV3Pool exposes the standard V3 slot0(); using it (rather than a
        // separate IUniswapV3Pool) avoids an interface-name clash with the inline
        // IUniswapV3Pool declared in BaseLiquidityVault.
        (uint160 sqrtPriceX96, , , , , , ) = IRamsesV3Pool(pool).slot0();
        price = _sqrtPriceX96ToPrice(sqrtPriceX96);
    }
    
    /// @notice Get TWAP price from V3 pool using observe() function
    /// @param pool Address of the V3 pool
    /// @param twapWindow Time window for TWAP in seconds
    /// @return price TWAP price in normalized format (token1 per token0, 1e18 precision)
    /// @dev Uses pool.observe() which IS the oracle - no separate oracle needed!
    function getTWAPPrice(address pool, uint32 twapWindow) public view returns (uint256 price) {
        price = tickToPrice(getTWAPTick(pool, twapWindow));
    }

    /// @notice Time-weighted average tick over the window
    /// @param pool Address of the V3 pool
    /// @param twapWindow Time window for TWAP in seconds
    /// @return twapTick The arithmetic-mean tick over the window (rounded toward -inf)
    /// @dev Use this (via TickMath.getSqrtRatioAtTick) to evaluate a position's
    ///      token split at the TWAP price, making valuation manipulation-resistant.
    function getTWAPTick(address pool, uint32 twapWindow) public view returns (int24 twapTick) {
        require(twapWindow > 0, "UniswapV3PriceHelper: twapWindow must be > 0");

        // Query pool observations - the pool IS the oracle.
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;  // Start of window
        secondsAgos[1] = 0;           // Current time

        (int56[] memory tickCumulatives, ) = IRamsesV3Pool(pool).observe(secondsAgos);

        int56 tickCumulativeDelta = tickCumulatives[1] - tickCumulatives[0];
        twapTick = int24(tickCumulativeDelta / int56(uint56(twapWindow)));

        // Round toward negative infinity for negative deltas (V3 convention)
        if (tickCumulativeDelta < 0 && (tickCumulativeDelta % int56(uint56(twapWindow)) != 0)) {
            twapTick--;
        }
    }
    
    /// @notice Convert tick to price using TickMath library
    /// @param tick The tick value
    /// @return price Price in normalized format (token1 per token0, 1e18 precision)
    /// @dev Uses TickMath library for accurate conversion
    function tickToPrice(int24 tick) public pure returns (uint256 price) {
        // Use TickMath to get sqrtPriceX96 from tick, then convert to a 1e18 price
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);
        price = _sqrtPriceX96ToPrice(sqrtPriceX96);
    }

    /// @notice Convert a Q64.96 sqrt price to a 1e18-scaled price (token1 per token0)
    /// @param sqrtPriceX96 The sqrt price in Q64.96 format (sqrt(price) * 2^96)
    /// @return price The price scaled to 1e18 precision
    /// @dev price = (sqrtPriceX96 / 2^96)^2 * 1e18. Uses Math.mulDiv so the
    ///      intermediate sqrtPriceX96^2 (up to 2^320) cannot overflow and no
    ///      precision is lost for sub-integer prices. The previous version
    ///      shifted right by 192 first, truncating any ratio < 2^96 to zero.
    function _sqrtPriceX96ToPrice(uint160 sqrtPriceX96) private pure returns (uint256 price) {
        // ratioX96 = sqrtPriceX96^2 / 2^96  == price * 2^96
        uint256 ratioX96 = Math.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), Q96);
        // price = (price * 2^96) * 1e18 / 2^96  == price * 1e18
        price = Math.mulDiv(ratioX96, PRICE_PRECISION, Q96);
    }
    
    /// @notice Get both spot and TWAP prices
    /// @param pool Address of the V3 pool
    /// @param twapWindow Time window for TWAP in seconds
    /// @return spotPrice Current spot price
    /// @return twapPrice TWAP price over the specified window
    function getPrices(address pool, uint32 twapWindow) 
        internal 
        view 
        returns (uint256 spotPrice, uint256 twapPrice) 
    {
        spotPrice = getSpotPrice(pool);
        twapPrice = getTWAPPrice(pool, twapWindow);
    }
}

