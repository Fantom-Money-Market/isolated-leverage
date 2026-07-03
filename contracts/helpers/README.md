# Price Helper Libraries

AMM-agnostic price retrieval, abstracting how to query prices from different pool types.

## Key Insight

**Different venues expose manipulation-resistant value differently:**

- **Uniswap V3 (and forks: Shadow, Thick)**: Pools themselves are oracles — `slot0()` for spot and `observe()` for TWAP. No separate oracle contract needed. Handled by `UniswapV3PriceHelper`.
- **Balancer / Beets v3**: Value is sourced from each token's on-chain rate provider (e.g. `stS.getRate()`), read directly inside `StratusBeetsV3Adapter` — a swap that skews reserves conserves the rate-weighted sum, so there is no tick to push. This is why there is no separate Balancer price-helper library: the adapter is the price surface.

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

## How collateral pricing consumes this

`Collateral.getPrices()` never calls these helpers directly. It reads the underlying's
venue-uniform safe surface (`getTotalValueSafe()` / `twapPrice()` on `IStratusALPT`), and
each vault implements that surface with the appropriate source: CL vaults via
`UniswapV3PriceHelper` TWAP, the Beets adapter via rate providers. That keeps the lending
layer venue-agnostic and manipulation-resistant with no per-AMM branching in Collateral.
