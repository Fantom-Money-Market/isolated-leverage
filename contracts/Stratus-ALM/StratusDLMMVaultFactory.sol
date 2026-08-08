// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./interfaces/ILBPair.sol";
import "./interfaces/IStratusDLMMVault.sol";
import "./StratusDLMMVaultDeployer.sol";

/// @title StratusDLMMVaultFactory
/// @notice Deploys and seeds StratusDLMMVaults, and is the privileged (factory) caller
///         for each vault's admin (rebalance / reward tokens / fee). Mirrors
///         StratusShadowVaultFactory.sol's shape; resolves the LB pair from the
///         Metropolis LBFactory instead of a Shadow voter/gauge lookup.
/// @dev Vault bytecode lives in StratusDLMMVaultDeployer, not here — see EIP-170.
contract StratusDLMMVaultFactory is Ownable {
    using SafeERC20 for IERC20;

    /// @notice Oracle ring-buffer length requested on a pair at vault creation, so it can
    ///         serve the 30-minute TWAP the vault's safe price requires. Set here rather
    ///         than in the vault because the oracle must be switched on BEFORE the vault
    ///         exists (history only accrues once active) — and because moving this out of
    ///         the vault constructor kept StratusDLMMVaultDeployer under the EIP-170 limit.
    uint16 public constant DESIRED_ORACLE_LENGTH = 20;

    /// @notice Metropolis LBFactory — resolves a pair address from (tokenA, tokenB, binStep).
    address public immutable lbFactory;

    /// @notice Dedicated deployer (holds StratusDLMMVault creation code).
    address public immutable vaultDeployer;

    /// @notice Seed shares are minted here — permanently-locked bootstrap liquidity.
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @notice Reward token new vaults distribute (e.g. METRO). Owner-settable; may be 0.
    address public rewardToken;

    address[] public allVaults;
    mapping(address => address) public vaultForPair;

    /// @notice Tokens the factory may hold protocol-fee skims in (pair tokens across all
    ///         vaults, plus hook reward tokens like METRO) and can sweep out via
    ///         claimRewards. Future-proof: owner adds new tokens as new vaults/reward types
    ///         appear; claimRewards never needs to change.
    address[] public claimableTokens;
    mapping(address => bool) public isClaimableToken;

    event VaultCreated(address indexed pair, address indexed vault, uint256 seedShares, address hook);
    event ClaimableTokenAdded(address indexed token);
    event ClaimableTokenRemoved(address indexed token);
    event RewardsClaimed(address indexed to, address[] tokens, uint256[] amounts);

    error ZeroAddress();
    error NoPair();
    error VaultExists();
    error SeedRequired();
    error AlreadyClaimable();
    error NotClaimable();

    constructor(address _lbFactory, address _rewardToken) Ownable(msg.sender) {
        if (_lbFactory == address(0)) revert ZeroAddress();
        lbFactory = _lbFactory;
        rewardToken = _rewardToken; // 0 = no rewards distributed until configured
        vaultDeployer = address(new StratusDLMMVaultDeployer());
    }

    function vaultCount() external view returns (uint256) {
        return allVaults.length;
    }

    /// @notice Create a vault for the Metropolis DLMM pair of (tokenA, tokenB, binStep).
    function createVault(
        address tokenA,
        address tokenB,
        uint16 binStep,
        uint256 upwardBias,
        uint8 protocolFee,
        uint256 seed0,
        uint256 seed1
    ) external onlyOwner returns (address vault) {
        address pairAddr = _resolvePair(tokenA, tokenB, binStep);

        // Activate/extend the pair's oracle BEFORE the vault exists, so the market has a
        // shot at a real TWAP. The vault's safe price fails closed (StratusDLMMVaultBase
        // .UnsafePrice) rather than falling back to the swap-movable active bin, so a pair
        // whose oracle was never switched on would be permanently unpriceable — and the
        // history only starts accumulating once it is on. increaseOracleLength is
        // permissionless and flips the oracle on when unused, but REVERTS if asked to
        // shrink, hence the size check. Not wrapped in try/catch on purpose: failing here,
        // loudly, beats shipping a market that can never price its collateral.
        (, uint16 oracleSize, , , ) = ILBPair(pairAddr).getOracleParameters();
        if (oracleSize < DESIRED_ORACLE_LENGTH) {
            ILBPair(pairAddr).increaseOracleLength(DESIRED_ORACLE_LENGTH);
        }

        vault = _create(pairAddr, upwardBias, protocolFee, seed0, seed1);
    }

    function deployIdleVault(address vault) external onlyOwner {
        IStratusDLMMVault(vault).deployIdle();
    }

    /// @notice Emergency stop for one or more vaults in a single call (deposits/rebalance
    ///         halt; withdraw/claimRewards stay open on every vault regardless).
    function panicAtTheDisco(address[] calldata vaults) external onlyOwner {
        for (uint256 i = 0; i < vaults.length; i++) {
            IStratusDLMMVault(vaults[i]).panicAtTheDisco();
        }
    }

    function resumeVaults(address[] calldata vaults) external onlyOwner {
        for (uint256 i = 0; i < vaults.length; i++) {
            IStratusDLMMVault(vaults[i]).resume();
        }
    }

    function updateVaultProtocolFee(address vault, uint8 newFee) external onlyOwner {
        IStratusDLMMVault(vault).updateProtocolFee(newFee);
    }

    /// @notice Set the METRO cut (bps) paid to permissionless rebalancers on a vault.
    function setVaultRewardBountyBps(address vault, uint256 rewardBountyBps) external onlyOwner {
        IStratusDLMMVault(vault).setRewardBountyBps(rewardBountyBps);
    }

    /// @notice Set the default reward token for future vaults.
    function setDefaultRewardToken(address token) external onlyOwner {
        rewardToken = token;
    }

    /// @notice Override the reward-token set on a specific vault.
    function setVaultRewardTokens(address vault, address[] calldata tokens) external onlyOwner {
        IStratusDLMMVault(vault).setRewardTokens(tokens);
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

    function _resolvePair(address tokenA, address tokenB, uint16 binStep) internal view returns (address pairAddr) {
        ILBFactory.LBPairInformation[] memory pairs = ILBFactory(lbFactory).getAllLBPairs(tokenA, tokenB);
        for (uint256 i = 0; i < pairs.length; i++) {
            if (pairs[i].binStep == binStep) return pairs[i].LBPair;
        }
        revert NoPair();
    }

    function _create(address pairAddr, uint256 upwardBias, uint8 protocolFee, uint256 seed0, uint256 seed1)
        internal
        returns (address vault)
    {
        if (vaultForPair[pairAddr] != address(0)) revert VaultExists();
        if (seed0 == 0 || seed1 == 0) revert SeedRequired();

        IERC20 tX = IERC20(ILBPair(pairAddr).getTokenX());
        IERC20 tY = IERC20(ILBPair(pairAddr).getTokenY());
        (string memory name, string memory symbol) = _names(address(tX), address(tY));

        vault = IStratusDLMMVaultDeployer(vaultDeployer).deploy(pairAddr, upwardBias, protocolFee, name, symbol);
        vaultForPair[pairAddr] = vault;
        allVaults.push(vault);

        tX.safeTransferFrom(msg.sender, address(this), seed0);
        tY.safeTransferFrom(msg.sender, address(this), seed1);
        tX.forceApprove(vault, seed0);
        tY.forceApprove(vault, seed1);

        // Mint the seed shares straight to the dead address: permanently-locked bootstrap
        // liquidity. Inflation is handled by the vault's virtual shares, so there is no burn.
        uint256 seedShares = IStratusDLMMVault(vault).deposit(seed0, seed1, DEAD, 0);
        IStratusDLMMVault(vault).deployIdle();

        if (rewardToken != address(0)) {
            address[] memory rts = new address[](1);
            rts[0] = rewardToken;
            IStratusDLMMVault(vault).setRewardTokens(rts); // distribute just METRO by default
        }

        emit VaultCreated(pairAddr, vault, seedShares, IStratusDLMMVault(vault).hook());
    }

    function _names(address t0, address t1) internal view returns (string memory name, string memory symbol) {
        string memory s0 = _symbol(t0);
        string memory s1 = _symbol(t1);
        name = string.concat("Stratus ALPT ", s0, "-", s1);
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
