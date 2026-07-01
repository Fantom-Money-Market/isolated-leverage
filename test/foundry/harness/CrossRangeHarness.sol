// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../../../contracts/Stratus-ALM/base/StratusCLVaultBase.sol";
import "./MockCLPool.sol";

/// @notice Foundry-only harness exposing StratusCLVaultBase's bespoke cross-range allocation
///         and swap-quote math for fuzzing, wired to a MockCLPool instead of a real venue.
///         _clMint/_clBurn/_clCollect are never exercised by the fuzz suite (it only reads
///         previewRebalance()/_quoteSwap — no minting), so they revert defensively.
contract CrossRangeHarness is StratusCLVaultBase {
    MockCLPool public immutable mockPool;

    constructor(address _factory, address _pool, uint256 _upwardBias, uint8 _protocolFee)
        StratusCLVaultBase(_factory, _pool, _upwardBias, _protocolFee, "Harness", "HNS")
    {
        mockPool = MockCLPool(_pool);
    }

    /// @notice Re-center the 3 weighted ranges around `tick`, exactly as rebalance() would.
    function exposeSetRanges(int24 tick) external {
        _setRanges(tick);
    }

    /// @notice Thin pure passthrough to the internal balancing-swap quote.
    function exposeQuoteSwap(uint256 surplusBal, uint256 deficitBal, uint256 needDeficit, uint256 priceSurplusInDeficit)
        external
        pure
        returns (uint256 surplusOut, uint256 deficitIn)
    {
        return _quoteSwap(surplusBal, deficitBal, needDeficit, priceSurplusInDeficit);
    }

    /// @notice Thin view passthrough to the per-range token-amount request.
    function exposeReqAtRange(int24 lower, int24 upper, uint160 sqrtP, uint256 w)
        external
        view
        returns (uint256 r0, uint256 r1)
    {
        return _reqAtRange(lower, upper, sqrtP, w);
    }

    function _clPosition(int24 tickLower, int24 tickUpper)
        internal
        view
        override
        returns (uint128 liquidity, uint128 tokensOwed0, uint128 tokensOwed1)
    {
        return mockPool.positionsByKey(mockPool.positionKey(tickLower, tickUpper));
    }

    function _clMint(int24, int24, uint128) internal pure override returns (uint256, uint256) {
        revert("CrossRangeHarness: mint unused in fuzz suite");
    }

    function _clBurn(int24, int24, uint128) internal pure override returns (uint256, uint256) {
        revert("CrossRangeHarness: burn unused in fuzz suite");
    }

    function _clCollect(int24, int24, address, uint128, uint128) internal pure override returns (uint256, uint256) {
        revert("CrossRangeHarness: collect unused in fuzz suite");
    }
}
