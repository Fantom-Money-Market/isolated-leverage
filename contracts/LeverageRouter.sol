// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/ITarotCallee.sol";

interface ILevVault {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function deposit(uint256 deposit0, uint256 deposit1, address to, uint256 minShares) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface ILevBorrowable {
    function borrow(address borrower, address receiver, uint256 borrowAmount, bytes calldata data) external;
    function mint(address minter) external returns (uint256);
    function underlying() external view returns (address);
}

interface ILevCollateral {
    function mint(address minter) external returns (uint256);
    function underlying() external view returns (address);
    function borrowable0() external view returns (address);
    function borrowable1() external view returns (address);
}

/// @notice One-call leverage for Stratus ALPT lending pools — the Tarot/Impermax Router
///         "leverage" pattern. The user's own tokens plus flash-borrowed tokens from both
///         Borrowables are deposited into the vault, and the resulting ALPT is posted as
///         the user's collateral, all inside a single transaction. This works because
///         Borrowable.borrow() transfers funds and invokes the callback BEFORE its
///         solvency check — by the time canBorrow() runs, the leveraged collateral is
///         already minted to the borrower.
/// @dev Trust model: holds no funds between transactions and has no owner/admin. The
///      borrower must have called borrowApprove(router) on each Borrowable being drawn
///      from; the Borrowables themselves enforce post-callback solvency. The callback is
///      gated on (msg.sender == the borrowable we just called) + (sender == this router),
///      so third parties can't feed it forged contexts.
contract LeverageRouter is ITarotCallee {
    using SafeERC20 for IERC20;

    error Unauthorized();
    error BadCollateral();
    error NothingToDo();

    struct LevContext {
        address vault;
        address collateral;
        address borrowable1; // second leg (0 = single-sided leverage)
        uint256 borrow1;
        uint256 minShares;
    }

    /// @dev The borrowable expected to invoke tarotBorrow next; doubles as a reentrancy lock.
    address private expectedCaller;

    /// @notice Open or increase a leveraged ALPT position in one call.
    /// @param collateral The Collateral (cToken) contract; vault/borrowables are read from it.
    /// @param user0/user1 The caller's own tokens to pull in (either may be 0).
    /// @param borrow0/borrow1 Amounts to flash-borrow from borrowable0/borrowable1 (either may be 0).
    /// @param minShares Slippage floor on the vault shares minted for the combined deposit.
    function leverage(
        address collateral,
        uint256 user0,
        uint256 user1,
        uint256 borrow0,
        uint256 borrow1,
        uint256 minShares
    ) external {
        if (expectedCaller != address(0)) revert Unauthorized();
        if (user0 == 0 && user1 == 0 && borrow0 == 0 && borrow1 == 0) revert NothingToDo();

        address vault = ILevCollateral(collateral).underlying();
        address b0 = ILevCollateral(collateral).borrowable0();
        address b1 = ILevCollateral(collateral).borrowable1();
        if (vault == address(0) || b0 == address(0) || b1 == address(0)) revert BadCollateral();

        if (user0 > 0) IERC20(ILevVault(vault).token0()).safeTransferFrom(msg.sender, address(this), user0);
        if (user1 > 0) IERC20(ILevVault(vault).token1()).safeTransferFrom(msg.sender, address(this), user1);

        LevContext memory ctx = LevContext({
            vault: vault,
            collateral: collateral,
            borrowable1: borrow1 > 0 ? b1 : address(0),
            borrow1: borrow1,
            minShares: minShares
        });

        if (borrow0 > 0) {
            expectedCaller = b0;
            ILevBorrowable(b0).borrow(msg.sender, address(this), borrow0, abi.encode(ctx));
        } else if (borrow1 > 0) {
            ctx.borrowable1 = address(0); // consumed here, not in a callback
            expectedCaller = b1;
            ILevBorrowable(b1).borrow(msg.sender, address(this), borrow1, abi.encode(ctx));
        } else {
            _mintPosition(vault, collateral, msg.sender, minShares);
        }
        expectedCaller = address(0);
    }

    /// @notice Atomic lend: pull `amount` of the borrowable's underlying from the caller and
    ///         mint the lend receipt (bTokens) to them in the SAME transaction.
    /// @dev Exists because Borrowable.mint() is a Uniswap-V2-style low-level primitive: it
    ///      credits whoever is named as `minter` with the contract's whole unaccounted
    ///      balance delta, regardless of who created it. Doing the transfer and the mint in
    ///      two separate transactions leaves a window in which anyone can call
    ///      Borrowable.mint(themselves) and take the pending deposit. Callers must approve
    ///      this router for `amount` rather than transferring directly to the Borrowable.
    function lend(address borrowable, uint256 amount) external returns (uint256 mintTokens) {
        if (expectedCaller != address(0)) revert Unauthorized();
        if (amount == 0) revert NothingToDo();

        address underlying = ILevBorrowable(borrowable).underlying();
        if (underlying == address(0)) revert BadCollateral();

        IERC20(underlying).safeTransferFrom(msg.sender, borrowable, amount);
        mintTokens = ILevBorrowable(borrowable).mint(msg.sender);
    }

    /// @inheritdoc ITarotCallee
    function tarotBorrow(address sender, address borrower, uint256, bytes calldata data) external {
        if (msg.sender != expectedCaller || sender != address(this)) revert Unauthorized();
        LevContext memory ctx = abi.decode(data, (LevContext));

        if (ctx.borrowable1 != address(0)) {
            // Second leg: nest the token1 borrow; its own solvency check (and then the
            // outer one) runs after the position is minted below.
            address b1 = ctx.borrowable1;
            ctx.borrowable1 = address(0);
            expectedCaller = b1;
            ILevBorrowable(b1).borrow(borrower, address(this), ctx.borrow1, abi.encode(ctx));
            expectedCaller = address(0);
        } else {
            _mintPosition(ctx.vault, ctx.collateral, borrower, ctx.minShares);
        }
    }

    /// @inheritdoc ITarotCallee
    function tarotRedeem(address, uint256, bytes calldata) external pure {
        revert Unauthorized(); // this router only opens positions
    }

    /// @dev Deposit everything the router holds into the vault and post the ALPT as
    ///      `borrower`'s collateral. Vault deposits are held idle until the next
    ///      rebalance, so any token mix is accepted in full — no leftovers to refund.
    function _mintPosition(address vault, address collateral, address borrower, uint256 minShares) internal {
        IERC20 t0 = IERC20(ILevVault(vault).token0());
        IERC20 t1 = IERC20(ILevVault(vault).token1());
        uint256 bal0 = t0.balanceOf(address(this));
        uint256 bal1 = t1.balanceOf(address(this));

        if (bal0 > 0) t0.forceApprove(vault, bal0);
        if (bal1 > 0) t1.forceApprove(vault, bal1);
        ILevVault(vault).deposit(bal0, bal1, address(this), minShares);

        uint256 shares = ILevVault(vault).balanceOf(address(this));
        ILevVault(vault).transfer(collateral, shares);
        ILevCollateral(collateral).mint(borrower);
    }
}
