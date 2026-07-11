// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../../contracts/Stratus-ALM/StratusDLMMVaultFactory.sol";
import "../../contracts/Stratus-ALM/StratusDLMMVault.sol";
import "../../contracts/Stratus-ALM/interfaces/ILBPair.sol";
import "../../contracts/tarotFactory.sol";
import "../../contracts/BDeployer.sol";
import "../../contracts/CDeployer.sol";
import "../../contracts/Collateral.sol";
import "../../contracts/Borrowable.sol";
import "../../contracts/LeverageRouter.sol";
import "../../contracts/LendingPoolStruct.sol";
import "../../contracts/UnwindRouter.sol";

/// @dev Reproduces: deploy -> deployIdle (1st) -> leverage -> unwind -> deployIdle (2nd).
///      Root cause of the original PackedUint128Math__SubUnderflow (0xe599af55) was NOT
///      vault composition math — it was fork-test funding that drained ERC20 tokens out of
///      PAIR, leaving balance < LB's internal _reserves. mint() then underflows on
///      `received = balance - _reserves`. Fixed by funding from FUNDING_SOURCE only, plus
///      vault-side _repairPairReserveShortfall that tops up against gross reserves
///      (getReserves + getProtocolFees) when a small shortfall exists.
contract DLMMRebalanceCycleTest is Test {
    uint256 internal constant SUB_UNDERFLOW = 0xe599af55;

    address constant LB_FACTORY = 0x39D966c1BaFe7D3F1F53dA4845805E15f7D6EE43;
    address constant PAIR = 0x361F55337074ae43957204CB30fFBAbbCe4Fb837;
    address constant FUNDING_SOURCE = 0x9e81415250996E5cE50B3E3FD99EE9964Dd53008;
    address constant wS = 0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38;
    address constant USSD = 0x000000000eCcFf26B795F73fb0A70d48da657fEf;
    address constant METRO = 0x71E99522EaD5E21CF57F1f542Dc4ad2E841F7321;
    address constant USER = 0x0190933669d250406efcf18b351b954Ea88D5bfD;

    uint16 constant BIN_STEP = 10;
    uint256 constant SEED0 = 200 ether;
    uint256 constant SEED1 = 1 ether;
    // Fund Tarot lenders / user from FUNDING_SOURCE (binStep=20 pair), NEVER from PAIR.
    // Pulling tokens out of PAIR leaves balance < _reserves and the next vault mint()
    // reverts with PackedUint128Math__SubUnderflow — that was the "second deployIdle"
    // failure after leverage/unwind, not a vault composition bug.
    uint256 constant LEND_WS = 100 ether;
    uint256 constant LEND_USSD = 1 ether;

    StratusDLMMVaultFactory factory;
    StratusDLMMVault vault;
    address collateral;
    address borrowable0;
    address borrowable1;
    LeverageRouter levRouter;
    UnwindRouter unwindRouter;

    function setUp() public {
        string memory rpc = vm.envOr("SONIC_RPC_URL", string("https://rpc.soniclabs.com"));
        vm.createSelectFork(rpc);

        factory = new StratusDLMMVaultFactory(LB_FACTORY, METRO);

        _fundFrom(FUNDING_SOURCE, wS, address(this), SEED0);
        _fundFrom(FUNDING_SOURCE, USSD, address(this), SEED1);
        IERC20(wS).approve(address(factory), SEED0);
        IERC20(USSD).approve(address(factory), SEED1);
        factory.createVault(wS, USSD, BIN_STEP, 100, 10, SEED0, SEED1);

        vault = StratusDLMMVault(factory.vaultForPair(PAIR));

        BDeployer bd = new BDeployer();
        CDeployer cd = new CDeployer();
        TarotFactory tarot = new TarotFactory(address(this), address(this), bd, cd);
        tarot.createCollateral(address(vault));
        tarot.createBorrowable0(address(vault));
        tarot.createBorrowable1(address(vault));
        tarot.initializeLendingPool(address(vault));
        LendingPool memory lp = tarot.getLendingPool(address(vault));
        collateral = lp.collateral;
        borrowable0 = lp.borrowable0;
        borrowable1 = lp.borrowable1;

        levRouter = new LeverageRouter();
        unwindRouter = new UnwindRouter();

        _fundFrom(FUNDING_SOURCE, wS, address(this), LEND_WS);
        IERC20(wS).transfer(borrowable0, LEND_WS);
        Borrowable(borrowable0).mint(address(this));
        _fundFrom(FUNDING_SOURCE, USSD, address(this), LEND_USSD);
        IERC20(USSD).transfer(borrowable1, LEND_USSD);
        Borrowable(borrowable1).mint(address(this));

        _fundFrom(FUNDING_SOURCE, wS, USER, 20 ether);
        _fundFrom(FUNDING_SOURCE, USSD, USER, 1 ether);
        vm.deal(USER, 500 ether);
    }

    function test_secondDeployIdleWithoutLeverage_succeeds() public {
        factory.deployIdleVault(address(vault));
        // second full rebalance immediately — should not depend on leverage/unwind
        factory.deployIdleVault(address(vault));
        _assertActiveBinLiquidity("after second deployIdle (no leverage)");
    }

    function test_secondDeployIdleAfterLeverageUnwind_succeeds() public {
        // createVault already ran deployIdle once — go straight to leverage/unwind
        vm.startPrank(USER);
        IERC20(wS).approve(address(levRouter), 10 ether);
        Borrowable(borrowable0).borrowApprove(address(levRouter), 10 ether);
        levRouter.leverage(collateral, 10 ether, 0, 10 ether, 0, 0);

        uint256 cBal = IERC20(collateral).balanceOf(USER);
        assertGt(cBal, 0, "no cTokens after leverage");

        IERC20(collateral).approve(address(unwindRouter), cBal);
        unwindRouter.deleverage(collateral, cBal, 0, 0);
        vm.stopPrank();

        factory.deployIdleVault(address(vault));
        _assertActiveBinLiquidity("after second deployIdle (post leverage/unwind)");
    }

    function test_initialDeployPutsLiquidityInActiveBin() public view {
        // createVault already called deployIdle once in setUp
        _assertActiveBinLiquidity("after initial createVault deployIdle");
    }

    function _assertActiveBinLiquidity(string memory where) internal view {
        uint24 activeId = ILBPair(PAIR).getActiveId();
        uint256 bal = ILBPair(PAIR).balanceOf(address(vault), activeId);
        assertGt(bal, 0, string.concat("expected active-bin LP shares: ", where));
    }

    function _fundFrom(address source, address token, address to, uint256 amount) internal {
        vm.startPrank(source);
        vm.deal(source, 10_000 ether);
        IERC20(token).transfer(to, amount);
        vm.stopPrank();
    }
}
