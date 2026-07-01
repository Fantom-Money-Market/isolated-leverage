// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./StratusShadowVault.sol";
import "./interfaces/IStratusShadowVault.sol";

/// @title StratusShadowVaultDeployer
/// @notice Single-purpose deployer. The factory calls this externally so its own
///         bytecode does not embed StratusShadowVault's creation code.
/// @dev Deploy once (from the factory constructor or standalone) and reuse forever.
contract StratusShadowVaultDeployer is IStratusShadowVaultDeployer {
    /// @inheritdoc IStratusShadowVaultDeployer
    function deploy(
        address pool,
        uint256 upwardBias,
        uint8 protocolFee,
        string memory name,
        string memory symbol
    ) external returns (address vault) {
        // msg.sender is the factory calling deploy(); record it as the vault's
        // privileged `factory` so onlyFactory admin works through the deployer.
        vault = address(new StratusShadowVault(msg.sender, pool, upwardBias, protocolFee, name, symbol));
    }
}
