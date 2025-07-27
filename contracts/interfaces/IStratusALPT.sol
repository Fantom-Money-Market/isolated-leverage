// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IStratusALPT {
    // --- Structs ---

    struct Position {
        uint256 tokenId;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 percentage;
        uint256 feeToken0;
        uint256 feeToken1;
        uint256 lastKnownRatio;
    }

    struct Checkpoint {
        uint256 timestamp;
        uint256 feeToken0;
        uint256 feeToken1;
    }

    // --- Events ---

    event PositionCreated(uint256 indexed tokenId, int24 tickLower, int24 tickUpper, uint256 liquidity);
    event PositionIncreased(uint256 indexed tokenId, uint128 liquidityAdded);
    event PositionDecreased(uint256 indexed tokenId, uint128 liquidityRemoved);
    event FeesCollected(uint256 indexed tokenId, uint256 amount0, uint256 amount1);
    event ProtocolFeesPaid(uint256 amount0, uint256 amount1);
    event Deposit(address indexed user, uint256 amount0, uint256 amount1, uint256 shares);
    event Withdraw(address indexed user, uint256 shares, uint256 amount0, uint256 amount1);
    event RatioUpdated(uint256 indexed tokenId, uint256 newRatio);

    // --- View Functions ---

    function pool() external view returns (address);
    function positionManager() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function factory() external view returns (address);
    function swapRouter() external view returns (address);
    function rangeWidths(uint256 index) external view returns (int24);
    function rangeWeights(uint256 index) external view returns (uint256);
    function upwardBias() external view returns (uint256);
    function positions(uint256 index) external view returns (Position memory);
    function feeCheckpoints(uint256 index) external view returns (Checkpoint memory);
    function userCheckpoint(address user) external view returns (uint256);
    function getOptimalDepositAmounts(uint256 amount0Desired, uint256 amount1Desired) external view returns (uint256 optimal0, uint256 optimal1);
    function getAsymmetricRanges(int24 currentTick) external view returns (int24[] memory tickLowers, int24[] memory tickUppers);
    function getPositionAmounts(Position memory position) external view returns (uint256 amount0, uint256 amount1);
    function calculateShares(uint256 amount0, uint256 amount1) external view returns (uint256);
    function getTotalAmounts() external view returns (uint256 total0, uint256 total1);
    function getFeesAPR(uint256 timeframe) external view returns (uint256 apr);
    function getTotalValueInToken1() external view returns (uint256 totalValue);
    function getTotalFeesInToken1(uint256 timeframe) external view returns (uint256 totalFees);
    function previewDeposit(uint256 amount0Desired, uint256 amount1Desired) external view returns (uint256 shares, uint256[] memory amount0PerRange, uint256[] memory amount1PerRange);
    function previewWithdraw(uint256 shares) external view returns (uint256 amount0Total, uint256 amount1Total, uint256[] memory amount0PerRange, uint256[] memory amount1PerRange);
    function getCurrentRangeStatuses() external view returns (bool[] memory isInRange, uint256[] memory utilizations);
    function getWeightedAverageRatio() external view returns (uint256);
    function getPositionRatios() external view returns (uint256[] memory ratios);

    // --- State-Changing Functions ---

    function deposit(uint256 amount0Desired, uint256 amount1Desired, uint256 amount0Min, uint256 amount1Min) external returns (uint256 shares);
    function withdraw(uint256 shares, uint256 amount0Min, uint256 amount1Min) external;
    function collectAllFees() external returns (uint256 amount0Total, uint256 amount1Total);
    function updateRangeRatios() external;

    // --- ERC20 Functions ---
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}