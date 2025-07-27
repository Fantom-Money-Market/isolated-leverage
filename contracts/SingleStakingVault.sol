// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IFactory.sol";
import "./interfaces/IBorrowable.sol";
import "./interfaces/ILendingStrategy.sol";
import "./LendingPoolStruct.sol";

contract SingleStakingVault is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Custom Errors ---
    error ZeroAddress();
    error InvalidAmount();
    error InsufficientLiquidity();

    // --- State Variables ---
    IERC20 public immutable underlying;
    IFactory public immutable factory;
    ILendingStrategy public strategy;
    mapping(address => uint256) public investedAmount;

    // --- Events ---
    event Deposit(address indexed user, uint256 amount, uint256 shares);
    event Withdraw(address indexed user, uint256 amount, uint256 shares);
    event StrategyChanged(address indexed newStrategy);
    event Rebalanced(uint256 totalInvested);

    constructor(
        address _underlying,
        address _factory,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) {
        if (_underlying == address(0) || _factory == address(0)) revert ZeroAddress();
        underlying = IERC20(_underlying);
        factory = IFactory(_factory);
    }

    // --- Core Functions ---

    function deposit(uint256 amount) external nonReentrant returns (uint256 shares) {
        if (amount == 0) revert InvalidAmount();

        uint256 totalAssets = totalValue();
        shares = (totalSupply() == 0) ? amount : (amount * totalSupply()) / totalAssets;
        if (shares == 0) revert InvalidAmount();

        _mint(msg.sender, shares);
        underlying.safeTransferFrom(msg.sender, address(this), amount);

        emit Deposit(msg.sender, amount, shares);
    }

    function withdraw(uint256 shares) external nonReentrant returns (uint256 amount) {
        if (shares == 0) revert InvalidAmount();

        uint256 totalAssets = totalValue();
        amount = (shares * totalAssets) / totalSupply();
        if (amount == 0) revert InvalidAmount();

        _burn(msg.sender, shares);

        if (underlying.balanceOf(address(this)) < amount) {
            uint256 deficit = amount - underlying.balanceOf(address(this));
            _withdrawFromPools(deficit);
        }
        
        if (underlying.balanceOf(address(this)) < amount) revert InsufficientLiquidity();

        underlying.safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount, shares);
    }

    // --- Admin & Strategy Functions ---

    function setStrategy(address _strategy) external {
        // require(msg.sender == factory.admin(), "Only admin can set strategy");
        if (_strategy == address(0)) revert ZeroAddress();
        strategy = ILendingStrategy(_strategy);
        emit StrategyChanged(_strategy);
    }

    function rebalance() external nonReentrant {
        // require(msg.sender == factory.admin(), "Only admin can rebalance");
        if (address(strategy) == address(0)) return;

        uint256 idleAssets = underlying.balanceOf(address(this));
        if (idleAssets == 0) return;

        (address[] memory pools, uint256[] memory amounts) = strategy.getDistribution(idleAssets);

        uint256 totalToInvest = 0;
        for (uint i = 0; i < pools.length; i++) {
            if (amounts[i] > 0) {
                underlying.approve(pools[i], amounts[i]);
                IBorrowable(pools[i]).mint(address(this));
                investedAmount[pools[i]] += amounts[i];
                totalToInvest += amounts[i];
            }
        }
        emit Rebalanced(totalToInvest);
    }

    // --- View Functions ---

    function totalValue() public returns (uint256) {
        uint256 total = underlying.balanceOf(address(this));
        uint256 poolCount = factory.allLendingPoolsLength();
        for (uint i = 0; i < poolCount; i++) {
            address poolAddress = factory.allLendingPools(i);
            LendingPool memory lendingPool = factory.getLendingPool(poolAddress);
            if (investedAmount[lendingPool.borrowable0] > 0) {
                total += IERC20(lendingPool.borrowable0).balanceOf(address(this)) * IBorrowable(lendingPool.borrowable0).exchangeRate() / 1e18;
            }
            if (investedAmount[lendingPool.borrowable1] > 0) {
                total += IERC20(lendingPool.borrowable1).balanceOf(address(this)) * IBorrowable(lendingPool.borrowable1).exchangeRate() / 1e18;
            }
        }
        return total;
    }

    // --- Internal Functions ---

    function _withdrawFromPools(uint256 amount) internal {
        uint256 withdrawn = 0;
        uint256 poolCount = factory.allLendingPoolsLength();

        // This is a simplified withdrawal strategy. A more advanced strategy
        // would be more selective about which pools to withdraw from.
        for (uint i = 0; i < poolCount && withdrawn < amount; i++) {
            address poolAddress = factory.allLendingPools(i);
            LendingPool memory lendingPool = factory.getLendingPool(poolAddress);
            
            address borrowableAddress = lendingPool.borrowable0; // Simplified
            uint256 invested = investedAmount[borrowableAddress];

            if (invested > 0) {
                uint256 toWithdraw = (amount - withdrawn) > invested ? invested : (amount - withdrawn);
                uint256 sharesToRedeem = toWithdraw * 1e18 / IBorrowable(borrowableAddress).exchangeRate();
                
                // First transfer the shares to the borrowable contract
                IERC20(borrowableAddress).transfer(borrowableAddress, sharesToRedeem);
                
                // Then call redeem with this contract's address as the recipient
                IBorrowable(borrowableAddress).redeem(address(this));
                withdrawn += toWithdraw;
                investedAmount[borrowableAddress] -= toWithdraw;
            }
        }
    }
}