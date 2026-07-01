# Price Helper Libraries

These libraries provide AMM-agnostic price retrieval by abstracting how to query prices from different pool types.

## Key Insight

**Different AMMs handle oracles differently:**

- **Uniswap V3**: Pools themselves are oracles! They expose `slot0()` for spot price and `observe()` for TWAP. No separate oracle contract needed.
- **Balancer**: Uses a separate `WeightedLPOracle` contract that uses Chainlink feeds to compute prices. The oracle contract must be deployed separately.

## Libraries

### `UniswapV3PriceHelper.sol`

Helper library for Uniswap V3 (and V3-compatible) pools.

**Functions**:
- `getSpotPrice(address pool)` - Get current spot price from pool
- `getTWAPPrice(address pool, uint32 twapWindow)` - Get TWAP price using pool.observe()
- `tickToPrice(int24 tick)` - Convert tick to price using TickMath library
- `getPrices(address pool, uint32 twapWindow)` - Get both spot and TWAP prices

**Usage**:
```solidity
import "./helpers/UniswapV3PriceHelper.sol";

uint256 spotPrice = UniswapV3PriceHelper.getSpotPrice(poolAddress);
uint256 twapPrice = UniswapV3PriceHelper.getTWAPPrice(poolAddress, 30 minutes);
```

### `BalancerPriceHelper.sol`

Helper library for Balancer pools using WeightedLPOracle.

**Functions**:
- `getSpotPrice(address oracle)` - Get current spot price from Balancer WeightedLPOracle
- `getTWAPPrice(address oracle, uint32 twapWindow)` - Get TWAP price (falls back to spot if TWAP unavailable)
- `getPrices(address oracle, uint32 twapWindow)` - Get both spot and TWAP prices

**Usage**:
```solidity
import "./helpers/BalancerPriceHelper.sol";

// Note: oracle is the address of the WeightedLPOracle contract, not the pool itself
address balancerOracle = 0x...; // Address of deployed WeightedLPOracle

uint256 spotPrice = BalancerPriceHelper.getSpotPrice(balancerOracle);
uint256 twapPrice = BalancerPriceHelper.getTWAPPrice(balancerOracle, 30 minutes);
```

**Important**: Balancer uses a separate oracle contract (`WeightedLPOracle`) that must be deployed with Chainlink feeds. The oracle is NOT the pool itself - you need the oracle contract address.

## Integration Example

```solidity
// contracts/Collateral.sol
import "./helpers/UniswapV3PriceHelper.sol";
import "./helpers/BalancerPriceHelper.sol";

function getPrices() public view returns (uint256 price0, uint256 price1) {
    address poolAddress = IStratusALPT(underlying).pool();
    bytes32 ammType = IStratusALPT(underlying).ammType();
    
    uint256 twapPrice;
    uint256 spotPrice;
    
    if (ammType == keccak256("UNISWAP_V3")) {
        // V3 pools ARE oracles - use pool address directly
        twapPrice = UniswapV3PriceHelper.getTWAPPrice(poolAddress, 30 minutes);
        spotPrice = UniswapV3PriceHelper.getSpotPrice(poolAddress);
    } else if (ammType == keccak256("BALANCER")) {
        // Balancer uses separate oracle contract - need oracle address, not pool address
        address balancerOracle = IStratusALPT(underlying).oracle(); // Or however you store it
        twapPrice = BalancerPriceHelper.getTWAPPrice(balancerOracle, 30 minutes);
        spotPrice = BalancerPriceHelper.getSpotPrice(balancerOracle);
    }
    
    // ... rest of price adjustment logic ...
}
```

## Benefits

✅ **No separate oracle contracts** - Pools are oracles themselves
✅ **Simple wrappers** - ~2 hours each to implement
✅ **Gas efficient** - Direct pool queries, no extra infrastructure
✅ **Flexible** - Easy to add more AMM types (just add a new helper library)

