// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

interface IGaugeV3 {
    // Events
    event NotifyReward(address indexed from, address indexed reward, uint256 indexed amount, uint256 period);
    event ClaimRewards(uint256 indexed period, bytes32 indexed positionHash, address indexed to, address token, uint256 amount);
    event RewardAdded(address indexed reward);
    event RewardRemoved(address indexed reward);

    // View functions
    function pool() external view returns (address);
    function voter() external view returns (address);
    function feeCollector() external view returns (address);
    function nfpManager() external view returns (address);
    function firstPeriod() external view returns (uint256);
    function getRewardTokens() external view returns (address[] memory);
    function positionHash(address owner, uint256 index, int24 tickLower, int24 tickUpper) external pure returns (bytes32);
    function earned(address token, uint256 tokenId) external view returns (uint256 reward);
    function periodEarned(uint256 period, address token, uint256 tokenId) external view returns (uint256);
    function periodEarned(uint256 period, address token, address owner, uint256 index, int24 tickLower, int24 tickUpper) external view returns (uint256 amount);
    function left(address token) external view returns (uint256);
    function rewardRate(address token) external view returns (uint256);
    function tokenTotalSupplyByPeriod(uint256 period, address token) external view returns (uint256);
    function periodClaimedAmount(uint256 period, bytes32 positionHash, address token) external view returns (uint256);
    function lastClaimByToken(address token, bytes32 positionHash) external view returns (uint256);
    function isReward(address token) external view returns (bool);
    function rewards(uint256 index) external view returns (address);

    // Reward notification functions
    function notifyRewardAmount(address token, uint256 amount) external;
    function notifyRewardAmountNextPeriod(address token, uint256 amount) external;
    function notifyRewardAmountForPeriod(address token, uint256 amount, uint256 period) external;

    // Reward claiming functions
    function getReward(uint256[] calldata tokenIds, address[] memory tokens) external;
    function getReward(uint256 tokenId, address[] memory tokens) external;
    function getRewardForOwner(uint256 tokenId, address[] memory tokens) external;
    function getReward(address owner, uint256 index, int24 tickLower, int24 tickUpper, address[] memory tokens, address receiver) external;
    function getPeriodReward(uint256 period, address[] calldata tokens, uint256 tokenId, address receiver) external;
    function getPeriodReward(uint256 period, address[] calldata tokens, address owner, uint256 index, int24 tickLower, int24 tickUpper, address receiver) external;
    function cachePeriodEarned(uint256 period, address token, address owner, uint256 index, int24 tickLower, int24 tickUpper, bool caching) external returns (uint256 amount);

    // Reward management functions
    function addRewards(address reward) external;
    function removeRewards(address reward) external;
}
