// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @notice Interface for Balancer Weighted LP Oracle
/// @dev This matches the IWeightedLPOracle and ILPOracleBase interface from Balancer
/// @dev Based on @balancer-labs/v3-interfaces contracts/oracles/ILPOracleBase.sol
interface IWeightedLPOracle {
    /// @notice Get latest oracle result for a specific variable
    /// @param variable Variable index (e.g., BPT_PRICE_IN_TOKEN_0, SPOT_PRICE_TOKEN0_TOKEN1, etc.)
    /// @return Latest value for the specified variable
    /// @dev Variable indices: 0 = BPT price in token0, 1 = BPT price in token1, 2 = spot price token0/token1, etc.
    function getLatest(uint256 variable) external view returns (uint256);
    
    /// @notice Get time-weighted average for a specific variable
    /// @param variable Variable index (e.g., SPOT_PRICE_TOKEN0_TOKEN1)
    /// @param secs Time window in seconds for the TWAP
    /// @return Time-weighted average value for the specified variable
    function getTimeWeightedAverage(uint256 variable, uint256 secs) external view returns (uint256);
}

/// @title Balancer Price Helper Library
/// @notice Helper library for extracting price data from Balancer pools using WeightedLPOracle
/// @dev Uses Balancer's WeightedLPOracle contract (from @balancer-labs/v3-interfaces)
/// @dev The oracle is a separate contract that uses Chainlink feeds and computes TVL
library BalancerPriceHelper {
    
    /// @notice Oracle variable indices (standard Balancer oracle interface)
    /// @dev These may vary by oracle implementation - adjust based on actual oracle interface
    uint256 private constant BPT_PRICE_IN_TOKEN_0 = 0;
    uint256 private constant BPT_PRICE_IN_TOKEN_1 = 1;
    uint256 private constant SPOT_PRICE_TOKEN0_TOKEN1 = 2;
    uint256 private constant SPOT_PRICE_TOKEN1_TOKEN0 = 3;
    
    /// @notice Get current spot price from Balancer oracle
    /// @param oracle Address of the Balancer WeightedLPOracle contract
    /// @return price Price in normalized format (token1 per token0, 1e18 precision)
    /// @dev Uses Balancer's WeightedLPOracle.getLatest(variable) function with SPOT_PRICE_TOKEN0_TOKEN1
    function getSpotPrice(address oracle) internal view returns (uint256 price) {
        // Balancer's WeightedLPOracle contract provides getLatest(variable)
        // This oracle uses Chainlink feeds and computes prices based on pool state
        // Query spot price token0/token1 using variable index 2
        uint256 priceToken0Token1 = IWeightedLPOracle(oracle).getLatest(SPOT_PRICE_TOKEN0_TOKEN1);
        
        // If getLatest() returns 0, it may mean the oracle isn't initialized
        // or the price isn't available. Try the inverse variable
        if (priceToken0Token1 == 0) {
            // Try getting token1/token0 directly
            priceToken0Token1 = IWeightedLPOracle(oracle).getLatest(SPOT_PRICE_TOKEN1_TOKEN0);
            if (priceToken0Token1 == 0) {
                revert("BalancerPriceHelper: oracle returned zero price");
            }
            // Already in token1/token0 format
            price = priceToken0Token1;
        } else {
            // getLatest(SPOT_PRICE_TOKEN0_TOKEN1) returns price in token0/token1 format
            // We want token1/token0, so invert: price = 1e18 * 1e18 / priceToken0Token1
            // Assuming both are in 1e18 precision
            price = (1e18 * 1e18) / priceToken0Token1;
        }
    }
    
    /// @notice Get TWAP price from Balancer oracle
    /// @param oracle Address of the Balancer WeightedLPOracle contract
    /// @param twapWindow Time window for TWAP in seconds
    /// @return price TWAP price in normalized format (token1 per token0)
    /// @dev Uses Balancer's WeightedLPOracle.getTimeWeightedAverage() for TWAP queries
    function getTWAPPrice(address oracle, uint32 twapWindow) internal view returns (uint256 price) {
        require(twapWindow > 0, "BalancerPriceHelper: twapWindow must be > 0");
        
        // Balancer's WeightedLPOracle provides getTimeWeightedAverage()
        // Query using variable index for spot price token0/token1
        // Note: Exact variable index may vary - adjust SPOT_PRICE_TOKEN0_TOKEN1 as needed
        uint256 twapValue = IWeightedLPOracle(oracle).getTimeWeightedAverage(
            SPOT_PRICE_TOKEN0_TOKEN1,
            twapWindow
        );
        
        if (twapValue == 0) {
            // Fallback to spot price if TWAP unavailable
            price = getSpotPrice(oracle);
        } else {
            // Invert to get token1/token0
            price = (1e18 * 1e18) / twapValue;
        }
    }
    
    /// @notice Get both spot and TWAP prices
    /// @param oracle Address of the Balancer WeightedLPOracle contract
    /// @param twapWindow Time window for TWAP in seconds
    /// @return spotPrice Current spot price
    /// @return twapPrice TWAP price over the specified window
    function getPrices(
        address oracle,
        uint32 twapWindow
    ) internal view returns (uint256 spotPrice, uint256 twapPrice) {
        spotPrice = getSpotPrice(oracle);
        twapPrice = getTWAPPrice(oracle, twapWindow);
    }
    
    /// @notice Alternative: Get spot price directly from pool using oracle's computed TVL
    /// @param oracle Address of the Balancer WeightedLPOracle contract
    /// @return price Price in normalized format (token1 per token0)
    /// @dev This is an alternative method if getLatest() doesn't work as expected
    /// @dev Computes price from oracle TVL and pool balances
    /// @dev Currently not implemented - placeholder for future development
    /// @dev pool, token0Address, and token1Address parameters reserved for future use
    function getSpotPriceFromTVL(
        address oracle,
        address /* pool */,
        address /* token0Address */,
        address /* token1Address */
    ) internal view returns (uint256 price) {
        // Get TVL from oracle
        // uint256 tvl = IWeightedLPOracle(oracle).getLatest();
        
        // Get pool balances (this would require IVault interface)
        // For now, this is a placeholder - actual implementation would need:
        // 1. IVault to get balances
        // 2. IWeightedPool to get weights
        // 3. Compute price from TVL, balances, and weights
        
        // Placeholder - implement based on actual pool interface
        revert("BalancerPriceHelper: getSpotPriceFromTVL not yet implemented");
    }
}

