// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal surface used by StratusShadowVaultFactory during seeding and admin.
interface IStratusShadowVault {
    function deposit(uint256 deposit0, uint256 deposit1, address to, uint256 minShares)
        external
        returns (uint256 shares);

    function deployIdle() external;

    function setGauge(address gauge) external;

    function setRewardTokens(address[] calldata tokens) external;

    function updateProtocolFee(uint8 newFee) external;

    function setRebalanceParams(
        uint256 deviationCapBps,
        uint256 bountyBps,
        uint256 rewardBountyBps,
        uint256 minSkewBps
    ) external;

    function panicAtTheDisco() external;

    function resume() external;
}

/// @notice Deploys StratusShadowVault instances. Kept separate from the factory so
///         the factory runtime stays under the 24KB limit (vault creation code is
///         embedded here, not in the factory).
interface IStratusShadowVaultDeployer {
    function deploy(
        address pool,
        uint256 upwardBias,
        uint8 protocolFee,
        string memory name,
        string memory symbol
    ) external returns (address vault);
}
