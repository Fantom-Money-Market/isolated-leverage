// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./interfaces/IThickV3Pool.sol";
import "./interfaces/IStratusThickVault.sol";
import "./StratusThickVaultDeployer.sol";

/// @title StratusThickVaultFactory
/// @notice Deploys and seeds StratusThickVaults and is the privileged (factory) caller for
///         each vault's admin (rebalance / fee). Thick CL pools have no gauge, so — unlike
///         the Shadow factory — there is no voter, gauge, or reward-token wiring here.
/// @dev Pool is resolved from (tokenA, tokenB, tickSpacing) via the Thick CL factory's
///      getPool, so no pool address needs to be known in advance.
contract StratusThickVaultFactory is Ownable {
    using SafeERC20 for IERC20;

    /// @notice Thick CL factory — resolves a pool from its token pair + tick spacing.
    address public immutable clFactory;

    /// @notice Dedicated deployer (holds StratusThickVault creation code).
    address public immutable vaultDeployer;

    /// @notice Seed shares are minted here — permanently-locked bootstrap liquidity.
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address[] public allVaults;
    mapping(address => address) public vaultForPool;

    /// @notice Tokens the factory may hold protocol-fee skims in (pair tokens across all
    ///         vaults) and can sweep out via claimRewards. Future-proof: owner adds new
    ///         tokens as new vaults appear; claimRewards never needs to change.
    address[] public claimableTokens;
    mapping(address => bool) public isClaimableToken;

    event VaultCreated(address indexed pool, address indexed vault, uint256 seedShares, int24 tickSpacing);
    event ClaimableTokenAdded(address indexed token);
    event ClaimableTokenRemoved(address indexed token);
    event RewardsClaimed(address indexed to, address[] tokens, uint256[] amounts);

    error ZeroAddress();
    error NoPool();
    error VaultExists();
    error SeedRequired();
    error AlreadyClaimable();
    error NotClaimable();

    constructor(address _clFactory) Ownable(msg.sender) {
        if (_clFactory == address(0)) revert ZeroAddress();
        clFactory = _clFactory;
        vaultDeployer = address(new StratusThickVaultDeployer());
    }

    function vaultCount() external view returns (uint256) {
        return allVaults.length;
    }

    /// @notice Create a vault for the Thick CL pool of (tokenA, tokenB, tickSpacing).
    function createVault(
        address tokenA,
        address tokenB,
        int24 tickSpacing,
        uint256 upwardBias,
        uint8 protocolFee,
        uint256 seed0,
        uint256 seed1
    ) external onlyOwner returns (address vault) {
        address pool = IThickV3Factory(clFactory).getPool(tokenA, tokenB, tickSpacing);
        if (pool == address(0)) revert NoPool();
        vault = _create(pool, tickSpacing, upwardBias, protocolFee, seed0, seed1);
    }

    function deployIdleVault(address vault) external onlyOwner {
        IStratusThickVault(vault).deployIdle();
    }

    /// @notice Emergency stop for one or more vaults in a single call (deposits/rebalance
    ///         halt; withdraw/claimRewards stay open on every vault regardless).
    function panicAtTheDisco(address[] calldata vaults) external onlyOwner {
        for (uint256 i = 0; i < vaults.length; i++) {
            IStratusThickVault(vaults[i]).panicAtTheDisco();
        }
    }

    function resumeVaults(address[] calldata vaults) external onlyOwner {
        for (uint256 i = 0; i < vaults.length; i++) {
            IStratusThickVault(vaults[i]).resume();
        }
    }

    function updateVaultProtocolFee(address vault, uint8 newFee) external onlyOwner {
        IStratusThickVault(vault).updateProtocolFee(newFee);
    }

    /// @notice Tune a vault's swap-rebalance economics (deviation cap, bounties, cooldown).
    function setVaultRebalanceParams(
        address vault,
        uint256 deviationCapBps,
        uint256 bountyBps,
        uint256 rewardBountyBps,
        uint256 minSkewBps
    ) external onlyOwner {
        IStratusThickVault(vault).setRebalanceParams(deviationCapBps, bountyBps, rewardBountyBps, minSkewBps);
    }

    // ===================== FEE / REWARD CLAIMS =====================

    /// @notice Register a token the factory should sweep on claimRewards (idempotent).
    function addClaimableToken(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (isClaimableToken[token]) revert AlreadyClaimable();
        isClaimableToken[token] = true;
        claimableTokens.push(token);
        emit ClaimableTokenAdded(token);
    }

    /// @notice Drop a token from the sweep list (does not affect any balance already held).
    function removeClaimableToken(address token) external onlyOwner {
        if (!isClaimableToken[token]) revert NotClaimable();
        isClaimableToken[token] = false;
        uint256 len = claimableTokens.length;
        for (uint256 i = 0; i < len; i++) {
            if (claimableTokens[i] == token) {
                claimableTokens[i] = claimableTokens[len - 1];
                claimableTokens.pop();
                break;
            }
        }
        emit ClaimableTokenRemoved(token);
    }

    function claimableTokensLength() external view returns (uint256) {
        return claimableTokens.length;
    }

    /// @notice Sweep every claimable token's current factory balance to `to`. Iterates the
    ///         whole array and sends whatever is sendable, skipping zero balances instead of
    ///         reverting, so adding a new reward token never requires touching this function.
    function claimRewards(address to)
        external
        onlyOwner
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        if (to == address(0)) revert ZeroAddress();
        uint256 len = claimableTokens.length;
        tokens = new address[](len);
        amounts = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            address token = claimableTokens[i];
            tokens[i] = token;
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal == 0) continue;
            amounts[i] = bal;
            IERC20(token).safeTransfer(to, bal);
        }
        emit RewardsClaimed(to, tokens, amounts);
    }

    function _create(
        address pool,
        int24 tickSpacing,
        uint256 upwardBias,
        uint8 protocolFee,
        uint256 seed0,
        uint256 seed1
    ) internal returns (address vault) {
        if (vaultForPool[pool] != address(0)) revert VaultExists();
        if (seed0 == 0 || seed1 == 0) revert SeedRequired();

        IERC20 t0 = IERC20(IThickV3Pool(pool).token0());
        IERC20 t1 = IERC20(IThickV3Pool(pool).token1());
        (string memory name, string memory symbol) = _names(address(t0), address(t1));

        vault = IStratusThickVaultDeployer(vaultDeployer).deploy(pool, upwardBias, protocolFee, name, symbol);
        vaultForPool[pool] = vault;
        allVaults.push(vault);

        t0.safeTransferFrom(msg.sender, address(this), seed0);
        t1.safeTransferFrom(msg.sender, address(this), seed1);
        t0.forceApprove(vault, seed0);
        t1.forceApprove(vault, seed1);

        // Seed shares to the dead address: permanently-locked bootstrap liquidity.
        // Inflation is handled by the vault's virtual shares, so there is no burn.
        uint256 seedShares = IStratusThickVault(vault).deposit(seed0, seed1, DEAD, 0);
        IStratusThickVault(vault).deployIdle();

        emit VaultCreated(pool, vault, seedShares, tickSpacing);
    }

    function _names(address t0, address t1) internal view returns (string memory name, string memory symbol) {
        string memory s0 = _symbol(t0);
        string memory s1 = _symbol(t1);
        name = string.concat("Stratus ALPT Thick ", s0, "-", s1);
        symbol = string.concat("sALPT-", s0, "-", s1);
    }

    function _symbol(address token) internal view returns (string memory) {
        try IERC20Metadata(token).symbol() returns (string memory s) {
            return s;
        } catch {
            return "?";
        }
    }
}
