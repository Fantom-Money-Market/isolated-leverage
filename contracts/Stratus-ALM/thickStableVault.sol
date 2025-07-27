// SPDX-License-Identifier: none
pragma solidity ^0.8.24;
pragma abicoder v2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./libraries/TickMath.sol";
import "./libraries/LiquidityAmounts.sol"; 
import './interfaces/IUniswapV3Pool.sol';
import './interfaces/INonfungiblePositionManager.sol';
import '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';

/// @title ThickLiquidityVault
/// @notice Automated liquidity management using overlapping positions on Thickv2 (Equalizer) fork

contract ThickStableVault is ERC20, ReentrancyGuard { 
    using SafeERC20 for IERC20;

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

    // Custom Errors
    error ZeroAddress();
    error AllocationSumNotHundred();
    error RangeLengthMismatch();
    error CooldownActive();
    error InsufficientToken0();
    error InsufficientToken1();
    error ZeroShares();
    error InvalidShares();
    error LowOutput0();
    error LowOutput1();
    error PositionNotFound();
    error InvalidRange();
    error SlippageExceeded();
    error InvalidTimeframe();
    error Unauthorized();

    // Immutable contract references
    INonfungiblePositionManager public immutable positionManager;
    IUniswapV3Pool public immutable pool;
    IERC20 public immutable token0;
    IERC20 public immutable token1;
    ISwapRouter public swapRouter;
    
    // Position configuration
    Position[] public positions;
    int24[3] public rangeWidths = [
       int24 (1),    // Finest granularity: narrow range
       int24 (8),    // Medium granularity: medium range
       int24(64)    // Coarse granularity: wide range
    ];
    uint256[] public allocations = [
        50,   // 50% in narrow range
        30,   // 30% in medium range
        20    // 20% in wide range
    ];

    // Flash loan protection - 1 minute cooldown
    uint256 private constant MINIMUM_DEPOSIT_PERIOD = 10 seconds;
    mapping(address => uint256) private lastDepositTime;

    uint256 constant PRICE_PRECISION = 1e18; 
    uint256 public constant RATIO_MULTIPLIER = 1e18;
    uint256 private constant BASIS_POINTS = 10000;
    uint16 public constant COMPOUND_BOUNTY = 50; // 0.5% bounty (50 / 10000)

    
    uint8 public immutable protocolFee;
    address public immutable factory;

    // Events
    event PositionCreated(uint256 indexed tokenId, int24 tickLower, int24 tickUpper, uint256 liquidity);
    event PositionIncreased(uint256 indexed tokenId, uint128 liquidityAdded);
    event PositionDecreased(uint256 indexed tokenId, uint128 liquidityRemoved);
    event FeesCollected(uint256 indexed tokenId, uint256 amount0, uint256 amount1);
    event Deposit(address indexed user, uint256 amount0, uint256 amount1, uint256 shares);
    event Withdraw(address indexed user, uint256 shares, uint256 amount0, uint256 amount1);
    event RatioUpdated(uint256 indexed tokenId, uint256 newRatio);
    event PositionRebalanced(uint256 indexed oldTokenId, uint256 indexed newTokenId, int24 newTickLower, int24 newTickUpper);

    // For automatic re-ranging of the tightest position
    uint256 public tightestPositionOutOfRangeSince;
 
    constructor(
        address _pool,
        address _positionManager,
        address _swapRouter,
        string memory _name,
        string memory _symbol,
        uint8 _protocolFee
    ) ERC20(_name, _symbol) {
        if (_pool == address(0)) revert ZeroAddress();
        if (_positionManager == address(0)) revert ZeroAddress();

        pool = IUniswapV3Pool(_pool);
        positionManager = INonfungiblePositionManager(_positionManager);
        token0 = IERC20(pool.token0());
        token1 = IERC20(pool.token1());

        // Validate allocation percentages
        if (rangeWidths.length != allocations.length) revert RangeLengthMismatch();
        
        uint256 totalAllocation;
        for (uint256 i = 0; i < allocations.length; i++) {
            totalAllocation += allocations[i];
        }
        if (totalAllocation != 100) revert AllocationSumNotHundred();

        protocolFee = _protocolFee;
        factory = msg.sender;
        swapRouter = ISwapRouter(_swapRouter) ;
    }

    /// @notice Deposit tokens and receive vault shares
    function deposit(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) external nonReentrant returns (uint256 shares) {
        if (totalSupply() == 0 && msg.sender != factory) revert Unauthorized();

        if (lastDepositTime[msg.sender] != 0) {
            if (block.timestamp < lastDepositTime[msg.sender] + MINIMUM_DEPOSIT_PERIOD) {
                revert CooldownActive();
            }
        }
        lastDepositTime[msg.sender] = block.timestamp;

        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));
        
        token0.safeTransferFrom(msg.sender, address(this), amount0Desired);
        token1.safeTransferFrom(msg.sender, address(this), amount1Desired);
        
        if (token0.balanceOf(address(this)) - balance0Before < amount0Min) revert InsufficientToken0();
        if (token1.balanceOf(address(this)) - balance1Before < amount1Min) revert InsufficientToken1();

        // Update range ratios before deposit
        updateRangeRatios();
        
        shares = calculateShares(amount0Desired, amount1Desired);
        if (shares == 0) revert ZeroShares();
        
        _mint(msg.sender, shares);

        if (positions.length == 0) {
            _createInitialPositions(amount0Desired, amount1Desired, amount0Min, amount1Min);
        } else {
            _addToExistingPositions(amount0Desired, amount1Desired, amount0Min, amount1Min);
        }

        emit Deposit(msg.sender, amount0Desired, amount1Desired, shares);
    }

    /// @notice Withdraw tokens by burning vault shares
    function withdraw(
        uint256 shares,
        uint256 amount0Min,
        uint256 amount1Min
    ) external nonReentrant {
        if (shares == 0 || shares > balanceOf(msg.sender)) revert InvalidShares();
        
        uint256 totalShares = totalSupply();
        _burn(msg.sender, shares);

        uint256 amount0Total;
        uint256 amount1Total;

        for (uint256 i = 0; i < positions.length; i++) {
            Position storage position = positions[i];
            
            uint128 liquidityToWithdraw = uint128((uint256(position.liquidity) * shares) / totalShares);
            if (liquidityToWithdraw > 0) {
                (uint256 amount0, uint256 amount1) = _decreasePosition(position.tokenId, liquidityToWithdraw);
                
                amount0Total += amount0;
                amount1Total += amount1;
                position.liquidity -= liquidityToWithdraw;
            }
        }

        if (amount0Total < amount0Min) revert LowOutput0();
        if (amount1Total < amount1Min) revert LowOutput1();
        
        if (amount0Total > 0) token0.safeTransfer(msg.sender, amount0Total);
        if (amount1Total > 0) token1.safeTransfer(msg.sender, amount1Total);

        emit Withdraw(msg.sender, shares, amount0Total, amount1Total);
    }

    function _createInitialPositions(
        uint256 amount0Total,
        uint256 amount1Total,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        int24 currentTick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        for (uint256 i = 0; i < rangeWidths.length; i++) {
            int24 spacing = rangeWidths[i];
            int24 tickRange = spacing * 100;
            
            int24 tickLower = currentTick - tickRange;
            int24 tickUpper = currentTick + tickRange;
            
            tickLower = tickLower - (tickLower % spacing);
            tickUpper = tickUpper - (tickUpper % spacing);
            
            if (tickLower >= tickUpper) revert InvalidRange();

            uint256 amount0 = (amount0Total * allocations[i]) / 100;
            uint256 amount1 = (amount1Total * allocations[i]) / 100;
            uint256 minAmount0 = (amount0Min * allocations[i]) / 100;
            uint256 minAmount1 = (amount1Min * allocations[i]) / 100;
            
            _createPosition(tickLower, tickUpper, amount0, amount1, minAmount0, minAmount1);
        }
    }

     function _createPosition(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal returns (uint256) {
        token0.approve(address(positionManager), amount0Desired);
        token1.approve(address(positionManager), amount1Desired);
        
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(token0),
                token1: address(token1),
                fee: 10000, // Fixed 1% fee for Thick
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                recipient: address(this),
                deadline: block.timestamp
            })
        );

        if (amount0 < amount0Min || amount1 < amount1Min) revert SlippageExceeded();

        positions.push(Position({
            tokenId: tokenId,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            percentage: 0,
            feeToken0: 0,
            feeToken1: 0,
            lastKnownRatio: RATIO_MULTIPLIER
        }));

        emit PositionCreated(tokenId, tickLower, tickUpper, liquidity);
    }

    function _addToExistingPositions(
        uint256 amount0Total,
        uint256 amount1Total,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal {
        for (uint256 i = 0; i < positions.length; i++) {
            Position storage position = positions[i];
            uint256 amount0 = (amount0Total * allocations[i]) / 100;
            uint256 amount1 = (amount1Total * allocations[i]) / 100;
            uint256 minAmount0 = (amount0Min * allocations[i]) / 100;
            uint256 minAmount1 = (amount1Min * allocations[i]) / 100;

            token0.approve(address(positionManager), amount0);
            token1.approve(address(positionManager), amount1);

            (uint128 liquidityAdded, uint256 amount0Added, uint256 amount1Added) = 
                positionManager.increaseLiquidity(
                    INonfungiblePositionManager.IncreaseLiquidityParams({
                        tokenId: position.tokenId,
                        amount0Desired: amount0,
                        amount1Desired: amount1,
                        amount0Min: minAmount0,
                        amount1Min: minAmount1,
                        deadline: block.timestamp
                    })
                );

            if (amount0Added < minAmount0 || amount1Added < minAmount1) revert SlippageExceeded();

            position.liquidity += liquidityAdded;
            emit PositionIncreased(position.tokenId, liquidityAdded);
        }
    }

    function _decreasePosition(
        uint256 tokenId,
        uint128 liquidityToRemove
    ) internal returns (uint256 amount0, uint256 amount1) {
        if (liquidityToRemove > 0) {
            // Calculate minimum amounts based on current price with 1% slippage tolerance
            (uint256 expectedAmount0, uint256 expectedAmount1) = getPositionAmounts(
                Position({
                    tokenId: tokenId,
                    tickLower: positions[0].tickLower,
                    tickUpper: positions[0].tickUpper,
                    liquidity: liquidityToRemove,
                    percentage: 0,
                    feeToken0: 0,
                    feeToken1: 0,
                    lastKnownRatio: RATIO_MULTIPLIER
                })
            );
            
            uint256 amount0Min = expectedAmount0 * 99 / 100; // 1% slippage
            uint256 amount1Min = expectedAmount1 * 99 / 100; // 1% slippage

            (amount0, amount1) = positionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liquidityToRemove,
                    amount0Min: amount0Min,
                    amount1Min: amount1Min,
                    deadline: block.timestamp
                })
            );

            (uint256 collected0, uint256 collected1) = positionManager.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );

            amount0 += collected0;
            amount1 += collected1;
            
            emit PositionDecreased(tokenId, liquidityToRemove);
        }
    }

    /// @notice Collects all pending fees and reinvests them, increasing the value of vault shares.
    /// @dev This function can be called by anyone to trigger compounding for all vault holders.
    function compound() external nonReentrant returns (uint256 compounded0, uint256 compounded1) {
        uint256 totalCollected0;
        uint256 totalCollected1;

        // --- 1. Collect fees from all positions --- 
        for (uint256 i = 0; i < positions.length; i++) {
            Position storage position = positions[i];
            
            // Reading pending fees from the position manager
            (, , , , , , , , , , uint128 fee0, uint128 fee1) = positionManager.positions(position.tokenId);
            
            if (fee0 > 0 || fee1 > 0) {
                // Pulling fees from Uniswap into this contract
                (uint256 collected0, uint256 collected1) = positionManager.collect(
                    INonfungiblePositionManager.CollectParams({
                        tokenId: position.tokenId,
                        recipient: address(this),
                        amount0Max: fee0,
                        amount1Max: fee1
                    })
                );
                totalCollected0 += collected0;
                totalCollected1 += collected1;
            }
        }

        if (totalCollected0 == 0 && totalCollected1 == 0) {
            return (0, 0); // No fees to compound
        }

        // --- 2. Pay compounder bounty --- 
        uint256 bounty0 = (totalCollected0 * COMPOUND_BOUNTY) / BASIS_POINTS;
        uint256 bounty1 = (totalCollected1 * COMPOUND_BOUNTY) / BASIS_POINTS;

        if (bounty0 > 0) token0.safeTransfer(msg.sender, bounty0);
        if (bounty1 > 0) token1.safeTransfer(msg.sender, bounty1);

        // --- 3. Pay protocol fees on the remainder ---
        uint256 remaining0 = totalCollected0 - bounty0;
        uint256 remaining1 = totalCollected1 - bounty1;

        uint256 protocolFee0 = (remaining0 * protocolFee) / 100;
        uint256 protocolFee1 = (remaining1 * protocolFee) / 100;

        if (protocolFee0 > 0) token0.safeTransfer(factory, protocolFee0);
        if (protocolFee1 > 0) token1.safeTransfer(factory, protocolFee1);

        compounded0 = remaining0 - protocolFee0;
        compounded1 = remaining1 - protocolFee1;

        // --- 3. Reinvest the remaining fees --- 
        _addToExistingPositions(compounded0, compounded1, 0, 0); // Assuming 0 minimums for simplicity, consider adding slippage protection

        // We can use the Deposit event here to signify reinvestment
        emit Deposit(msg.sender, compounded0, compounded1, 0);
    }

     function calculateShares(uint256 amount0, uint256 amount1) public view returns (uint256) {
        uint256 totalSupply = totalSupply();
        if (totalSupply == 0) {
            return Math.sqrt(amount0 * amount1);
        }
        
        (uint256 total0, uint256 total1) = getTotalAmounts();
        if (total0 == 0 || total1 == 0) revert InvalidRange();
        
        return Math.min(
            (amount0 * totalSupply) / total0,
            (amount1 * totalSupply) / total1
        );
    }

    function getTotalAmounts() public view returns (uint256 total0, uint256 total1) {
        
        for (uint256 i = 0; i < positions.length; i++) {
            Position memory position = positions[i];
            (uint256 amount0, uint256 amount1) = getPositionAmounts(position);
            total0 += amount0;
            total1 += amount1;
        }
    }

    function getPriceRanges() external view returns (
        uint256[] memory lowerPrices,
        uint256[] memory upperPrices,
        bool[] memory isActive
    ) {
        lowerPrices = new uint256[](positions.length);
        upperPrices = new uint256[](positions.length);
        isActive = new bool[](positions.length);
        
        (uint160 currentSqrtPriceX96,,,,,,) = pool.slot0();
        uint256 currentPrice = uint256(currentSqrtPriceX96) * uint256(currentSqrtPriceX96) * 1e18 >> (96 * 2);
        
        for (uint256 i = 0; i < positions.length; i++) {
            Position memory position = positions[i];
            uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(position.tickLower);
            uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(position.tickUpper);
            
            lowerPrices[i] = uint256(sqrtRatioAX96) * uint256(sqrtRatioAX96) * 1e18 >> (96 * 2);
            upperPrices[i] = uint256(sqrtRatioBX96) * uint256(sqrtRatioBX96) * 1e18 >> (96 * 2);
            isActive[i] = currentPrice >= lowerPrices[i] && currentPrice <= upperPrices[i];
        }
    }

    function getPositionAmounts(Position memory position) public view returns (uint256 amount0, uint256 amount1) {
        if (position.liquidity == 0) return (0, 0);
        
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(position.tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(position.tickUpper);
        
        return LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            position.liquidity
        );
    }

    function getFeesAPR(uint256 timeframe) external view returns (uint256 apr) {
        if (timeframe == 0) revert InvalidTimeframe();
        
        uint256 totalValue = getTotalValueInToken1();
        if (totalValue == 0) return 0;
        
        uint256 feesEarned = getTotalFeesInToken1(timeframe);
        apr = (feesEarned * 365 days * 100) / (timeframe * totalValue);
    }

    function getTotalValueInToken1() public view returns (uint256 totalValue) {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint256 price = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18 >> (96 * 2);
        
        (uint256 total0, uint256 total1) = getTotalAmounts();
        return (total0 * price) / 1e18 + total1;
    }

    function getTotalFeesInToken1(uint256 timeframe) public view returns (uint256 totalFees) {
        if (timeframe == 0) revert InvalidTimeframe();
        
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint256 price = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18 >> (96 * 2);
        
        uint256 totalFeeToken0;
        uint256 totalFeeToken1;
        for (uint256 i = 0; i < positions.length; i++) {
            Position memory position = positions[i];
            totalFeeToken0 += position.feeToken0;
            totalFeeToken1 += position.feeToken1;
        }
        
        // Convert all fees to token1 value
        return (totalFeeToken0 * price / 1e18) + totalFeeToken1;
    }

    function previewDeposit(
        uint256 amount0Desired,
        uint256 amount1Desired
    ) external view returns (
        uint256 shares,
        uint256[] memory amount0PerRange,
        uint256[] memory amount1PerRange
    ) {
        shares = calculateShares(amount0Desired, amount1Desired);
        
        amount0PerRange = new uint256[](allocations.length);
        amount1PerRange = new uint256[](allocations.length);
        
        for (uint256 i = 0; i < allocations.length; i++) {
            amount0PerRange[i] = (amount0Desired * allocations[i]) / 100;
            amount1PerRange[i] = (amount1Desired * allocations[i]) / 100;
        }
    }

    function previewWithdraw(uint256 shares) external view returns (
        uint256 amount0Total,
        uint256 amount1Total,
        uint256[] memory amount0PerRange,
        uint256[] memory amount1PerRange
    ) {
        uint256 totalShares = totalSupply();
        if (totalShares == 0) return (0, 0, new uint256[](0), new uint256[](0));
        
        amount0PerRange = new uint256[](positions.length);
        amount1PerRange = new uint256[](positions.length);
        
        for (uint256 i = 0; i < positions.length; i++) {
            Position memory position = positions[i];
            uint128 liquidityToWithdraw = uint128((uint256(position.liquidity) * shares) / totalShares);
            
            if (liquidityToWithdraw > 0) {
                (uint256 amount0, uint256 amount1) = getPositionAmounts(position);
                amount0PerRange[i] = (amount0 * liquidityToWithdraw) / position.liquidity;
                amount1PerRange[i] = (amount1 * liquidityToWithdraw) / position.liquidity;
                
                amount0Total += amount0PerRange[i];
                amount1Total += amount1PerRange[i];
            }
        }
    }

    function getWeightedAverageRatio() public view returns (uint256) {
        uint256 weightedRatio = 0;
        uint256 totalWeight = 0;
        
        for (uint i = 0; i < positions.length; i++) {
            Position memory position = positions[i];
            if (position.liquidity > 0) {
                weightedRatio += (position.lastKnownRatio * position.percentage);
                totalWeight += position.percentage;
            }
        }
        
        return totalWeight > 0 ? weightedRatio / totalWeight : RATIO_MULTIPLIER;
    }

    function updateRangeRatios() public {
        for (uint i = 0; i < positions.length; i++) {
            Position storage position = positions[i];
            if (position.liquidity == 0) continue;

            // Get current tick
            (, int24 currentTick,,,,,) = pool.slot0();
            
            // Calculate amounts
            uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(currentTick);
            uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(position.tickLower);
            uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(position.tickUpper);
            
            (uint256 token0Amount, uint256 token1Amount) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtRatioX96,
                sqrtRatioAX96,
                sqrtRatioBX96,
                position.liquidity
            );
            
            // Update ratio if both amounts are non-zero
            if (token1Amount > 0) {
                position.lastKnownRatio = (token0Amount * RATIO_MULTIPLIER) / token1Amount;
                emit RatioUpdated(position.tokenId, position.lastKnownRatio);
            }
        }
    }

    function getPositionRatios() external view returns (uint256[] memory ratios) {
        ratios = new uint256[](positions.length);
        for (uint i = 0; i < positions.length; i++) {
            ratios[i] = positions[i].lastKnownRatio;
        }
        return ratios;
    }

    function getCurrentRangeStatuses() external view returns (
        bool[] memory isInRange,
        uint256[] memory utilizations
    ) {
        isInRange = new bool[](positions.length);
        utilizations = new uint256[](positions.length);
        
        (, int24 currentTick,,,,,) = pool.slot0();
        
        for (uint i = 0; i < positions.length; i++) {
            Position memory position = positions[i];
            isInRange[i] = currentTick >= position.tickLower && currentTick <= position.tickUpper;
            
            if (isInRange[i]) {
                uint256 rangeSize = uint24(position.tickUpper - position.tickLower);
                uint256 distanceFromLower = uint24(currentTick - position.tickLower);
                utilizations[i] = (distanceFromLower * 100) / rangeSize;
            }
        }
    }

    function _balanceAmounts(
        uint256 amount0In,
        uint256 amount1In,
        uint256 optimal0,
        uint256 optimal1
    ) internal returns (uint256 amount0, uint256 amount1) {
        // Get current price
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint256 price = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * PRICE_PRECISION >> (96 * 2);

        // Calculate value differences
        uint256 value0In = amount0In * price / PRICE_PRECISION;
        uint256 value1In = amount1In;
        uint256 value0Optimal = optimal0 * price / PRICE_PRECISION;
        uint256 value1Optimal = optimal1;

        // Determine which token to swap
        if (value0In > value0Optimal) {
            // Need to swap excess token0 for token1
            uint256 excess0 = amount0In - optimal0;
            token0.approve(address(swapRouter), excess0);
            
            uint256 minOut = (excess0 * price * 98) / (PRICE_PRECISION * 100); // 2% slippage tolerance
            
            uint256 amountOut = swapRouter.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: address(token0),
                    tokenOut: address(token1),
                    fee: 10000, // 1% fee
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: excess0,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            );
            
            amount0 = optimal0;
            amount1 = amount1In + amountOut;
            
        } else if (value1In > value1Optimal) {
            // Need to swap excess token1 for token0
            uint256 excess1 = amount1In - optimal1;
            token1.approve(address(swapRouter), excess1);
            
            uint256 minOut = (excess1 * PRICE_PRECISION * 98) / (price * 100); // 2% slippage tolerance
            
            uint256 amountOut = swapRouter.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: address(token1),
                    tokenOut: address(token0),
                    fee: 10000,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: excess1,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            );
            
            amount0 = amount0In + amountOut;
            amount1 = optimal1;
        } else {
            amount0 = amount0In;
            amount1 = amount1In;
        }
    }

}
