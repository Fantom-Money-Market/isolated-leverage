// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal surface used by StratusDLMMVaultFactory during seeding and admin.
interface IStratusDLMMVault {
    function deposit(uint256 deposit0, uint256 deposit1, address to, uint256 minShares)
        external
        returns (uint256 shares);

    function deployIdle() external;

    function hook() external view returns (address);

    function setRewardTokens(address[] calldata tokens) external;

    function updateProtocolFee(uint8 newFee) external;

    function setRewardBountyBps(uint256 rewardBountyBps) external;

    function panicAtTheDisco() external;

    function resume() external;
}

/// @notice Deploys StratusDLMMVault instances. Kept separate from the factory so the
///         factory runtime stays under the 24KB limit (vault creation code is embedded
///         here, not in the factory) — same split used for StratusShadowVaultDeployer.
interface IStratusDLMMVaultDeployer {
    function deploy(
        address pair,
        uint256 upwardBias,
        uint8 protocolFee,
        string memory name,
        string memory symbol
    ) external returns (address vault);
}
