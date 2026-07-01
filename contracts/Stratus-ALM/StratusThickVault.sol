// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./base/StratusCLVaultBase.sol";
import "./interfaces/IThickV3Pool.sol";

/// @title StratusThickVault
/// @notice Fungible ERC20 (ALPT) wrapper around a Thick (Equalizer "Thickv2") CL position.
///         Thick is a faithful Uniswap V3 fork with NO gauge, so value accrues purely from
///         swap fees, which `_realizeFees` (in the CL base) skims and leaves as idle balance
///         to be compounded back into the ranges on the next rebalance. No reward tokens are
///         ever registered — the reward accumulator simply stays empty.
/// @dev All share accounting, valuation, rebalancing and fee realization are inherited
///      unchanged from StratusCLVaultBase / StratusVaultBase. This adapter supplies only the
///      vanilla-V3 pool ops (no `index`) and the matching position key.
contract StratusThickVault is StratusCLVaultBase {
    constructor(
        address _factory,
        address _pool,
        uint256 _upwardBias,
        uint8 _protocolFee,
        string memory _name,
        string memory _symbol
    ) StratusCLVaultBase(_factory, _pool, _upwardBias, _protocolFee, _name, _symbol) {}

    // ===================== FORK OPS (vanilla Uniswap V3: no index) =====================

    function _clPosition(int24 tickLower, int24 tickUpper)
        internal
        view
        override
        returns (uint128 liquidity, uint128 tokensOwed0, uint128 tokensOwed1)
    {
        bytes32 key = keccak256(abi.encodePacked(address(this), tickLower, tickUpper));
        (liquidity, , , tokensOwed0, tokensOwed1) = IThickV3Pool(pool).positions(key);
    }

    function _clMint(int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        override
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = IThickV3Pool(pool).mint(address(this), tickLower, tickUpper, liquidity, "");
    }

    function _clBurn(int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        override
        returns (uint256 owed0, uint256 owed1)
    {
        (owed0, owed1) = IThickV3Pool(pool).burn(tickLower, tickUpper, liquidity);
    }

    function _clCollect(int24 tickLower, int24 tickUpper, address to, uint128 c0, uint128 c1)
        internal
        override
        returns (uint256 amount0, uint256 amount1)
    {
        (uint128 a0, uint128 a1) = IThickV3Pool(pool).collect(to, tickLower, tickUpper, c0, c1);
        amount0 = a0;
        amount1 = a1;
    }
}
