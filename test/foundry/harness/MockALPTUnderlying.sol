// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../../../contracts/Stratus-ALM/test/MockERC20.sol";

/// @notice Foundry-only stand-in for the ALPT `underlying` Collateral.sol holds: a plain
///         mintable ERC20 (so mint()/redeem()'s balance-diff bookkeeping works) plus a
///         controllable pricing surface (getPrices() reads totalSupply/getTotalValueSafe/
///         twapPrice) and a controllable reward surface (harvestVaultRewards reads
///         rewardTokensList/claimRewards). Values are directly settable rather than derived
///         from real AMM math, so invariant/fuzz tests can drive exact scenarios.
contract MockALPTUnderlying is MockERC20 {
    uint256 public totalValueSafe;
    uint256 public twapPriceValue = 1e18; // 1:1 by default, keeps getPrices() well-defined
    address[] public rewardTokensStored;
    uint256 public rewardPerClaim;
    MockERC20 public rewardToken;

    constructor(string memory n, string memory s, address _rewardToken) MockERC20(n, s) {
        rewardToken = MockERC20(_rewardToken);
        rewardTokensStored.push(_rewardToken);
    }

    function setTotalValueSafe(uint256 v) external {
        totalValueSafe = v;
    }

    function setTwapPrice(uint256 p) external {
        twapPriceValue = p;
    }

    function setRewardPerClaim(uint256 r) external {
        rewardPerClaim = r;
    }

    function getTotalValueSafe() external view returns (uint256) {
        return totalValueSafe;
    }

    function twapPrice() external view returns (uint256) {
        return twapPriceValue;
    }

    function rewardTokensList() external view returns (address[] memory) {
        return rewardTokensStored;
    }

    /// @dev Mints a fixed, known amount of the reward token to the caller (Collateral),
    ///      mirroring MockGauge's determinism — no dependence on real emission timing.
    function claimRewards() external {
        if (rewardPerClaim > 0) rewardToken.mint(msg.sender, rewardPerClaim);
    }
}
