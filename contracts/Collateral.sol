// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./PoolToken.sol";
import "./interfaces/IBorrowable.sol";
import "./interfaces/ICollateral.sol";
import "./interfaces/IFactory.sol";
import "./interfaces/ITarotPriceOracle.sol";
import "./interfaces/ITarotCallee.sol";
import "./interfaces/IStratusALPT.sol";
import "./interfaces/IUniswapV3Pool.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract Collateral is ICollateral, PoolToken {
    // --- Custom Errors ---
    error PriceCalculationError();
    error InvalidBorrowable();
    error InsufficientShortfall();
    error LiquidatingTooMuch();
    error InsufficientRedeemTokens();

    // --- State Variables (formerly CStorage) ---
    address public borrowable0;
    address public borrowable1;
    address public tarotPriceOracle;

    // --- Constants ---
    uint256 public constant SAFETY_MARGIN_SQRT_MIN = 1e18; // safetyMargin: 100%
    uint256 public constant SAFETY_MARGIN_SQRT_MAX = 1581138840000000000; // safetyMargin: 250%
    uint256 public constant LIQUIDATION_INCENTIVE_MIN = 1e18; // 100%
    uint256 public constant LIQUIDATION_INCENTIVE_MAX = 1040000000000000000; // 105%

    // --- Events ---
    // Events are inherited from ICollateral interface

    constructor() {}

    /*** Initialization and Settings ***/

    // called once by the factory at the time of deployment
    function _initialize(
        string calldata _name,
        string calldata _symbol,
        address _underlying,
        address _borrowable0,
        address _borrowable1
    ) external {
        if (msg.sender != factory) revert Unauthorized();
        _setName(_name, _symbol);
        underlying = _underlying;
        borrowable0 = _borrowable0;
        borrowable1 = _borrowable1;
        tarotPriceOracle = address(IFactory(factory).tarotPriceOracle());
    }

    // Override functions that are defined in multiple base contracts
    function _setFactory() external override(PoolToken, ICollateral) {
        if (factory != address(0)) revert FactoryAlreadySet();
        factory = msg.sender;
    }

    function exchangeRate() public override(PoolToken, ICollateral) returns (uint256) {
        return PoolToken.exchangeRate();
    }

    function mint(address minter) external override(PoolToken, ICollateral) nonReentrant update returns (uint256 mintTokens) {
        uint256 balance = IERC20(underlying).balanceOf(address(this));
        uint256 mintAmount = balance - totalBalance;
        mintTokens = (mintAmount * 1e18) / exchangeRate();

        if (totalSupply == 0) {
            // permanently lock the first MINIMUM_LIQUIDITY tokens
            mintTokens -= MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY);
        }
        if (mintTokens == 0) revert MintAmountZero();
        _mint(minter, mintTokens);
        emit Mint(msg.sender, minter, mintAmount, mintTokens); 
    }

    function redeem(address redeemer) external override(PoolToken, ICollateral) nonReentrant update returns (uint256 redeemAmount) {
        uint256 redeemTokens = balanceOf[address(this)];
        redeemAmount = (redeemTokens * exchangeRate()) / 1e18;

        if (redeemAmount == 0) revert RedeemAmountZero();
        if (redeemAmount > totalBalance) revert InsufficientCash();
        _burn(address(this), redeemTokens);
        _safeTransfer(redeemer, redeemAmount);
        emit Redeem(msg.sender, redeemer, redeemAmount, redeemTokens);
    }

    function _setSafetyMarginSqrt(uint256 newSafetyMarginSqrt) external nonReentrant {
        _checkSetting(newSafetyMarginSqrt, SAFETY_MARGIN_SQRT_MIN, SAFETY_MARGIN_SQRT_MAX);
        safetyMarginSqrt = newSafetyMarginSqrt;
        emit NewSafetyMargin(newSafetyMarginSqrt);
    }

    function _setLiquidationIncentive(uint256 newLiquidationIncentive) external nonReentrant {
        _checkSetting(newLiquidationIncentive, LIQUIDATION_INCENTIVE_MIN, LIQUIDATION_INCENTIVE_MAX);
        liquidationIncentive = newLiquidationIncentive;
        emit NewLiquidationIncentive(newLiquidationIncentive);
    }

    function _checkSetting(uint256 parameter, uint256 min, uint256 max) internal view {
        _checkAdmin();
        if (parameter < min || parameter > max) revert InvalidSetting();
    }

    function _checkAdmin() internal view {
        if (msg.sender != IFactory(factory).admin()) revert Unauthorized();
    }

    /*** Collateralization Model ***/

    function getPrices() public view returns (uint256 price0, uint256 price1) {
        (uint224 twapPrice112x112, ) = ITarotPriceOracle(tarotPriceOracle).getResult(underlying);
        
        (uint256 total0, uint256 total1) = IStratusALPT(underlying).getTotalAmounts();
        uint256 collateralTotalSupply = IStratusALPT(underlying).totalSupply();

        address poolAddress = IStratusALPT(underlying).pool();
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(poolAddress).slot0();
        
        uint256 currentPrice112x112 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 80;

        uint256 adjustmentSquared = (uint256(twapPrice112x112) * (2**32)) / currentPrice112x112;
        uint256 adjustment = Math.sqrt(adjustmentSquared * (2**32));

        uint256 currentBorrowable0Price = (collateralTotalSupply * 1e18) / (total0 * 2);
        uint256 currentBorrowable1Price = (collateralTotalSupply * 1e18) / (total1 * 2);

        price0 = (currentBorrowable0Price * adjustment) / (2**32);
        price1 = (currentBorrowable1Price * (2**32)) / adjustment;

        if (price0 <= 100 || price1 <= 100) revert PriceCalculationError();
    }

    function _calculateLiquidity(
        uint256 amountCollateral,
        uint256 amount0,
        uint256 amount1
    ) internal view returns (uint256 liquidity, uint256 shortfall) {
        uint256 _safetyMarginSqrt = safetyMarginSqrt;
        (uint256 price0, uint256 price1) = getPrices();

        uint256 a = (amount0 * price0) / 1e18;
        uint256 b = (amount1 * price1) / 1e18;
        if (a < b) (a, b) = (b, a);
        a = (a * _safetyMarginSqrt) / 1e18;
        b = (b * 1e18) / _safetyMarginSqrt;
        uint256 collateralNeeded = ((a + b) * liquidationIncentive) / 1e18;

        if (amountCollateral >= collateralNeeded) {
            return (amountCollateral - collateralNeeded, 0);
        } else {
            return (0, collateralNeeded - amountCollateral);
        }
    }

    /*** ERC20 ***/

    function _transfer(
        address from,
        address to,
        uint256 value
    ) internal override {
        if (!tokensUnlocked(from, value)) revert InsufficientLiquidity();
        super._transfer(from, to, value);
    }

    function tokensUnlocked(address from, uint256 value) public returns (bool) {
        uint256 _balance = balanceOf[from];
        if (value > _balance) return false;
        uint256 finalBalance = _balance - value;
        uint256 amountCollateral = (finalBalance * exchangeRate()) / 1e18;
        uint256 amount0 = IBorrowable(borrowable0).borrowBalance(from);
        uint256 amount1 = IBorrowable(borrowable1).borrowBalance(from);
        (, uint256 shortfall) = _calculateLiquidity(amountCollateral, amount0, amount1);
        return shortfall == 0;
    }

    /*** Collateral ***/

    function accountLiquidityAmounts(
        address borrower,
        uint256 amount0,
        uint256 amount1
    ) public returns (uint256 liquidity, uint256 shortfall) {
        if (amount0 == type(uint256).max)
            amount0 = IBorrowable(borrowable0).borrowBalance(borrower);
        if (amount1 == type(uint256).max)
            amount1 = IBorrowable(borrowable1).borrowBalance(borrower);
        uint256 amountCollateral = (balanceOf[borrower] * exchangeRate()) / 1e18;
        return _calculateLiquidity(amountCollateral, amount0, amount1);
    }

    function accountLiquidity(address borrower)
        public
        returns (uint256 liquidity, uint256 shortfall)
    {
        return accountLiquidityAmounts(borrower, type(uint256).max, type(uint256).max);
    }

    function canBorrow(
        address borrower,
        address borrowable,
        uint256 accountBorrows
    ) public returns (bool) {
        address _borrowable0 = borrowable0;
        address _borrowable1 = borrowable1;
        if (borrowable != _borrowable0 && borrowable != _borrowable1) {
            revert InvalidBorrowable();
        }
        uint256 amount0 = borrowable == _borrowable0 ? accountBorrows : type(uint256).max;
        uint256 amount1 = borrowable == _borrowable1 ? accountBorrows : type(uint256).max;
        (, uint256 shortfall) = accountLiquidityAmounts(borrower, amount0, amount1);
        return shortfall == 0;
    }

    function seize(
        address liquidator,
        address borrower,
        uint256 repayAmount
    ) external returns (uint256 seizeTokens) {
        if (msg.sender != borrowable0 && msg.sender != borrowable1) {
            revert Unauthorized();
        }

        (, uint256 shortfall) = accountLiquidity(borrower);
        if (shortfall == 0) revert InsufficientShortfall();

        uint256 price;
        if (msg.sender == borrowable0) (price, ) = getPrices();
        else (, price) = getPrices();

        seizeTokens = (((repayAmount * liquidationIncentive) / 1e18) * price) / exchangeRate();

        uint256 borrowerBalance = balanceOf[borrower];
        if (seizeTokens > borrowerBalance) revert LiquidatingTooMuch();
        balanceOf[borrower] = borrowerBalance - seizeTokens;
        
        balanceOf[liquidator] += seizeTokens;
        emit Transfer(borrower, liquidator, seizeTokens);
    }

    function flashRedeem(
        address redeemer,
        uint256 redeemAmount,
        bytes calldata data
    ) external nonReentrant update {
        if (redeemAmount > totalBalance) revert InsufficientCash();

        _safeTransfer(redeemer, redeemAmount);
        if (data.length > 0)
            ITarotCallee(redeemer).tarotRedeem(msg.sender, redeemAmount, data);

        uint256 redeemTokens = balanceOf[address(this)];
        uint256 declaredRedeemTokens = (redeemAmount * 1e18) / exchangeRate() + 1;
        if (redeemTokens < declaredRedeemTokens) {
            revert InsufficientRedeemTokens();
        }

        _burn(address(this), redeemTokens);
        emit Redeem(msg.sender, redeemer, redeemAmount, redeemTokens);
    }
}