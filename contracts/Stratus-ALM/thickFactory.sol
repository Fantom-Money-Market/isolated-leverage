// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IThickVault.sol";
import "./interfaces/IUniswapV3Pool.sol";
import "./interfaces/IPausableVault.sol";
import "./thickVolatileVault.sol";
import "./thickStableVault.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IThickFactory {
    function getPool(
        address tokenA,
        address tokenB,
        int24 tickSpacing
    ) external view returns (address pool);
}

/// @title ThickLiquidityVaultFactory
/// @notice Factory for deploying and tracking ThickLiquidityVaults
contract ThickLiquidityVaultFactory is Pausable, Ownable {
    using SafeERC20 for IERC20;

    // Custom Errors
    error ZeroAddress();
    error InvalidTokens();
    error VaultExists();
    error VaultNotFound();
    error TokenNotFound();

    // Immutable references
    address public immutable thickFactory;
    address public immutable positionManager;
    address public immutable swapRouter;

    // Vault tracking
    mapping(address => mapping(address => address)) public getVault;
    address[] public allVaults;
    uint256 public vaultCount;

    event VaultCreated(
        address indexed token0,
        address indexed token1,
        address vault,
        uint256 vaultId,
        bool isStable
    );

    constructor(
        address _thickFactory,
        address _positionManager,
        address _swapRouter
    ) Ownable(msg.sender) {
        if (_thickFactory == address(0) || 
            _positionManager == address(0) || 
            _swapRouter == address(0)) revert ZeroAddress();
        
        thickFactory = _thickFactory;
        positionManager = _positionManager;
        swapRouter = _swapRouter;
    }

    /// @notice Creates a new vault if one doesn't exist for the given tokens.
    /// @dev This function requires a small initial deposit that is transferred to the vault
    /// @dev to prevent inflation attacks. The factory will perform the initial deposit
    /// @dev and burn the resulting shares, making the initial liquidity permanent.
    /// @dev Use a small, non-zero amount for the initial deposit.
    /// @param tokenA First token of the pair.
    /// @param tokenB Second token of the pair.
    /// @param isStable Whether to create a stable or volatile vault.
    /// @param amount0Initial The initial amount of token0 to seed the vault with.
    /// @param amount1Initial The initial amount of token1 to seed the vault with.
    /// @return vault Address of the created vault.
    function createVault(
        address tokenA,
        address tokenB,
        bool isStable,
        uint256 amount0Initial,
        uint256 amount1Initial
    ) external whenNotPaused returns (address vault) {
        if (tokenA == tokenB) revert InvalidTokens();

        // Sort tokens
        (address token0, address token1) = tokenA < tokenB 
            ? (tokenA, tokenB) 
            : (tokenB, tokenA);

        // Check if vault already exists
        vault = getVault[token0][token1];
        if (vault != address(0)) revert VaultExists();

        // Transfer initial liquidity from the caller to this factory
        if (amount0Initial > 0) {
            IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0Initial);
        }
        if (amount1Initial > 0) {
            IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1Initial);
        }



        // Get pool from Thick factory - always use tick spacing 1
        address pool = IThickFactory(thickFactory).getPool(token0, token1, 1);
        if (pool == address(0)) revert VaultNotFound();

        // Generate vault name and symbol
        string memory symbol0 = IERC20Metadata(token0).symbol();
        string memory symbol1 = IERC20Metadata(token1).symbol();
        string memory name = string(abi.encodePacked(
            "Thick Liquidity - ",
            symbol0,
            "/",
            symbol1,
            isStable ? " Stable Vault" : " Volatile Vault"
        ));
        string memory symbol = string(abi.encodePacked("TLV-", symbol0, "-", symbol1));

        // Deploy appropriate vault type
        if (isStable) {
            vault = address(new ThickStableVault(
                pool,
                positionManager,
                swapRouter,
                name,
                symbol,
                5  // Default protocol fee (5%)
            ));
        } else {
            vault = address(new ThickVolatileVault(
                pool,
                positionManager,
                swapRouter,
                name,
                symbol,
                100  // Default upward bias
            ));
        }

        // Record vault
        getVault[token0][token1] = vault;
        getVault[token1][token0] = vault; // Record in reverse for easy lookup
        allVaults.push(vault);
        vaultCount = allVaults.length;

        // Approve the new vault to spend the factory's tokens for the initial deposit
        if (amount0Initial > 0) {
            IERC20(token0).approve(vault, amount0Initial);
        }
        if (amount1Initial > 0) {
            IERC20(token1).approve(vault, amount1Initial);
        }

        // The factory is the first depositor, then burns the shares to lock initial liquidity
        // This sets the initial share price and prevents inflation attacks
        uint256 shares = IThickVault(vault).deposit(amount0Initial, amount1Initial, 0, 0);
        if (shares > 0) {
            IThickVault(vault).transfer(address(0), shares); // Burn the shares
        }

        emit VaultCreated(token0, token1, vault, vaultCount - 1, isStable);
    }

    /// @notice Returns all deployed vaults
    function getAllVaults() external view returns (address[] memory) {
        return allVaults;
    }

    

    /// @notice Returns vault address if it exists, address(0) if not
    function findVault(
        address tokenA,
        address tokenB
    ) external view returns (address vault) {
        (address token0, address token1) = tokenA < tokenB 
            ? (tokenA, tokenB) 
            : (tokenB, tokenA);
        return getVault[token0][token1];
    }

    /// @notice Check if a vault exists for given tokens
    function vaultExists(
        address tokenA,
        address tokenB
    ) external view returns (bool) {
        (address token0, address token1) = tokenA < tokenB 
            ? (tokenA, tokenB) 
            : (tokenB, tokenA);
        return getVault[token0][token1] != address(0);
    }

    /// @notice Get all unique fee tokens from vaults
    function getFeeTokens() public view returns (address[] memory tokens) {
        // First create a dynamic array to collect all tokens
        address[] memory allTokens = new address[](allVaults.length * 2);
        uint256 totalTokens = 0;
        
        // Collect all tokens from vaults
        for (uint i = 0; i < allVaults.length; i++) {
            address vault = allVaults[i];
            address pool = IThickVault(vault).pool();
            allTokens[totalTokens++] = IUniswapV3Pool(pool).token0();
            allTokens[totalTokens++] = IUniswapV3Pool(pool).token1();
        }
        
        // Count unique tokens
        uint256 uniqueCount = 0;
        for (uint i = 0; i < totalTokens; i++) {
            bool isDuplicate = false;
            for (uint j = 0; j < i; j++) {
                if (allTokens[j] == allTokens[i]) {
                    isDuplicate = true;
                    break;
                }
            }
            if (!isDuplicate) {
                uniqueCount++;
            }
        }
        
        // Create result array with unique tokens
        tokens = new address[](uniqueCount);
        uint256 resultIndex = 0;
        
        for (uint i = 0; i < totalTokens; i++) {
            bool isDuplicate = false;
            for (uint j = 0; j < resultIndex; j++) {
                if (tokens[j] == allTokens[i]) {
                    isDuplicate = true;
                    break;
                }
            }
            if (!isDuplicate) {
                tokens[resultIndex++] = allTokens[i];
            }
        }
    }

    function getFeeTokenBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    // --- Admin Functions ---

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function pauseVault(address _vault) external onlyOwner {
        IPausableVault(_vault).pause();
    }

    function unpauseVault(address _vault) external onlyOwner {
        IPausableVault(_vault).unpause();
    }
}