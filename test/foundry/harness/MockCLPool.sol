// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Foundry-only stand-in for a Uniswap-V3-style CL pool: just enough surface
///         (slot0, observe, positions, token0/1/fee/tickSpacing) for StratusCLVaultBase's
///         read-only valuation/preview math to run under fuzzing, with no real swap/mint
///         mechanics. TWAP is synthesized to exactly equal a settable `twapTick`, decoupled
///         from spot (`slot0Tick`/`sqrtPriceX96`) so tests can fuzz spot-vs-TWAP divergence.
contract MockCLPool {
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;

    uint160 public sqrtPriceX96;
    int24 public slot0Tick;
    int24 public twapTick;

    struct Position {
        uint128 liquidity;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }
    mapping(bytes32 => Position) public positionsByKey;

    constructor(address _token0, address _token1, uint24 _fee, int24 _tickSpacing) {
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        tickSpacing = _tickSpacing;
    }

    function setSlot0(uint160 _sqrtPriceX96, int24 _tick) external {
        sqrtPriceX96 = _sqrtPriceX96;
        slot0Tick = _tick;
    }

    function setTwapTick(int24 _twapTick) external {
        twapTick = _twapTick;
    }

    function setPosition(int24 lower, int24 upper, uint128 liquidity, uint128 owed0, uint128 owed1) external {
        positionsByKey[positionKey(lower, upper)] = Position(liquidity, owed0, owed1);
    }

    function positionKey(int24 lower, int24 upper) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(lower, upper));
    }

    function slot0()
        external
        view
        returns (uint160, int24, uint16, uint16, uint16, uint8, bool)
    {
        return (sqrtPriceX96, slot0Tick, 0, 0, 0, 0, true);
    }

    /// @dev Synthesizes tickCumulatives so (cum[1]-cum[0])/window == twapTick exactly,
    ///      matching UniswapV3PriceHelper.getTWAPTick's arithmetic-mean computation.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
        // secondsAgos = [window, 0] by convention in UniswapV3PriceHelper.getTWAPTick.
        uint32 window = secondsAgos[0];
        tickCumulatives[0] = 0;
        tickCumulatives[1] = int56(int256(twapTick) * int256(uint256(window)));
    }

    function positions(bytes32 key)
        external
        view
        returns (uint128 liquidity, uint256, uint256, uint128 tokensOwed0, uint128 tokensOwed1)
    {
        Position memory p = positionsByKey[key];
        return (p.liquidity, 0, 0, p.tokensOwed0, p.tokensOwed1);
    }
}
