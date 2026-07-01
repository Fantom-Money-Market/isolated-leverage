// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./StratusThickVault.sol";
import "./interfaces/IStratusThickVault.sol";

/// @title StratusThickVaultDeployer
/// @notice Single-purpose deployer. The factory calls this externally so its own bytecode
///         does not embed StratusThickVault's creation code (EIP-170).
contract StratusThickVaultDeployer is IStratusThickVaultDeployer {
    /// @inheritdoc IStratusThickVaultDeployer
    function deploy(
        address pool,
        uint256 upwardBias,
        uint8 protocolFee,
        string memory name,
        string memory symbol
    ) external returns (address vault) {
        // msg.sender is the factory calling deploy(); record it as the vault's privileged
        // `factory` so onlyFactory admin works through the deployer.
        vault = address(new StratusThickVault(msg.sender, pool, upwardBias, protocolFee, name, symbol));
    }
}
