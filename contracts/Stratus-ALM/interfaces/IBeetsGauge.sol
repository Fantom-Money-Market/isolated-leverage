// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal Curve-style Child Liquidity Gauge on Beets/Balancer (Vyper).
interface IBeetsGauge {
    function lp_token() external view returns (address);
    function deposit(uint256 value, address user) external;
    function withdraw(uint256 value, address user) external;
    function claim_rewards(address addr, address receiver, uint256[] calldata reward_indexes) external;
    function claimable_reward(address user, address reward_token) external view returns (uint256);
    function reward_count() external view returns (uint256);
    function reward_tokens(uint256 index) external view returns (address);
}
