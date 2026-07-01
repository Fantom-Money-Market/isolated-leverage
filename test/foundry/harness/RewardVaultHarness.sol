// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../../../contracts/Stratus-ALM/base/StratusVaultBase.sol";
import "../../../contracts/Stratus-ALM/test/MockERC20.sol";

/// @notice Foundry-only harness exercising StratusVaultBase's share accounting + reward
///         accumulator with a trivial 1:1 valuation (no AMM/CL positions needed) — isolates
///         the reward-per-share math (the live-incident bug class) from venue mechanics.
///         Deposits sit as idle balance 1:1; withdraw returns idle balance proportionally.
contract RewardVaultHarness is StratusVaultBase {
    constructor(address _factory, address _token0, address _token1)
        StratusVaultBase(_factory, _token0, _token1, 100, 5, "Harness", "HNS")
    {}

    /// @notice Mint `net` of `token` to this contract and credit it through the accumulator,
    ///         exactly like a real adapter's harvest path (tokens land first, then distribute).
    function harvest(address token, uint256 net) external {
        if (net > 0) MockERC20(token).mint(address(this), net);
        _distributeReward(token, net);
    }

    function _safeValuation() internal view override returns (uint256 total0, uint256 total1, uint256 price) {
        total0 = token0.balanceOf(address(this));
        total1 = token1.balanceOf(address(this));
        price = PRECISION; // 1:1, no AMM in this harness
    }

    function _totalAmountsSpot() internal view override returns (uint256 total0, uint256 total1) {
        return (token0.balanceOf(address(this)), token1.balanceOf(address(this)));
    }

    function _spotPrice() internal pure override returns (uint256) {
        return PRECISION;
    }

    function _realizeFees() internal override {}

    function _withdrawPositions(uint256, uint256, address) internal pure override returns (uint256, uint256) {
        return (0, 0); // everything is idle balance in this harness; base sweeps it proportionally
    }

    function deployIdle() external pure override {}
}
