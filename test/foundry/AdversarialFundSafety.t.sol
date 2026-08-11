// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../../contracts/LeverageRouter.sol";
import "../../contracts/UnwindRouter.sol";
import "../../contracts/Stratus-ALM/StratusBeetsV3Adapter.sol";
import "../../contracts/Stratus-ALM/StratusDLMMVaultFactory.sol";
import "../../contracts/Stratus-ALM/StratusDLMMVault.sol";
import "../../contracts/Stratus-ALM/base/StratusVaultBase.sol";
import "../../contracts/Stratus-ALM/base/StratusDLMMVaultBase.sol";
import "../../contracts/Stratus-ALM/interfaces/ILBPair.sol";
import "../../contracts/Stratus-ALM/test/MockERC20.sol";

interface ILBPairSwap {
    function swap(bool swapForY, address to) external returns (bytes32);
}
import "../../contracts/tarotFactory.sol";
import "../../contracts/BDeployer.sol";
import "../../contracts/CDeployer.sol";
import "../../contracts/Collateral.sol";
import "../../contracts/LendingPoolStruct.sol";

/// @dev Adversarial suite focused on fund loss and permanent bricking.
contract AdversarialFundSafetyTest is Test {
    address constant LB_FACTORY = 0x39D966c1BaFe7D3F1F53dA4845805E15f7D6EE43;
    address constant PAIR = 0x361F55337074ae43957204CB30fFBAbbCe4Fb837;
    address constant FUNDING_SOURCE = 0x9e81415250996E5cE50B3E3FD99EE9964Dd53008;
    address constant wS = 0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38;
    address constant USSD = 0x000000000eCcFf26B795F73fb0A70d48da657fEf;
    address constant METRO = 0x71E99522EaD5E21CF57F1f542Dc4ad2E841F7321;
    address constant BEETS_VAULT = 0xbA1333333333a1BA1108E8412f11850A5C319bA9;
    address constant BPT = 0x75b000584a7d86Fb3ef5E15ba26F4C52b41be0E9;
    address constant GAUGE = 0xaE647ea922D392cC825c51967382940A30893f6D;

    LeverageRouter lev;
    UnwindRouter unwind;

    function setUp() public {
        lev = new LeverageRouter();
        unwind = new UnwindRouter();
    }

    // =========================================================================
    // Router forgery
    // =========================================================================

    function test_leverageRouter_forgedTarotBorrow_reverts() public {
        bytes memory data = abi.encode(address(1), address(2), address(0), uint256(0), uint256(0));
        vm.expectRevert(LeverageRouter.Unauthorized.selector);
        lev.tarotBorrow(address(lev), address(this), 1 ether, data);
    }

    function test_unwindRouter_forgedTarotRedeem_reverts() public {
        bytes memory data = abi.encode(
            address(1), address(this), address(2), address(3), address(4), uint256(1 ether), uint256(0), uint256(0)
        );
        vm.expectRevert(UnwindRouter.Unauthorized.selector);
        unwind.tarotRedeem(address(unwind), 1 ether, data);
    }

    function test_leverageRouter_tarotRedeem_alwaysReverts() public {
        vm.expectRevert(LeverageRouter.Unauthorized.selector);
        lev.tarotRedeem(address(this), 0, "");
    }

    // =========================================================================
    // Two-step mint/redeem snipe (Tarot PoolToken primitive) vs atomic pattern
    // =========================================================================

    function test_rawMintSnipe_succeeds_onPrimitive() public {
        MockERC20 token = new MockERC20("T", "T");
        SnipeablePool pool = new SnipeablePool(address(token));
        address victim = address(0xBEEF);
        address attacker = address(0xBAD);

        token.mint(victim, 100 ether);
        vm.prank(victim);
        token.transfer(address(pool), 100 ether);

        vm.prank(attacker);
        pool.mint(attacker);
        assertEq(pool.balanceOf(attacker), 100 ether, "attacker sniped victim deposit");
        assertEq(pool.balanceOf(victim), 0);
    }

    function test_rawRedeemSnipe_succeeds_onPrimitive() public {
        MockERC20 token = new MockERC20("T", "T");
        SnipeablePool pool = new SnipeablePool(address(token));
        address victim = address(0xBEEF);
        address attacker = address(0xBAD);

        token.mint(victim, 100 ether);
        vm.startPrank(victim);
        token.transfer(address(pool), 100 ether);
        pool.mint(victim);
        pool.stageRedeem(100 ether); // transfer receipt tokens onto the pool
        vm.stopPrank();

        vm.prank(attacker);
        uint256 got = pool.redeem(attacker);
        assertEq(got, 100 ether, "attacker sniped redeem");
        assertEq(token.balanceOf(attacker), 100 ether);
    }

    function test_atomicLendPattern_noSnipeWindow() public {
        MockERC20 token = new MockERC20("T", "T");
        SnipeablePool pool = new SnipeablePool(address(token));
        address user = address(0xA11CE);
        token.mint(user, 50 ether);

        // Same-tx transfer + mint (what LeverageRouter.lend does).
        vm.startPrank(user);
        token.transfer(address(pool), 50 ether);
        pool.mint(user);
        vm.stopPrank();

        assertEq(pool.balanceOf(user), 50 ether);
        vm.expectRevert(bytes("nothing"));
        vm.prank(address(0xBAD));
        pool.mint(address(0xBAD));
    }

    // =========================================================================
    // Beets — donation immunity + 1:1 unwrap
    // =========================================================================

    function test_beets_donationDoesNotInflateOrStealUnwrap() public {
        vm.createSelectFork(vm.envOr("SONIC_RPC_URL", string("https://rpc.soniclabs.com")));

        StratusBeetsV3Adapter adapter =
            new StratusBeetsV3Adapter(BEETS_VAULT, BPT, GAUGE, "s-stS-wS", "sBPT");

        address user = address(0xA11CE);
        address attacker = address(0xBAD);
        uint256 amount = 1000 ether;

        vm.startPrank(GAUGE);
        vm.deal(GAUGE, 10 ether);
        IERC20(BPT).transfer(user, amount);
        IERC20(BPT).transfer(attacker, 500 ether);
        vm.stopPrank();

        vm.startPrank(user);
        IERC20(BPT).approve(address(adapter), amount);
        adapter.wrap(amount, user);
        vm.stopPrank();

        uint256 ppsBefore = adapter.pricePerShareSafe();
        uint256 userShares = adapter.balanceOf(user);

        vm.prank(attacker);
        IERC20(BPT).transfer(address(adapter), 500 ether);

        assertEq(adapter.pricePerShareSafe(), ppsBefore, "donation must not move pps");
        assertEq(adapter.balanceOf(user), userShares, "user shares unchanged");

        uint256 bptBefore = IERC20(BPT).balanceOf(user);
        vm.prank(user);
        adapter.unwrap(userShares, user);
        assertEq(IERC20(BPT).balanceOf(user) - bptBefore, amount, "unwrap still 1:1");
        assertEq(adapter.balanceOf(user), 0);
    }

    // =========================================================================
    // DLMM — panic withdraw + fee seed + second rebalance
    // =========================================================================

    function test_dlmm_unsafePrice_bricksDeposit_notWithdraw() public {
        vm.createSelectFork(vm.envOr("SONIC_RPC_URL", string("https://rpc.soniclabs.com")));

        StratusDLMMVaultFactory factory = new StratusDLMMVaultFactory(LB_FACTORY, METRO);
        _fund(FUNDING_SOURCE, wS, address(this), 200 ether);
        _fund(FUNDING_SOURCE, USSD, address(this), 1 ether);
        IERC20(wS).approve(address(factory), 200 ether);
        IERC20(USSD).approve(address(factory), 1 ether);
        factory.createVault(wS, USSD, 10, 100, 10, 200 ether, 1 ether);
        StratusDLMMVault vault = StratusDLMMVault(factory.vaultForPair(PAIR));

        // Warm oracle, deposit, then let the sample go stale past MAX_ORACLE_STALENESS
        // (TWAP_PERIOD/3 = 10 minutes) with no new trade.
        _warmLbOracle();
        assertTrue(vault.isSafePriceAvailable(), "oracle warm");

        address user = address(0xA11CE);
        _fund(FUNDING_SOURCE, wS, user, 20 ether);
        vm.startPrank(user);
        IERC20(wS).approve(address(vault), 20 ether);
        vault.deposit(20 ether, 0, user, 0);
        uint256 shares = vault.balanceOf(user);
        vm.stopPrank();
        assertGt(shares, 0);

        vm.warp(block.timestamp + 11 minutes);
        assertFalse(vault.isSafePriceAvailable(), "oracle should be stale");

        // New deposits fail closed — temporary freeze, not a silent spot fallback.
        _fund(FUNDING_SOURCE, wS, user, 1 ether);
        vm.startPrank(user);
        IERC20(wS).approve(address(vault), 1 ether);
        vm.expectRevert(StratusDLMMVaultBase.UnsafePrice.selector);
        vault.deposit(1 ether, 0, user, 0);

        // Existing holders can still exit — fee accrual skips when unsafe.
        uint256 before = IERC20(wS).balanceOf(user);
        vault.withdraw(shares, user, 0, 0);
        vm.stopPrank();
        assertEq(vault.balanceOf(user), 0);
        assertGt(IERC20(wS).balanceOf(user), before, "withdraw works while oracle stale");
    }

    function test_dlmm_panicDoesNotBrickWithdraw_andFeeDoesNotTaxSeed() public {
        vm.createSelectFork(vm.envOr("SONIC_RPC_URL", string("https://rpc.soniclabs.com")));

        StratusDLMMVaultFactory factory = new StratusDLMMVaultFactory(LB_FACTORY, METRO);
        _fund(FUNDING_SOURCE, wS, address(this), 200 ether);
        _fund(FUNDING_SOURCE, USSD, address(this), 1 ether);
        IERC20(wS).approve(address(factory), 200 ether);
        IERC20(USSD).approve(address(factory), 1 ether);
        factory.createVault(wS, USSD, 10, 100, 10, 200 ether, 1 ether);

        StratusDLMMVault vault = StratusDLMMVault(factory.vaultForPair(PAIR));

        uint256 factoryShares = vault.balanceOf(address(factory));
        uint256 supply = vault.totalSupply();
        assertLt(factoryShares * 10000 / (supply == 0 ? 1 : supply), 1, "factory taxed seed TVL");

        _warmLbOracle();

        address user = address(0xA11CE);
        _fund(FUNDING_SOURCE, wS, user, 20 ether);
        vm.startPrank(user);
        IERC20(wS).approve(address(vault), 20 ether);
        vault.deposit(20 ether, 0, user, 0);
        uint256 shares = vault.balanceOf(user);
        assertGt(shares, 0, "user got shares");
        vm.stopPrank();

        address[] memory vs = new address[](1);
        vs[0] = address(vault);
        factory.panicAtTheDisco(vs);
        assertTrue(vault.paused());

        vm.startPrank(user);
        vm.expectRevert(StratusVaultBase.VaultPaused.selector);
        vault.deposit(1, 0, user, 0);

        uint256 wSBefore = IERC20(wS).balanceOf(user);
        vault.withdraw(shares, user, 0, 0);
        vm.stopPrank();

        assertEq(vault.balanceOf(user), 0, "shares burned");
        assertGt(IERC20(wS).balanceOf(user), wSBefore, "user recovered principal under panic");
    }

    function test_dlmm_secondRebalanceDoesNotBrickFunds() public {
        vm.createSelectFork(vm.envOr("SONIC_RPC_URL", string("https://rpc.soniclabs.com")));

        StratusDLMMVaultFactory factory = new StratusDLMMVaultFactory(LB_FACTORY, METRO);
        _fund(FUNDING_SOURCE, wS, address(this), 200 ether);
        _fund(FUNDING_SOURCE, USSD, address(this), 1 ether);
        IERC20(wS).approve(address(factory), 200 ether);
        IERC20(USSD).approve(address(factory), 1 ether);
        factory.createVault(wS, USSD, 10, 100, 10, 200 ether, 1 ether);
        StratusDLMMVault vault = StratusDLMMVault(factory.vaultForPair(PAIR));

        _warmLbOracle();

        address user = address(0xA11CE);
        _fund(FUNDING_SOURCE, wS, user, 30 ether);
        vm.startPrank(user);
        IERC20(wS).approve(address(vault), 30 ether);
        vault.deposit(30 ether, 0, user, 0);
        vm.stopPrank();

        uint256 valueBefore = vault.getTotalValueSafe();
        factory.deployIdleVault(address(vault));
        factory.deployIdleVault(address(vault));
        uint256 valueAfter = vault.getTotalValueSafe();

        if (valueBefore > 0) {
            uint256 lossBps =
                valueBefore > valueAfter ? ((valueBefore - valueAfter) * 10000) / valueBefore : 0;
            assertLt(lossBps, 50, "second rebalance burned >0.5% TVL");
        }

        uint256 shares = vault.balanceOf(user);
        vm.prank(user);
        vault.withdraw(shares, user, 0, 0);
        assertEq(vault.balanceOf(user), 0);
    }

    /// @dev Mirror scripts/test-adversarial-round2.ts warmOracle:
    ///      warp past TWAP_PERIOD, trade to write a fresh sample, then a short mine.
    function _warmLbOracle() internal {
        vm.warp(block.timestamp + 1900);
        vm.roll(block.number + 1);
        // Never fund from PAIR itself (breaks reserves). FUNDING_SOURCE is binStep=20.
        _fund(FUNDING_SOURCE, wS, PAIR, 1 ether);
        address tokenX = ILBPair(PAIR).getTokenX();
        bool swapForY = tokenX == wS;
        ILBPairSwap(PAIR).swap(swapForY, address(this));
        vm.warp(block.timestamp + 30);
        vm.roll(block.number + 1);
    }

    // =========================================================================
    // Collateral prices off safe surface only
    // =========================================================================

    function test_collateral_ignoresSpotInflation() public {
        MinimalALPT alpt = new MinimalALPT();
        alpt.mint(address(this), 100e18);
        alpt.setSafe(100e18, 1e18);

        BDeployer bd = new BDeployer();
        CDeployer cd = new CDeployer();
        TarotFactory tarot = new TarotFactory(address(this), address(this), bd, cd);
        tarot.createCollateral(address(alpt));
        tarot.createBorrowable0(address(alpt));
        tarot.createBorrowable1(address(alpt));
        tarot.initializeLendingPool(address(alpt));
        LendingPool memory lp = tarot.getLendingPool(address(alpt));
        Collateral col = Collateral(lp.collateral);

        address user = address(0xA11CE);
        alpt.transfer(user, 100e18);
        vm.startPrank(user);
        alpt.transfer(address(col), 100e18);
        col.mint(user);
        vm.stopPrank();

        (uint256 price0,) = col.getPrices();
        alpt.setSpot(1_000_000e18);
        (uint256 price0After,) = col.getPrices();
        assertEq(price0After, price0, "spot move must not change collateral prices");
    }

    function _fund(address source, address token, address to, uint256 amount) internal {
        vm.startPrank(source);
        vm.deal(source, 10_000 ether);
        IERC20(token).transfer(to, amount);
        vm.stopPrank();
    }
}

/// @dev Models Tarot PoolToken mint/redeem balance-diff bookkeeping for snipe demos.
contract SnipeablePool {
    IERC20 public immutable underlying;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    uint256 public totalBalance;

    constructor(address u) {
        underlying = IERC20(u);
    }

    function mint(address minter) external returns (uint256 minted) {
        uint256 bal = underlying.balanceOf(address(this));
        minted = bal - totalBalance;
        require(minted > 0, "nothing");
        balanceOf[minter] += minted;
        totalSupply += minted;
        totalBalance = bal;
    }

    /// @dev Victim stages a redeem by parking receipt tokens on the pool contract.
    function stageRedeem(uint256 tokens) external {
        require(balanceOf[msg.sender] >= tokens, "bal");
        balanceOf[msg.sender] -= tokens;
        balanceOf[address(this)] += tokens;
    }

    function redeem(address redeemer) external returns (uint256 amount) {
        uint256 tokens = balanceOf[address(this)];
        require(tokens > 0, "no tokens");
        amount = tokens;
        balanceOf[address(this)] = 0;
        totalSupply -= tokens;
        totalBalance -= amount;
        underlying.transfer(redeemer, amount);
    }
}

contract MinimalALPT is ERC20 {
    uint256 public safeValue;
    uint256 public safeTwap = 1e18;
    uint256 public spotValue;

    constructor() ERC20("mALPT", "mALPT") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function setSafe(uint256 v, uint256 p) external {
        safeValue = v;
        safeTwap = p;
    }

    function setSpot(uint256 v) external {
        spotValue = v;
    }

    function getTotalValueSafe() external view returns (uint256) {
        return safeValue;
    }

    function twapPrice() external view returns (uint256) {
        return safeTwap;
    }

    function getTotalValue() external view returns (uint256) {
        return spotValue == 0 ? safeValue : spotValue;
    }

    function token0() external pure returns (address) {
        return address(0x01);
    }

    function token1() external pure returns (address) {
        return address(0x02);
    }

    function pool() external pure returns (address) {
        return address(0x03);
    }
}
