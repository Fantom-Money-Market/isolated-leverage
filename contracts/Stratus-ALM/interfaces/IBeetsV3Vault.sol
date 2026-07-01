// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Beets v3 (= Balancer v3) Vault interface — Sonic
/// @notice Verified against balancer/balancer-v3-monorepo `pkg/interfaces/contracts/vault`
///         (IVaultMain, IVaultExtension, VaultTypes). Beets runs the canonical Balancer v3
///         Vault at 0xbA1333333333a1BA1108E8412f11850A5C319bA9 on Sonic.
/// @dev v3 is NOT v2: pools are addressed directly (no bytes32 poolId), the pool contract
///      IS the BPT (ERC20 tracked by the Vault), and liquidity moves through the Vault's
///      transient-accounting `unlock` callback (no joinPool/exitPool).

enum AddLiquidityKind {
    PROPORTIONAL,
    UNBALANCED,
    SINGLE_TOKEN_EXACT_OUT,
    DONATION,
    CUSTOM
}

enum RemoveLiquidityKind {
    PROPORTIONAL,
    SINGLE_TOKEN_EXACT_IN,
    SINGLE_TOKEN_EXACT_OUT,
    CUSTOM
}

enum TokenType {
    STANDARD,
    WITH_RATE
}

struct TokenInfo {
    TokenType tokenType;
    address rateProvider; // IRateProvider; address(0) for STANDARD tokens
    bool paysYieldFees;
}

struct AddLiquidityParams {
    address pool;
    address to;
    uint256[] maxAmountsIn;
    uint256 minBptAmountOut;
    AddLiquidityKind kind;
    bytes userData;
}

struct RemoveLiquidityParams {
    address pool;
    address from;
    uint256 maxBptAmountIn;
    uint256[] minAmountsOut;
    RemoveLiquidityKind kind;
    bytes userData;
}

interface IBeetsV3Vault {
    // ----- transient accounting (IVaultMain) -----

    /// @notice Open a Vault operation context. The Vault calls back `msg.sender` with `data`
    ///         as calldata; inside that callback the caller may add/remove liquidity and must
    ///         settle every token delta to zero before returning.
    function unlock(bytes calldata data) external returns (bytes memory result);

    /// @notice Pay a token debt: transfer the token to the Vault first, then call settle.
    function settle(IERC20 token, uint256 amountHint) external returns (uint256 credit);

    /// @notice Withdraw a credited token to `to`.
    function sendTo(IERC20 token, address to, uint256 amount) external;

    function addLiquidity(AddLiquidityParams memory params)
        external
        returns (uint256[] memory amountsIn, uint256 bptAmountOut, bytes memory returnData);

    function removeLiquidity(RemoveLiquidityParams memory params)
        external
        returns (uint256 bptAmountIn, uint256[] memory amountsOut, bytes memory returnData);

    // ----- views (IVaultExtension, via the Vault's fallback) -----

    function getPoolTokens(address pool) external view returns (IERC20[] memory tokens);

    /// @notice Per-token info incl. raw balances and the rate provider for WITH_RATE tokens.
    function getPoolTokenInfo(address pool)
        external
        view
        returns (
            IERC20[] memory tokens,
            TokenInfo[] memory tokenInfo,
            uint256[] memory balancesRaw,
            uint256[] memory lastBalancesLiveScaled18
        );

    /// @notice decimalScalingFactors (raw→18dec) and tokenRates (rate-provider rate, 1e18;
    ///         1e18 for STANDARD tokens). The basis for manipulation-resistant BPT valuation.
    function getPoolTokenRates(address pool)
        external
        view
        returns (uint256[] memory decimalScalingFactors, uint256[] memory tokenRates);

    /// @notice Rate-applied, 18-dec balances (invariant value building block).
    function getCurrentLiveBalances(address pool)
        external
        view
        returns (uint256[] memory balancesLiveScaled18);

    /// @notice BPT total supply (the pool token is managed by the Vault).
    function totalSupply(address token) external view returns (uint256);
}

/// @notice Balancer/Beets rate provider — yield-bearing token's exchange rate (1e18).
interface IRateProvider {
    function getRate() external view returns (uint256);
}
