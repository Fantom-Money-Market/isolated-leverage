// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./PoolToken.sol";
import "./BInterestModel.sol";
import "./BStorage.sol";
import "./interfaces/IBorrowable.sol";
import "./interfaces/ICollateral.sol";
import "./interfaces/ITarotCallee.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IFactory.sol";
import "./interfaces/IBorrowTracker.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract Borrowable is
    PoolToken,
    BStorage,
    BInterestRateModel,
    IBorrowable
{
    // --- Custom Errors ---
    error BorrowNotAllowed();

    // --- Constants ---
    uint256 public constant BORROW_FEE = 1e15; // 0.1%
    uint256 public constant RESERVE_FACTOR_MAX = 2e17; // 20%
    uint256 public constant KINK_UR_MIN = 5e17; // 50%
    uint256 public constant KINK_UR_MAX = 99e16; // 99%
    uint256 public constant ADJUST_SPEED_MIN = 57870370000; // 0.5% per day
    uint256 public constant ADJUST_SPEED_MAX = 5787037000000; // 50% per day
    // keccak256("BorrowPermit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant BORROW_PERMIT_TYPEHASH = 0xf6d86ed606f871fa1a557ac0ba607adce07767acf53f492fb215a1a4db4aea6f;

    // --- Events ---
    // Events are inherited from IBorrowable interface

    constructor() {}

    /*** Initialization & Settings ***/

    function _initialize(string calldata _name, string calldata _symbol, address _underlying, address _collateral) external {
        if (msg.sender != factory) revert Unauthorized();
        _setName(_name, _symbol);
        underlying = _underlying;
        collateral = _collateral;
        exchangeRateLast = INITIAL_EXCHANGE_RATE;
    }

    // Override functions that are defined in multiple base contracts
    function _setFactory() external override(PoolToken, IBorrowable) {
        if (factory != address(0)) revert FactoryAlreadySet();
        factory = msg.sender;
    }

    function accrueInterest() public override(BInterestRateModel, IBorrowable) {
        BInterestRateModel.accrueInterest();
    }

    function mint(address minter) external override(PoolToken, IBorrowable) nonReentrant update returns (uint256 mintTokens) {
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

    function redeem(address redeemer) external override(PoolToken, IBorrowable) nonReentrant update returns (uint256 redeemAmount) {
        uint256 redeemTokens = balanceOf[address(this)];
        redeemAmount = (redeemTokens * exchangeRate()) / 1e18;

        if (redeemAmount == 0) revert RedeemAmountZero();
        if (redeemAmount > totalBalance) revert InsufficientCash();
        _burn(address(this), redeemTokens);
        _safeTransfer(redeemer, redeemAmount);
        emit Redeem(msg.sender, redeemer, redeemAmount, redeemTokens);
    }

    function _setReserveFactor(uint256 newReserveFactor) external nonReentrant {
        _checkSetting(newReserveFactor, 0, RESERVE_FACTOR_MAX);
        reserveFactor = newReserveFactor;
        emit NewReserveFactor(newReserveFactor);
    }

    function _setKinkUtilizationRate(uint256 newKinkUtilizationRate) external nonReentrant {
        _checkSetting(newKinkUtilizationRate, KINK_UR_MIN, KINK_UR_MAX);
        kinkUtilizationRate = newKinkUtilizationRate;
        emit NewKinkUtilizationRate(newKinkUtilizationRate);
    }

    function _setAdjustSpeed(uint256 newAdjustSpeed) external nonReentrant {
        _checkSetting(newAdjustSpeed, ADJUST_SPEED_MIN, ADJUST_SPEED_MAX);
        adjustSpeed = newAdjustSpeed;
        emit NewAdjustSpeed(newAdjustSpeed);
    }

    function _setBorrowTracker(address newBorrowTracker) external nonReentrant {
        _checkAdmin();
        borrowTracker = newBorrowTracker;
        emit NewBorrowTracker(newBorrowTracker);
    }

    /*** Borrow Allowance & Permit ***/

    function _borrowApprove(address owner, address spender, uint256 value) private {
        borrowAllowance[owner][spender] = value;
        emit BorrowApproval(owner, spender, value);
    }

    function borrowApprove(address spender, uint256 value) external returns (bool) {
        _borrowApprove(msg.sender, spender, value);
        return true;
    }

    function _checkBorrowAllowance(address owner, address spender, uint256 value) internal {
        uint256 _borrowAllowance = borrowAllowance[owner][spender];
        if (spender != owner && _borrowAllowance != type(uint256).max) {
            if (_borrowAllowance < value) revert BorrowNotAllowed();
            unchecked {
                borrowAllowance[owner][spender] = _borrowAllowance - value;
            }
        }
    }

    function borrowPermit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external {
        _checkSignature(owner, spender, value, deadline, v, r, s, BORROW_PERMIT_TYPEHASH);
        _borrowApprove(owner, spender, value);
    }

    /*** PoolToken Overrides ***/

    function _update() internal override {
        super._update();
        _calculateBorrowRate();
    }

    function _mintReserves(uint256 _exchangeRate, uint256 _totalSupply) internal returns (uint256) {
        uint256 _exchangeRateLast = exchangeRateLast;
        if (_exchangeRate > _exchangeRateLast) {
            uint256 _exchangeRateNew = _exchangeRate - (((_exchangeRate - _exchangeRateLast) * reserveFactor) / 1e18);
            uint256 liquidity = ((_totalSupply * _exchangeRate) / _exchangeRateNew) - _totalSupply;
            if (liquidity == 0) return _exchangeRate;
            address reservesManager = IFactory(factory).reservesManager();
            _mint(reservesManager, liquidity);
            exchangeRateLast = _exchangeRateNew;
            return _exchangeRateNew;
        }
        return _exchangeRate;
    }

    function exchangeRate() public override(PoolToken, IBorrowable) accrue returns (uint256) {
        uint256 _totalSupply = totalSupply;
        uint256 _actualBalance = totalBalance + totalBorrows;
        if (_totalSupply == 0 || _actualBalance == 0) return INITIAL_EXCHANGE_RATE;
        return (_actualBalance * 1e18) / _totalSupply;
    }
    
    function exchangeRateAccrue() public accrue returns (uint256) {
        uint256 _totalSupply = totalSupply;
        uint256 _actualBalance = totalBalance + totalBorrows;
        if (_totalSupply == 0 || _actualBalance == 0) return INITIAL_EXCHANGE_RATE;
        uint256 _exchangeRate = (_actualBalance * 1e18) / _totalSupply;
        return _mintReserves(_exchangeRate, _totalSupply);
    }

    function sync() external override(PoolToken, IBorrowable) nonReentrant update accrue {}

    /*** Borrowable Logic ***/

    function borrowBalance(address borrower) public view returns (uint256) {
        BorrowSnapshot memory borrowSnapshot = borrowBalances[borrower];
        if (borrowSnapshot.interestIndex == 0) return 0;
        return (uint256(borrowSnapshot.principal) * borrowIndex) / borrowSnapshot.interestIndex;
    }

    function _trackBorrow(address borrower, uint256 accountBorrows, uint256 _borrowIndex) internal {
        address _borrowTracker = borrowTracker;
        if (_borrowTracker == address(0)) return;
        IBorrowTracker(_borrowTracker).trackBorrow(borrower, accountBorrows, _borrowIndex);
    }

    function _updateBorrow(address borrower, uint256 borrowAmount, uint256 repayAmount) private returns (uint256 accountBorrowsPrior, uint256 accountBorrows, uint256 _totalBorrows) {
        accountBorrowsPrior = borrowBalance(borrower);
        if (borrowAmount == repayAmount) return (accountBorrowsPrior, accountBorrowsPrior, totalBorrows);
        
        uint112 _borrowIndex = borrowIndex;
        BorrowSnapshot storage borrowSnapshot = borrowBalances[borrower];

        if (borrowAmount > repayAmount) {
            uint256 increaseAmount = borrowAmount - repayAmount;
            accountBorrows = accountBorrowsPrior + increaseAmount;
            borrowSnapshot.principal = safe112(accountBorrows);
            borrowSnapshot.interestIndex = _borrowIndex;
            _totalBorrows = uint256(totalBorrows) + increaseAmount;
            totalBorrows = safe112(_totalBorrows);
        } else {
            uint256 decreaseAmount = repayAmount - borrowAmount;
            accountBorrows = accountBorrowsPrior > decreaseAmount ? accountBorrowsPrior - decreaseAmount : 0;
            borrowSnapshot.principal = safe112(accountBorrows);
            borrowSnapshot.interestIndex = accountBorrows == 0 ? 0 : _borrowIndex;
            
            uint256 actualDecreaseAmount = accountBorrowsPrior - accountBorrows;
            _totalBorrows = uint256(totalBorrows) > actualDecreaseAmount ? uint256(totalBorrows) - actualDecreaseAmount : 0;
            totalBorrows = safe112(_totalBorrows);
        }
        _trackBorrow(borrower, accountBorrows, _borrowIndex);
    }

    function borrow(address borrower, address receiver, uint256 borrowAmount, bytes calldata data) external nonReentrant update accrue {
        uint256 _totalBalance = totalBalance;
        if (borrowAmount > _totalBalance) revert InsufficientCash();
        _checkBorrowAllowance(borrower, msg.sender, borrowAmount);

        if (borrowAmount > 0) _safeTransfer(receiver, borrowAmount);
        if (data.length > 0) ITarotCallee(receiver).tarotBorrow(msg.sender, borrower, borrowAmount, data);
        
        uint256 balance = IERC20(underlying).balanceOf(address(this));
        uint256 borrowFee = (borrowAmount * BORROW_FEE) / 1e18;
        uint256 adjustedBorrowAmount = borrowAmount + borrowFee;
        uint256 repayAmount = balance + borrowAmount - _totalBalance;
        
        (uint256 accountBorrowsPrior, uint256 accountBorrows, uint256 _totalBorrows) = _updateBorrow(borrower, adjustedBorrowAmount, repayAmount);

        if (adjustedBorrowAmount > repayAmount) {
            if (!ICollateral(collateral).canBorrow(borrower, address(this), accountBorrows)) {
                revert InsufficientLiquidity();
            }
        }

        emit Borrow(msg.sender, borrower, receiver, borrowAmount, repayAmount, accountBorrowsPrior, accountBorrows, _totalBorrows);
    }

    function liquidate(address borrower, address liquidator) external nonReentrant update accrue returns (uint256 seizeTokens) {
        uint256 balance = IERC20(underlying).balanceOf(address(this));
        uint256 repayAmount = balance - totalBalance;
        uint256 actualRepayAmount = Math.min(borrowBalance(borrower), repayAmount);
        
        seizeTokens = ICollateral(collateral).seize(liquidator, borrower, actualRepayAmount);
        
        (uint256 accountBorrowsPrior, uint256 accountBorrows, uint256 _totalBorrows) = _updateBorrow(borrower, 0, repayAmount);

        emit Liquidate(msg.sender, borrower, liquidator, seizeTokens, repayAmount, accountBorrowsPrior, accountBorrows, _totalBorrows);
    }

    function trackBorrow(address borrower) external {
        _trackBorrow(borrower, borrowBalance(borrower), borrowIndex);
    }

    /*** Modifiers & Helpers ***/

    modifier accrue() {
        accrueInterest();
        _;
    }

    function _checkSetting(uint256 parameter, uint256 min, uint256 max) internal view {
        _checkAdmin();
        if (parameter < min || parameter > max) revert InvalidSetting();
    }

    function _checkAdmin() internal view {
        if (msg.sender != IFactory(factory).admin()) revert Unauthorized();
    }

    function safe112(uint256 n) internal pure override returns (uint112) {
        if (n >= 2**112) revert ValueTooLargeForUint112();
        return uint112(n);
    }

    function _safeTransfer(address to, uint256 amount) internal override {
        (bool success, bytes memory data) =
            underlying.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
            revert TransferFailed();
        }
    }
}