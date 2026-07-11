// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./base/StratusDLMMVaultBase.sol";

/// @title StratusDLMMVault
/// @notice Fungible ERC20 (ALPT) wrapper around a Metropolis (Trader Joe Liquidity Book
///         fork) DLMM position. All bin management, valuation, rebalancing, protocol-fee
///         realization, and hook-reward harvesting live in StratusDLMMVaultBase; this is a
///         thin concrete adapter, kept as its own file for consistency with the CL vaults
///         (StratusShadowVault/StratusThickVault) and to leave a clean seam if a future
///         DLMM fork ever needs a differently-shaped pair interface.
contract StratusDLMMVault is StratusDLMMVaultBase {
    constructor(
        address _factory,
        address _pair,
        uint256 _upwardBias,
        uint8 _protocolFee,
        string memory _name,
        string memory _symbol
    ) StratusDLMMVaultBase(_factory, _pair, _upwardBias, _protocolFee, _name, _symbol) {}
}
