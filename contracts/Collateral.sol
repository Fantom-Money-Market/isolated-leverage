// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "./PoolToken.sol";
import "./interfaces/IBorrowable.sol";
import "./interfaces/ICollateral.sol";
import "./interfaces/IFactory.sol";
import "./interfaces/ITarotCallee.sol";
import "./interfaces/IStratusALPT.sol";

/// @notice Reward surface of a Stratus vault (StratusVaultBase). The Beets adapter and
///         other non-emitting underlyings don't implement it — harvest no-ops via try/catch.
interface IStratusVaultRewards {
    function rewardTokensList() external view returns (address[] memory);
    function claimRewards() external;
}

contract Collateral is ICollateral, PoolToken {
    // --- Custom Errors ---
    error PriceCalculationError();
    error InvalidBorrowable();
    error InsufficientShortfall();
    error LiquidatingTooMuch();
    error InsufficientRedeemTokens();
    // MintAmountTooSmall is inherited from PoolToken (same guard, same base pattern).

    address public borrowable0;
    address public borrowable1;

    // --- Vault reward redistribution (MasterChef-style accumulator over cToken balances) ---
    // This contract holds the ALPT, so vault emissions accrue here. harvestVaultRewards
    // claims them and credits cToken holders pro-rata in-kind. Checkpoints settle on every
    // balance change (mint/redeem/transfer/seize). Denominator is floored with
    // +MINIMUM_LIQUIDITY; accrual uses Math.mulDiv so extreme accumulators cannot overflow
    // on settle (including inside seize()).
    uint256 internal constant REWARD_ACC_PRECISION = 1e18;
    address[] public vaultRewardTokens;
    mapping(address => bool) public isVaultRewardToken;
    mapping(address => uint256) public rewardPerShareStored;
    mapping(address => mapping(address => uint256)) public userRewardPerSharePaid;
    mapping(address => mapping(address => uint256)) public rewardsAccrued;

    event VaultRewardsHarvested(address indexed token, uint256 amount);
    event VaultRewardClaimed(address indexed user, address indexed token, uint256 amount);
    
    // --- Collateral Parameters ---
    uint256 public safetyMarginSqrt = 1414213562373095049; // sqrt(2) * 1e18 ≈ 141.42% safety margin
    uint256 public liquidationIncentive = 1050000000000000000; // 105% liquidation incentive

    // --- Constants ---
    uint256 public constant SAFETY_MARGIN_SQRT_MIN = 1e18; // safetyMargin: 100%
    uint256 public constant SAFETY_MARGIN_SQRT_MAX = 1581138840000000000; // safetyMargin: 250%
    uint256 public constant LIQUIDATION_INCENTIVE_MIN = 1e18; // 100%
    uint256 public constant LIQUIDATION_INCENTIVE_MAX = 1050000000000000000; // 105%

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
            // Lock MINIMUM_LIQUIDITY forever. Dust below that floor reverts MintAmountTooSmall.
            if (mintTokens <= MINIMUM_LIQUIDITY) revert MintAmountTooSmall();
            mintTokens -= MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY);
        }
        if (mintTokens == 0) revert MintAmountZero();
        _settleVaultRewards(minter); // checkpoint before balance increases
        _mint(minter, mintTokens);
        emit Mint(msg.sender, minter, mintAmount, mintTokens); 
    }

    function redeem(address redeemer) external override(PoolToken, ICollateral) nonReentrant update returns (uint256 redeemAmount) {
        uint256 redeemTokens = balanceOf[address(this)];
        redeemAmount = (redeemTokens * exchangeRate()) / 1e18;

        if (redeemAmount == 0) revert RedeemAmountZero();
        if (redeemAmount > totalBalance) revert InsufficientCash();
        _settleVaultRewards(address(this)); // checkpoint before balance decreases
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

    /// @notice Collateral price of one underlying (LP/ALPT/adapter) token in each
    ///         borrowable token. Sourced from the underlying's safe surface
    ///         (getTotalValueSafe / twapPrice) — no spot slot0 read.
    /// @dev price_i is "collateral tokens per token_i" (1e18-scaled), i.e.
    ///      supply / value_in_token_i, as _calculateLiquidity and seize expect.
    ///      Uses the real safe NAV, so weighted/stable pools price correctly.
    function getPrices() public view returns (uint256 price0, uint256 price1) {
        uint256 supply = IStratusALPT(underlying).totalSupply();
        uint256 valueInToken1 = IStratusALPT(underlying).getTotalValueSafe(); // token1 base units
        uint256 priceToken0In1 = IStratusALPT(underlying).twapPrice();        // token0 in token1, 1e18

        if (supply == 0 || valueInToken1 == 0 || priceToken0In1 == 0) revert PriceCalculationError();

        // Whole-position value expressed in token0 base units. Guard the rounded result
        // before it becomes a divisor: a tiny position + large priceToken0In1 can round
        // valueInToken0 to zero, which would revert-by-panic on the division below.
        uint256 valueInToken0 = (valueInToken1 * 1e18) / priceToken0In1;
        if (valueInToken0 == 0) revert PriceCalculationError();

        price0 = (supply * 1e18) / valueInToken0;
        price1 = (supply * 1e18) / valueInToken1;

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

    /*** Vault Reward Redistribution ***/

    /// @notice Claim the underlying vault's accrued rewards (e.g. gauge emissions)
    ///         to this contract and credit them to the accumulator. Permissionless — also
    ///         invoked from claimVaultRewards so a claim is always up to date.
    /// @dev No-ops when the underlying has no reward surface or supply is zero.
    ///      rewardTokensList() is try/caught (optional interface); claimRewards() is not —
    ///      a fund-moving step should revert on genuine failure rather than report success
    ///      while transferring nothing (and so that gas estimators do not underprice it).
    function harvestVaultRewards() public {
        uint256 supply = totalSupply;
        if (supply == 0) return;

        address[] memory tokens;
        try IStratusVaultRewards(underlying).rewardTokensList() returns (address[] memory t) {
            tokens = t;
        } catch {
            return; // underlying has no reward surface
        }
        if (tokens.length == 0) return;

        uint256[] memory balBefore = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            balBefore[i] = IERC20(tokens[i]).balanceOf(address(this));
        }

        IStratusVaultRewards(underlying).claimRewards();

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 received = IERC20(token).balanceOf(address(this)) - balBefore[i];
            if (received == 0) continue;
            if (!isVaultRewardToken[token]) {
                isVaultRewardToken[token] = true;
                vaultRewardTokens.push(token);
            }
            // Floor the denominator with MINIMUM_LIQUIDITY so a harvest at near-zero
            // real supply cannot inflate rewardPerShareStored unboundedly.
            rewardPerShareStored[token] += Math.mulDiv(received, REWARD_ACC_PRECISION, supply + MINIMUM_LIQUIDITY);
            emit VaultRewardsHarvested(token, received);
        }
    }

    /// @notice Pay out the caller's accrued share of every vault reward token, in-kind.
    function claimVaultRewards()
        external
        nonReentrant
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        harvestVaultRewards();
        _settleVaultRewards(msg.sender);

        tokens = vaultRewardTokens;
        amounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 amount = rewardsAccrued[token][msg.sender];
            if (amount == 0) continue;
            rewardsAccrued[token][msg.sender] = 0;
            amounts[i] = amount;
            _safeTokenTransfer(token, msg.sender, amount);
            emit VaultRewardClaimed(msg.sender, token, amount);
        }
    }

    /// @notice Claimable reward for a holder/token, including not-yet-settled accrual.
    ///         (Excludes rewards the vault has earned but this contract hasn't harvested.)
    function pendingVaultReward(address user, address token) external view returns (uint256) {
        uint256 unsettled = Math.mulDiv(
            balanceOf[user],
            rewardPerShareStored[token] - userRewardPerSharePaid[token][user],
            REWARD_ACC_PRECISION
        );
        return rewardsAccrued[token][user] + unsettled;
    }

    /// @notice The reward tokens discovered from the underlying vault so far.
    function vaultRewardTokensList() external view returns (address[] memory) {
        return vaultRewardTokens;
    }

    /// @dev Checkpoint a holder against the accumulator. MUST run before any change to
    ///      their cToken balance (mint/burn/transfer/seize) so accrual stays fair.
    function _settleVaultRewards(address user) internal {
        if (user == address(0)) return;
        uint256 bal = balanceOf[user];
        uint256 len = vaultRewardTokens.length;
        for (uint256 i = 0; i < len; i++) {
            address token = vaultRewardTokens[i];
            uint256 acc = rewardPerShareStored[token];
            uint256 paid = userRewardPerSharePaid[token][user];
            if (acc != paid) {
                if (bal > 0) rewardsAccrued[token][user] += Math.mulDiv(bal, acc - paid, REWARD_ACC_PRECISION);
                userRewardPerSharePaid[token][user] = acc;
            }
        }
    }

    /// @dev Generic ERC20 transfer for reward tokens (underlying uses _safeTransfer).
    function _safeTokenTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
            revert TransferFailed();
        }
    }

    /*** ERC20 ***/

    function _transfer(
        address from,
        address to,
        uint256 value
    ) internal override {
        if (!tokensUnlocked(from, value)) revert InsufficientLiquidity();
        _settleVaultRewards(from);
        _settleVaultRewards(to);
        super._transfer(from, to, value);
    }

    /// @dev borrowBalance() reflects each Borrowable's last-accrued index. Accrue both
    ///      legs before any solvency check so two-sided positions are not understated.
    ///      accrueInterest() is permissionless and no-ops if already accrued this timestamp.
    function _accrueBothBorrowables() internal {
        IBorrowable(borrowable0).accrueInterest();
        IBorrowable(borrowable1).accrueInterest();
    }

    function tokensUnlocked(address from, uint256 value) public returns (bool) {
        uint256 _balance = balanceOf[from];
        if (value > _balance) return false;
        uint256 finalBalance = _balance - value;
        uint256 amountCollateral = (finalBalance * exchangeRate()) / 1e18;
        _accrueBothBorrowables();
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
        // Refresh both markets before reading either leg — see _accrueBothBorrowables.
        // Covers canBorrow() (whose non-invoked leg would otherwise be stale) and seize().
        if (amount0 == type(uint256).max || amount1 == type(uint256).max) {
            _accrueBothBorrowables();
        }
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
        // Checkpoint both parties before the raw balance move (this path bypasses
        // _transfer): the borrower keeps rewards accrued up to this block, the
        // liquidator earns on the seized balance from here on.
        _settleVaultRewards(borrower);
        _settleVaultRewards(liquidator);
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

        _settleVaultRewards(address(this)); // checkpoint before balance decreases
        _burn(address(this), redeemTokens);
        emit Redeem(msg.sender, redeemer, redeemAmount, redeemTokens);
    }
}