// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./StratusDLMMVault.sol";
import "./interfaces/IStratusDLMMVault.sol";

/// @title StratusDLMMVaultDeployer
/// @notice Single-purpose deployer. The factory calls this externally so its own
///         bytecode does not embed StratusDLMMVault's creation code.
/// @dev Deploy once (from the factory constructor or standalone) and reuse forever.
contract StratusDLMMVaultDeployer is IStratusDLMMVaultDeployer {
    /// @inheritdoc IStratusDLMMVaultDeployer
    function deploy(
        address pair,
        uint256 upwardBias,
        uint8 protocolFee,
        string memory name,
        string memory symbol
    ) external returns (address vault) {
        // msg.sender is the factory calling deploy(); record it as the vault's
        // privileged `factory` so onlyFactory admin works through the deployer.
        vault = address(new StratusDLMMVault(msg.sender, pair, upwardBias, protocolFee, name, symbol));
    }
}
