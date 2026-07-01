// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../interfaces/ITarotCallee.sol";
import "../interfaces/IBorrowable.sol";

/// @notice Test-only attacker: re-enters Borrowable.borrow() from inside the tarotBorrow
///         flash callback. The borrowable's nonReentrant guard must make the whole tx revert.
contract ReentrantAttacker is ITarotCallee {
    function attack(address borrowable, uint256 amount) external {
        IBorrowable(borrowable).borrow(address(this), address(this), amount, abi.encode(borrowable, amount));
    }

    function tarotBorrow(address, address, uint256, bytes calldata data) external override {
        (address borrowable, uint256 amount) = abi.decode(data, (address, uint256));
        // Re-enter during the optimistic-transfer window — should hit `Reentered`.
        IBorrowable(borrowable).borrow(address(this), address(this), amount, "");
    }

    function tarotRedeem(address, uint256, bytes calldata) external override {}
}
