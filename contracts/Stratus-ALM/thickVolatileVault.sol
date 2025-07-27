// SPDX-License-Identifier: none
pragma solidity ^0.8.24;
pragma abicoder v2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';
import "./libraries/TickMath.sol";
import "./libraries/LiquidityAmounts.sol";
import './interfaces/IUniswapV3Pool.sol';
import './interfaces/INonfungiblePositionManager.sol';

contract ThickVolatileVault is ERC20, ReentrancyGuard {
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
    error InvalidRange();
    error InvalidBias();
    error InsufficientAmount();
    error SlippageExceeded();
    error InvalidShares();
    error NotInRange();
    error Unauthorized();
    error InvalidTimeframe();
    error CooldownActive();
    error InsufficientToken0();
    error InsufficientToken1();
    error LowOutput0();
    error LowOutput1();

    // Constants
    uint256 private constant MINIMUM_DEPOSIT_PERIOD = 1 minutes;
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant PRICE_PRECISION = 1e18;
    uint256 public constant RATIO_MULTIPLIER = 1e18;

    // Immutable references
    IUniswapV3Pool public immutable pool;
    INonfungiblePositionManager public immutable positionManager;
    IERC20 public immutable token0;
    IERC20 public immutable token1;
    address public immutable factory;

    // Vault configuration - Modified for 2thick's tick spacing
    int24[3] public rangeWidths = [
       int24 (1),    // Finest granularity: narrow range
        int24 (8),    // Medium granularity: medium range
         int24 (64)    // Coarse granularity: wide range
    ];
    uint256[3] public rangeWeights = [
        5000,   // 50% in narrow range
        3000,   // 30% in medium range
        2000    // 20% in wide range
    ];
    uint256 public upwardBias;        // >100 means upward bias
    
    // Position tracking
    Position[] public positions;
    mapping(address => uint256) private lastDepositTime;

    // Events
    event PositionCreated(uint256 indexed tokenId, int24 tickLower, int24 tickUpper, uint256 liquidity);
    event PositionIncreased(uint256 indexed tokenId, uint128 liquidityAdded);
    event PositionDecreased(uint256 indexed tokenId, uint128 liquidityRemoved);
    event FeesCollected(uint256 indexed tokenId, uint256 amount0, uint256 amount1);
    event ProtocolFeesPaid(uint256 amount0, uint256 amount1);
    event Deposit(address indexed user, uint256 amount0, uint256 amount1, uint256 shares);
    event Withdraw(address indexed user, uint256 shares, uint256 amount0, uint256 amount1);
    event RatioUpdated(uint256 indexed tokenId, uint256 newRatio);
    event PositionRebalanced(uint256 indexed oldTokenId, uint256 indexed newTokenId, int24 newTickLower, int24 newTickUpper);

    // For automatic re-ranging of the tightest position
    uint256 public tightestPositionOutOfRangeSince;
   

    // Add to state variables
    ISwapRouter public immutable swapRouter;

    // Modify state variables
    uint8 public constant PROTOCOL_FEE = 15;  // Hardcoded 15% fee
    uint16 public constant COMPOUND_BOUNTY = 50; // 0.5% bounty (50 / 10000)

    // Add checkpoint tracking
    struct Checkpoint {
        uint256 timestamp;
        uint256 feeToken0;
        uint256 feeToken1;
    }
    
    // Track global fee checkpoints
    Checkpoint[] public feeCheckpoints;
    
    // Track user's last claim checkpoint
    mapping(address => uint256) public userCheckpoint;  // Index into feeCheckpoints array

    constructor(
        address _pool,
        address _positionManager,
        address _swapRouter,
        string memory _name,
        string memory _symbol,
        uint256 _upwardBias
    ) ERC20(_name, _symbol) {
        if (_pool == address(0) || _positionManager == address(0)) revert ZeroAddress();
        if (_upwardBias < 50 || _upwardBias > 200) revert InvalidBias();
        
        uint256 totalWeight;
        for (uint i = 0; i < 3; i++) {
            totalWeight += rangeWeights[i];
        }
        if (totalWeight != BASIS_POINTS) revert InvalidRange();

        pool = IUniswapV3Pool(_pool);
        positionManager = INonfungiblePositionManager(_positionManager);
        token0 = IERC20(pool.token0());
        token1 = IERC20(pool.token1());
        factory = msg.sender;
        upwardBias = _upwardBias;
        swapRouter = ISwapRouter(_swapRouter);
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

    function deposit(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) external nonReentrant returns (uint256 shares) {
        if (totalSupply() == 0 && msg.sender != factory) revert Unauthorized();

        _checkAndRebalanceTightestPosition();

        // Add cooldown check
        if (lastDepositTime[msg.sender] != 0) {
            if (block.timestamp < lastDepositTime[msg.sender] + MINIMUM_DEPOSIT_PERIOD) {
                revert CooldownActive();
            }
        }
        
        if (amount0Desired == 0 && amount1Desired == 0) revert InsufficientAmount();
        
        // Add balance verification
        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));
        
        // Transfer tokens to vault
        if (amount0Desired > 0) {
            token0.safeTransferFrom(msg.sender, address(this), amount0Desired);
        }
        if (amount1Desired > 0) {
            token1.safeTransferFrom(msg.sender, address(this), amount1Desired);
        }

        if (token0.balanceOf(address(this)) - balance0Before < amount0Min) revert InsufficientToken0();
        if (token1.balanceOf(address(this)) - balance1Before < amount1Min) revert InsufficientToken1();

        // Get optimal amounts
        (uint256 optimal0, uint256 optimal1) = getOptimalDepositAmounts(amount0Desired, amount1Desired);
        
        // Balance amounts through swaps if needed
        (uint256 amount0, uint256 amount1) = _balanceAmounts(
            amount0Desired,
            amount1Desired,
            optimal0,
            optimal1
        );

        // Verify final amounts meet minimum requirements
        if (amount0 < amount0Min || amount1 < amount1Min) revert SlippageExceeded();

        // Calculate shares
        shares = calculateShares(amount0, amount1);
        if (shares == 0) revert InvalidShares();

        // Create or modify positions
        (, int24 currentTick, , , , , ) = pool.slot0();
        (int24[] memory tickLowers, int24[] memory tickUppers) = getAsymmetricRanges(currentTick);

        // If first deposit, create positions
        if (positions.length == 0) {
            for (uint256 i = 0; i < 3; i++) {
                uint256 amount0ToAdd = (amount0 * rangeWeights[i]) / BASIS_POINTS;
                uint256 amount1ToAdd = (amount1 * rangeWeights[i]) / BASIS_POINTS;
                
                _createPosition(
                    tickLowers[i],
                    tickUppers[i],
                    amount0ToAdd,
                    amount1ToAdd,
                    (amount0Min * rangeWeights[i]) / BASIS_POINTS,
                    (amount1Min * rangeWeights[i]) / BASIS_POINTS,
                    rangeWeights[i]
                );
            }
        } else {
            _addToExistingPositions(amount0, amount1, amount0Min, amount1Min);
        }

        // Update deposit timestamp and mint shares
        lastDepositTime[msg.sender] = block.timestamp;
        _mint(msg.sender, shares);

        // Set user's checkpoint to current
        userCheckpoint[msg.sender] = feeCheckpoints.length;
        
        emit Deposit(msg.sender, amount0, amount1, shares);
    }


    function _addToExistingPositions(
        uint256 amount0Total,
        uint256 amount1Total,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal {
        for (uint256 i = 0; i < positions.length; i++) {
            Position storage position = positions[i];
            uint256 amount0ToAdd = (amount0Total * position.percentage) / BASIS_POINTS;
            uint256 amount1ToAdd = (amount1Total * position.percentage) / BASIS_POINTS;
            
            if (amount0ToAdd > 0 || amount1ToAdd > 0) {
                token0.approve(address(positionManager), amount0ToAdd);
                token1.approve(address(positionManager), amount1ToAdd);

                (uint128 liquidityAdded, , ) = positionManager.increaseLiquidity(
                    INonfungiblePositionManager.IncreaseLiquidityParams({
                        tokenId: position.tokenId,
                        amount0Desired: amount0ToAdd,
                        amount1Desired: amount1ToAdd,
                        amount0Min: (amount0Min * position.percentage) / BASIS_POINTS,
                        amount1Min: (amount1Min * position.percentage) / BASIS_POINTS,
                        deadline: block.timestamp
                    })
                );

                position.liquidity += liquidityAdded;
                emit PositionIncreased(position.tokenId, liquidityAdded);
            }
        }
    }

    function _createPosition(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 percentage
    ) internal {
        if (tickLower >= tickUpper) revert InvalidRange();

        token0.approve(address(positionManager), amount0Desired);
        token1.approve(address(positionManager), amount1Desired);
        
        (uint256 tokenId, uint128 liquidity, , ) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(token0),
                token1: address(token1),
                fee: 10000, // Fixed 1% fee for 2thick
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

        positions.push(Position({
            tokenId: tokenId,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            percentage: percentage,
            feeToken0: 0,
            feeToken1: 0,
            lastKnownRatio: RATIO_MULTIPLIER
        }));

        emit PositionCreated(tokenId, tickLower, tickUpper, liquidity);
    }

    function getOptimalDepositAmounts(
        uint256 amount0Desired,
        uint256 amount1Desired
    ) public view returns (
        uint256 optimal0,
        uint256 optimal1
    ) {
        if (positions.length == 0) {
            return (amount0Desired, amount1Desired);
        }

        // Get current price and position ratios
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint256 currentPrice = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * PRICE_PRECISION >> (96 * 2);
        
        uint256 totalValue0;
        uint256 totalValue1;
        
        // Calculate total value in each token
        for (uint i = 0; i < positions.length; i++) {
            (uint256 pos0, uint256 pos1) = getPositionAmounts(positions[i]);
            totalValue0 += pos0;
            totalValue1 += pos1;
        }

        // If either total is 0, use current price only
        if (totalValue0 == 0 || totalValue1 == 0) {
            return (amount0Desired, amount1Desired);
        }

        // Calculate optimal ratio based on current positions
        uint256 optimalRatio = (totalValue0 * PRICE_PRECISION) / totalValue1;
        
        // Adjust deposit amounts to match optimal ratio
        uint256 totalDesiredValue = amount0Desired + (amount1Desired * currentPrice) / PRICE_PRECISION;
        optimal0 = (totalDesiredValue * optimalRatio) / (optimalRatio + currentPrice);
        optimal1 = (totalDesiredValue * PRICE_PRECISION) / (optimalRatio + currentPrice);
    }

    function getAsymmetricRanges(int24 currentTick) public view returns (
        int24[] memory tickLowers,
        int24[] memory tickUppers
    ) {
        tickLowers = new int24[](3);
        tickUppers = new int24[](3);
        
        // Use fixed tick spacing of 1
        for (uint i = 0; i < 3; i++) {
            int24 width = rangeWidths[i];
            
            // Lower bound stays same for downside protection
            tickLowers[i] = currentTick - width;
            
            // Upper bound extends based on upward bias
            int24 upwardWidth = int24(int256(width) * int256(upwardBias) / 100);
            tickUppers[i] = currentTick + upwardWidth;
            
            // Round to nearest tick
            tickLowers[i] = tickLowers[i] - (tickLowers[i] % 1);
            tickUppers[i] = tickUppers[i] - (tickUppers[i] % 1);
        }
    }

    function withdraw(
        uint256 shares,
        uint256 amount0Min,
        uint256 amount1Min
    ) external nonReentrant {
        _checkAndRebalanceTightestPosition();

        if (shares == 0 || shares > balanceOf(msg.sender)) revert InvalidShares();
        
        uint256 totalShares = totalSupply();
        _burn(msg.sender, shares);

        uint256 amount0Prop;
        uint256 amount1Prop;

        for (uint256 i = 0; i < positions.length; i++) {
            Position storage position = positions[i];
            
            uint128 liquidityToWithdraw = uint128((uint256(position.liquidity) * shares) / totalShares);
            if (liquidityToWithdraw > 0) {
                (uint256 amount0, uint256 amount1) = _decreasePosition(position.tokenId, liquidityToWithdraw);
                amount0Prop += amount0;
                amount1Prop += amount1;
                position.liquidity -= liquidityToWithdraw;
            }
        }

        (uint256 finalAmount0, uint256 finalAmount1) = _applyRebalanceIncentive(amount0Prop, amount1Prop);

        if (finalAmount0 < amount0Min) revert LowOutput0();
        if (finalAmount1 < amount1Min) revert LowOutput1();
        
        if (finalAmount0 > 0) token0.safeTransfer(msg.sender, finalAmount0);
        if (finalAmount1 > 0) token1.safeTransfer(msg.sender, finalAmount1);

        emit Withdraw(msg.sender, shares, finalAmount0, finalAmount1);
    }

    function _applyRebalanceIncentive(uint256 amount0Prop, uint256 amount1Prop) 
        internal 
        view 
        returns (uint256 finalAmount0, uint256 finalAmount1)
    {
        uint256 MAX_ADJUSTMENT_BPS = 500; // 5% total swing
        (uint256 total0, uint256 total1) = getTotalAmounts();

        if (total0 == 0 || total1 == 0) {
            return (amount0Prop, amount1Prop);
        }

        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint256 price = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * (10**IERC20Metadata(address(token0)).decimals())) / (uint256(1) << 192) / (10**IERC20Metadata(address(token1)).decimals());

        uint256 vaultValue0 = total0 * price;
        uint256 vaultValue1 = total1 * 1e18;

        if (vaultValue0 == vaultValue1) {
            return (amount0Prop, amount1Prop);
        }

        uint256 totalValue = vaultValue0 + vaultValue1;
        uint256 adjustmentBps;

        if (vaultValue0 > vaultValue1) { // Heavy on token0
            uint256 excessValue = vaultValue0 - vaultValue1;
            adjustmentBps = (excessValue * MAX_ADJUSTMENT_BPS) / totalValue;
            
            uint256 bonus0 = (amount0Prop * adjustmentBps) / BASIS_POINTS;
            uint256 penalty1Value = (bonus0 * price) / 1e18;
            uint256 penalty1 = (penalty1Value * (10**IERC20Metadata(address(token1)).decimals())) / (10**IERC20Metadata(address(token0)).decimals());

            finalAmount0 = amount0Prop + bonus0;
            finalAmount1 = amount1Prop > penalty1 ? amount1Prop - penalty1 : 0;

        } else { // Heavy on token1
            uint256 excessValue = vaultValue1 - vaultValue0;
            adjustmentBps = (excessValue * MAX_ADJUSTMENT_BPS) / totalValue;

            uint256 bonus1 = (amount1Prop * adjustmentBps) / BASIS_POINTS;
            uint256 penalty0Value = (bonus1 * 1e18) / price;
            uint256 penalty0 = (penalty0Value * (10**IERC20Metadata(address(token0)).decimals())) / (10**IERC20Metadata(address(token1)).decimals());

            finalAmount1 = amount1Prop + bonus1;
            finalAmount0 = amount0Prop > penalty0 ? amount0Prop - penalty0 : 0;
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

    function _checkAndRebalanceTightestPosition() internal {
        if (positions.length == 0) {
            return; // No positions to rebalance
        }

        // We assume the tightest position is at index 0
        Position storage tightestPosition = positions[0];
        (, int24 currentTick,,,,,) = pool.slot0();

        bool isInRange = currentTick >= tightestPosition.tickLower && currentTick < tightestPosition.tickUpper;

        if (!isInRange) {
            if (tightestPositionOutOfRangeSince == 0) {
                tightestPositionOutOfRangeSince = block.timestamp;
            } else if (block.timestamp >= tightestPositionOutOfRangeSince + 1 hours) {
                // Time to rebalance.
                
                // 1. Withdraw all liquidity from the old position. It will be single-sided.
                (uint256 amount0, uint256 amount1) = _decreasePosition(tightestPosition.tokenId, tightestPosition.liquidity);
                
                uint256 amount0ToDeposit;
                uint256 amount1ToDeposit;

                // 2. Swap half of the withdrawn asset to rebalance for the new position.
                if (amount0 > 0) {
                    // Price is above the old range, we have only token0. Swap half for token1.
                    uint256 amountToSwap = amount0 / 2;
                    token0.approve(address(swapRouter), amountToSwap);
                    
                    uint256 amount1Received = swapRouter.exactInputSingle(
                        ISwapRouter.ExactInputSingleParams({
                            tokenIn: address(token0),
                            tokenOut: address(token1),
                            fee: 10000, // 1% fee
                            recipient: address(this),
                            deadline: block.timestamp,
                            amountIn: amountToSwap,
                            amountOutMinimum: 0, // Slippage is not a primary concern for internal rebalancing
                            sqrtPriceLimitX96: 0
                        })
                    );
                    amount0ToDeposit = amount0 - amountToSwap;
                    amount1ToDeposit = amount1Received;
                } else if (amount1 > 0) {
                    // Price is below the old range, we have only token1. Swap half for token0.
                    uint256 amountToSwap = amount1 / 2;
                    token1.approve(address(swapRouter), amountToSwap);

                    uint256 amount0Received = swapRouter.exactInputSingle(
                        ISwapRouter.ExactInputSingleParams({
                            tokenIn: address(token1),
                            tokenOut: address(token0),
                            fee: 10000, // 1% fee
                            recipient: address(this),
                            deadline: block.timestamp,
                            amountIn: amountToSwap,
                            amountOutMinimum: 0,
                            sqrtPriceLimitX96: 0
                        })
                    );
                    amount0ToDeposit = amount0Received;
                    amount1ToDeposit = amount1 - amountToSwap;
                }

                // 3. Create a new position centered around the current tick
                (int24[] memory newTickLowers, int24[] memory newTickUppers) = getAsymmetricRanges(currentTick);
                int24 newTickLower = newTickLowers[0];
                int24 newTickUpper = newTickUppers[0];

                if (amount0ToDeposit > 0) token0.approve(address(positionManager), amount0ToDeposit);
                if (amount1ToDeposit > 0) token1.approve(address(positionManager), amount1ToDeposit);

                (uint256 newTokenId, uint128 newLiquidity, , ) = positionManager.mint(
                    INonfungiblePositionManager.MintParams({
                        token0: address(token0),
                        token1: address(token1),
                        fee: 10000,
                        tickLower: newTickLower,
                        tickUpper: newTickUpper,
                        amount0Desired: amount0ToDeposit,
                        amount1Desired: amount1ToDeposit,
                        amount0Min: 0,
                        amount1Min: 0,
                        recipient: address(this),
                        deadline: block.timestamp
                    })
                );

                emit PositionRebalanced(tightestPosition.tokenId, newTokenId, newTickLower, newTickUpper);

                // 4. Update the position struct in our state
                tightestPosition.tokenId = newTokenId;
                tightestPosition.tickLower = newTickLower;
                tightestPosition.tickUpper = newTickUpper;
                tightestPosition.liquidity = newLiquidity;
                
                tightestPositionOutOfRangeSince = 0;
            }
        } else {
            if (tightestPositionOutOfRangeSince != 0) {
                tightestPositionOutOfRangeSince = 0;
            }
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

    function calculateShares(uint256 amount0, uint256 amount1) public view returns (uint256) {
        uint256 totalSupply = totalSupply();
        if (totalSupply == 0) {
            return Math.sqrt(amount0 * amount1);
        }
        
        (uint256 total0, uint256 total1) = getTotalAmounts();
        if (total0 == 0 || total1 == 0) return 0;
        
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

        uint256 protocolFee0 = (remaining0 * PROTOCOL_FEE) / 100;
        uint256 protocolFee1 = (remaining1 * PROTOCOL_FEE) / 100;

        if (protocolFee0 > 0) token0.safeTransfer(factory, protocolFee0);
        if (protocolFee1 > 0) token1.safeTransfer(factory, protocolFee1);
        emit ProtocolFeesPaid(protocolFee0, protocolFee1);

        compounded0 = remaining0 - protocolFee0;
        compounded1 = remaining1 - protocolFee1;

        // --- 3. Reinvest the remaining fees --- 
        for (uint256 i = 0; i < positions.length; i++) {
            Position storage position = positions[i];
            uint256 amount0ToAdd = (compounded0 * position.percentage) / BASIS_POINTS;
            uint256 amount1ToAdd = (compounded1 * position.percentage) / BASIS_POINTS;
            
            if (amount0ToAdd > 0 || amount1ToAdd > 0) {
                token0.approve(address(positionManager), amount0ToAdd);
                token1.approve(address(positionManager), amount1ToAdd);

                // Calculate slippage protection (e.g., 1%)
                (uint256 expected0, uint256 expected1) = getPositionAmountsForLiquidity(position.tickLower, position.tickUpper, 1e18);
                uint256 amount0Min = (amount0ToAdd * 99) / 100;
                uint256 amount1Min = (amount1ToAdd * 99) / 100;

                (uint128 liquidityAdded, , ) = positionManager.increaseLiquidity(
                    INonfungiblePositionManager.IncreaseLiquidityParams({
                        tokenId: position.tokenId,
                        amount0Desired: amount0ToAdd,
                        amount1Desired: amount1ToAdd,
                        amount0Min: amount0Min,
                        amount1Min: amount1Min,
                        deadline: block.timestamp
                    })
                );

                position.liquidity += liquidityAdded;
                emit PositionIncreased(position.tokenId, liquidityAdded);
            }
        }
        // We can use the Deposit event here to signify reinvestment
        emit Deposit(msg.sender, compounded0, compounded1, 0);
    }

    function getPositionAmountsForLiquidity(int24 tickLower, int24 tickUpper, uint128 liquidity) public view returns (uint256 amount0, uint256 amount1) {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);
        
        return LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            liquidity
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
        
        amount0PerRange = new uint256[](rangeWeights.length);
        amount1PerRange = new uint256[](rangeWeights.length);
        
        for (uint256 i = 0; i < rangeWeights.length; i++) {
            amount0PerRange[i] = (amount0Desired * rangeWeights[i]) / BASIS_POINTS;
            amount1PerRange[i] = (amount1Desired * rangeWeights[i]) / BASIS_POINTS;
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

} 