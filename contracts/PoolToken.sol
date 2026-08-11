// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./TarotERC20.sol";
import "./interfaces/IPoolToken.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PoolToken is IPoolToken, TarotERC20 {
    // --- Custom Errors ---
    error FactoryAlreadySet();
    error MintAmountZero();
    error MintAmountTooSmall();
    error RedeemAmountZero();
    error InsufficientCash();
    error TransferFailed();
    error Reentered();
    error Unauthorized();
    error InvalidSetting();
    error InsufficientLiquidity();

    // --- Constants ---
    uint256 internal constant INITIAL_EXCHANGE_RATE = 1e18;
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    // --- State Variables ---
    address public underlying;
    address public factory;
    uint256 public totalBalance;

    // --- Events ---
    // Events are inherited from IPoolToken interface

    /*** Initialize ***/

    // called once by the factory
    function _setFactory() external virtual {
        if (factory != address(0)) revert FactoryAlreadySet();
        factory = msg.sender;
    }

    /*** PoolToken ***/

    function _update() internal virtual {
        totalBalance = IERC20(underlying).balanceOf(address(this));
        emit Sync(totalBalance);
    }

    function exchangeRate() public virtual returns (uint256) {
        uint256 _totalSupply = totalSupply;
        uint256 _totalBalance = totalBalance;
        if (_totalSupply == 0 || _totalBalance == 0) return INITIAL_EXCHANGE_RATE;
        return (_totalBalance * 1e18) / _totalSupply;
    }

    // this low-level function should be called from another contract
    function mint(address minter)
        external
        virtual
        nonReentrant
        update
        returns (uint256 mintTokens)
    {
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
        _mint(minter, mintTokens);
        emit Mint(msg.sender, minter, mintAmount, mintTokens);
    }

    // this low-level function should be called from another contract
    function redeem(address redeemer)
        external
        virtual
        nonReentrant
        update
        returns (uint256 redeemAmount)
    {
        uint256 redeemTokens = balanceOf[address(this)];
        redeemAmount = (redeemTokens * exchangeRate()) / 1e18;

        if (redeemAmount == 0) revert RedeemAmountZero();
        if (redeemAmount > totalBalance) revert InsufficientCash();
        _burn(address(this), redeemTokens);
        _safeTransfer(redeemer, redeemAmount);
        emit Redeem(msg.sender, redeemer, redeemAmount, redeemTokens);
    }

    // force real balance to match totalBalance
    function skim(address to) external nonReentrant {
        _safeTransfer(
            to,
            IERC20(underlying).balanceOf(address(this)) - totalBalance
        );
    }

    // force totalBalance to match real balance
    function sync() external virtual nonReentrant update {}

    /*** Utilities ***/

    function _safeTransfer(address to, uint256 amount) internal virtual {
        (bool success, bytes memory data) =
            underlying.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
            revert TransferFailed();
        }
    }

    // prevents a contract from calling itself, directly or indirectly.
    bool internal _notEntered = true;
    modifier nonReentrant() {
        if (!_notEntered) revert Reentered();
        _notEntered = false;
        _;
        _notEntered = true;
    }

    // update totalBalance with current balance
    modifier update() {
        _;
        _update();
    }
}
