// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IRamsesV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    function slot0() external view returns (
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
    function period() external view returns (uint32);
    function periods(uint32 period) external view returns (uint32 startTimestamp, uint32 endTimestamp);
    function _advancePeriod() external;
    function positionPeriodSecondsInRange(
        uint256 tokenId,
        uint32 period
    ) external view returns (uint256 secondsInRange);
}
