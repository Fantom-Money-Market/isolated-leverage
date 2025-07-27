// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @dev Interface for a vault that can be paused and unpaused.
 */
interface IPausableVault {
    /**
     * @dev Pauses the vault, preventing certain actions.
     *
     * Emits a {Paused} event.
     */
    function pause() external;

    /**
     * @dev Unpauses the vault, resuming normal operations.
     *
     * Emits an {Unpaused} event.
     */
    function unpause() external;
}
