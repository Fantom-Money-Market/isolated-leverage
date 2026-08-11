// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/ITarotCallee.sol";

interface IUnwindVault {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function withdraw(uint256 shares, address to, uint256 minAmount0, uint256 minAmount1)
        external
        returns (uint256, uint256);
}

interface IUnwindBorrowable {
    function borrow(address borrower, address receiver, uint256 borrowAmount, bytes calldata data) external;
    function borrowBalance(address borrower) external view returns (uint256);
    function exchangeRate() external returns (uint256); // accrue-modified: syncs interest
    function underlying() external view returns (address);
    function redeem(address redeemer) external returns (uint256 redeemAmount);
}

interface IUnwindCollateral {
    function underlying() external view returns (address);
    function borrowable0() external view returns (address);
    function borrowable1() external view returns (address);
    function exchangeRate() external returns (uint256);
    function flashRedeem(address redeemer, uint256 redeemAmount, bytes calldata data) external;
}

/// @notice One-call deleverage for Stratus ALPT pools.
/// @dev Liquidity is the borrower's own ALPT collateral (cToken → underlying), never the
///      lend-side borrowable cash pools. flashRedeem temporarily releases ALPT; we break
///      it, repay debt, then pull cTokens from the borrower (after debt is reduced) to
///      complete the burn.
contract UnwindRouter is ITarotCallee {
    using SafeERC20 for IERC20;

    error Unauthorized();
    error BadCollateral();
    error NothingToDo();

    struct UnwindContext {
        address collateral;
        address borrower;
        address vault;
        address borrowable0;
        address borrowable1;
        uint256 cTokenAmount;
        uint256 minAmount0;
        uint256 minAmount1;
    }

    address private expectedCaller;

    /// @param cTokenAmount cTokens the borrower will post to complete the redeem (approve router).
    /// @param minAmount0/minAmount1 Slippage floors on vault withdraw.
    function deleverage(
        address collateral,
        uint256 cTokenAmount,
        uint256 minAmount0,
        uint256 minAmount1
    ) external {
        if (expectedCaller != address(0)) revert Unauthorized();
        if (cTokenAmount <= 1) revert NothingToDo();

        IUnwindCollateral col = IUnwindCollateral(collateral);
        address vault = col.underlying();
        address b0 = col.borrowable0();
        address b1 = col.borrowable1();
        if (vault == address(0) || b0 == address(0) || b1 == address(0)) revert BadCollateral();

        // (cTokenAmount - 1) so declaredRedeemTokens fits in the post-callback burn.
        uint256 rate = col.exchangeRate();
        uint256 redeemAmount = ((cTokenAmount - 1) * rate) / 1e18;
        if (redeemAmount == 0) revert NothingToDo();

        UnwindContext memory ctx = UnwindContext({
            collateral: collateral,
            borrower: msg.sender,
            vault: vault,
            borrowable0: b0,
            borrowable1: b1,
            cTokenAmount: cTokenAmount,
            minAmount0: minAmount0,
            minAmount1: minAmount1
        });

        expectedCaller = collateral;
        col.flashRedeem(address(this), redeemAmount, abi.encode(ctx));
        expectedCaller = address(0);
    }

    /// @inheritdoc ITarotCallee
    /// @dev Collateral.flashRedeem calls tarotRedeem(msg.sender, …) where msg.sender is
    ///      this router — same pattern as LeverageRouter.tarotBorrow.
    function tarotRedeem(address sender, uint256 amount, bytes calldata data) external {
        if (msg.sender != expectedCaller || sender != address(this)) revert Unauthorized();
        UnwindContext memory ctx = abi.decode(data, (UnwindContext));

        IUnwindVault vault = IUnwindVault(ctx.vault);
        (uint256 out0, uint256 out1) =
            vault.withdraw(amount, address(this), ctx.minAmount0, ctx.minAmount1);

        // Repay first — reduces debt before the cToken pull is health-checked.
        _repayAndRefund(ctx.borrowable0, vault.token0(), ctx.borrower, out0);
        _repayAndRefund(ctx.borrowable1, vault.token1(), ctx.borrower, out1);

        // Complete the flash redeem burn (post-repay solvency).
        IERC20(ctx.collateral).safeTransferFrom(ctx.borrower, ctx.collateral, ctx.cTokenAmount);
    }

    /// @notice Atomic repay: pull up to `amount` of the borrowable's underlying from the
    ///         caller and apply it to THEIR debt in the same transaction.
    /// @dev Repayment on a Borrowable is expressed as borrow(borrower, _, 0, "") — the
    ///      contract credits its whole unaccounted balance delta to whoever is named as
    ///      `borrower`, and a zero borrow amount consumes no borrow allowance. Split across
    ///      two transactions that lets anyone call borrow(themselves, address(0), 0, "")
    ///      in between and have the pending payment retire their own debt instead.
    /// @param amount Maximum to repay; the actual repayment is capped at the caller's live
    ///        debt so an overpayment can't be stranded as unattributed pool value.
    /// @return repaid Underlying actually pulled and applied.
    function repay(address borrowable, uint256 amount) external returns (uint256 repaid) {
        if (expectedCaller != address(0)) revert Unauthorized();
        if (amount == 0) revert NothingToDo();

        address token = IUnwindBorrowable(borrowable).underlying();
        if (token == address(0)) revert BadCollateral();

        // borrowBalance() reads the last-accrued index; poke first so the cap reflects
        // interest owed right now (same reason as _repayAndRefund below).
        IUnwindBorrowable(borrowable).exchangeRate();
        uint256 debt = IUnwindBorrowable(borrowable).borrowBalance(msg.sender);
        repaid = amount < debt ? amount : debt;
        if (repaid == 0) revert NothingToDo();

        IERC20(token).safeTransferFrom(msg.sender, borrowable, repaid);
        IUnwindBorrowable(borrowable).borrow(msg.sender, address(0), 0, "");
    }

    /// @notice Atomic unlend: burn `tokens` of the caller's bTokens and send them the
    ///         underlying in one transaction (exit counterpart to LeverageRouter.lend()).
    /// @dev Borrowable.redeem() burns whatever bTokens sit on the Borrowable and pays the
    ///      named redeemer — so transfer-then-redeem leaves a snipe window. Do both halves
    ///      here; callers approve this router instead of transferring bTokens directly.
    ///      redeem() pays the whole bToken balance on the Borrowable, so this transfers
    ///      exactly the amount it will burn (no partial redeem).
    /// @return amount Underlying sent to the caller.
    function unlend(address borrowable, uint256 tokens) external returns (uint256 amount) {
        if (expectedCaller != address(0)) revert Unauthorized();
        if (tokens == 0) revert NothingToDo();

        IERC20(borrowable).safeTransferFrom(msg.sender, borrowable, tokens);
        amount = IUnwindBorrowable(borrowable).redeem(msg.sender);
    }

    /// @inheritdoc ITarotCallee
    function tarotBorrow(address, address, uint256, bytes calldata) external pure {
        revert Unauthorized();
    }

    function _repayAndRefund(
        address borrowable,
        address token,
        address borrower,
        uint256 amountMax
    ) internal {
        if (amountMax == 0) return;
        // Accrue before reading debt — borrowBalance() uses the last-accrued index.
        // A full unwind leaves zero collateral; any remaining dust debt fails tokensUnlocked.
        IUnwindBorrowable(borrowable).exchangeRate();
        uint256 debt = IUnwindBorrowable(borrowable).borrowBalance(borrower);
        uint256 repayAmount = amountMax < debt ? amountMax : debt;
        if (repayAmount > 0) {
            IERC20(token).safeTransfer(borrowable, repayAmount);
            IUnwindBorrowable(borrowable).borrow(borrower, address(0), 0, "");
        }
        uint256 refund = amountMax - repayAmount;
        if (refund > 0) {
            IERC20(token).safeTransfer(borrower, refund);
        }
    }
}
