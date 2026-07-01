import { ethers } from "hardhat";
import { expect } from "chai";
import { impersonateAccount, setBalance, takeSnapshot } from "@nomicfoundation/hardhat-network-helpers";

/**
 * Full lending-market lifecycle on a real Thick-ALPT-collateralized Tarot pool (Sonic fork):
 *   borrow → interest accrual → repay → lender redeem-with-yield → liquidation → reserves.
 * Plus a Beets-adapter-as-collateral borrow, exercising the second venue through the lender.
 *
 *   npx hardhat test test/integration/lending-lifecycle.fork.test.ts --config hardhat.config.integration.ts
 */
const CL_FACTORY = "0x7Ca1dCCFB4f49564b8f13E18a67747fd428F1C40";
const POOL = "0xb1BC4B830FCbA2184B92e15b9133c41160518038"; // wS/USDC.e ts=8
const wS = "0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38"; // token0 (18d)
const USDCe = "0x29219dd400f2Bf60E5a23d13Be72B486D4038894"; // token1 (6d)
const TICK_SPACING = 8;

const ERC20 = [
  "function transfer(address,uint256) returns (bool)",
  "function approve(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
];

async function fundFromPool(token: string, to: string, amount: bigint) {
  if (amount === 0n) return;
  await impersonateAccount(POOL);
  await setBalance(POOL, ethers.parseEther("100"));
  const s = await ethers.getSigner(POOL);
  await new ethers.Contract(token, ERC20, s).transfer(to, amount);
}

async function increaseTime(seconds: number) {
  await ethers.provider.send("evm_increaseTime", [seconds]);
  await ethers.provider.send("evm_mine", []);
}

const YEAR = 365 * 24 * 60 * 60;

describe("full lending lifecycle (Thick ALPT collateral, Sonic fork)", () => {
  let deployer: any, lender: any, borrower: any, liquidator: any;
  let tarot: any, collateral: any, b0: any, b1: any, alpt: any, vfac: any;
  let snap: any;

  before(async () => {
    [deployer, lender, borrower, liquidator] = await ethers.getSigners();

    // --- ALPT (Thick vault) ---
    const tm = await (await ethers.getContractFactory("TickMath")).deploy();
    const la = await (await ethers.getContractFactory("LiquidityAmounts")).deploy();
    const ph = await (await ethers.getContractFactory("UniswapV3PriceHelper", { libraries: { TickMath: await tm.getAddress() } })).deploy();
    const VF = await ethers.getContractFactory("StratusThickVaultFactory", { libraries: { TickMath: await tm.getAddress(), LiquidityAmounts: await la.getAddress(), UniswapV3PriceHelper: await ph.getAddress() } });
    vfac = await VF.connect(deployer).deploy(CL_FACTORY);
    await vfac.waitForDeployment();
    await fundFromPool(wS, deployer.address, ethers.parseEther("1"));
    await fundFromPool(USDCe, deployer.address, ethers.parseUnits("0.03", 6));
    await new ethers.Contract(wS, ERC20, deployer).approve(await vfac.getAddress(), ethers.parseEther("1"));
    await new ethers.Contract(USDCe, ERC20, deployer).approve(await vfac.getAddress(), ethers.parseUnits("0.03", 6));
    await vfac.createVault(USDCe, wS, TICK_SPACING, 100, 5, ethers.parseEther("1"), ethers.parseUnits("0.03", 6));
    alpt = await ethers.getContractAt("StratusThickVault", await vfac.vaultForPool(POOL));

    // --- Tarot lending pool ---
    const BD = await (await ethers.getContractFactory("BDeployer")).deploy();
    const CD = await (await ethers.getContractFactory("CDeployer")).deploy();
    tarot = await (await ethers.getContractFactory("TarotFactory")).deploy(
      deployer.address, deployer.address, await BD.getAddress(), await CD.getAddress()
    );
    await tarot.waitForDeployment();
    const alptAddr = await alpt.getAddress();
    await tarot.createCollateral(alptAddr);
    await tarot.createBorrowable0(alptAddr);
    await tarot.createBorrowable1(alptAddr);
    await tarot.initializeLendingPool(alptAddr);
    const lp = await tarot.getLendingPool(alptAddr);
    collateral = await ethers.getContractAt("Collateral", lp.collateral);
    b0 = await ethers.getContractAt("Borrowable", lp.borrowable0); // wS
    b1 = await ethers.getContractAt("Borrowable", lp.borrowable1); // USDC

    // --- fund the wS borrowable (the side we'll borrow/liquidate) ---
    await fundFromPool(wS, lender.address, ethers.parseEther("50"));
    await new ethers.Contract(wS, ERC20, lender).transfer(lp.borrowable0, ethers.parseEther("50"));
    await b0.connect(lender).mint(lender.address);
    await fundFromPool(USDCe, lender.address, ethers.parseUnits("5", 6));
    await new ethers.Contract(USDCe, ERC20, lender).transfer(lp.borrowable1, ethers.parseUnits("5", 6));
    await b1.connect(lender).mint(lender.address);

    // --- borrower posts ALPT collateral ---
    await fundFromPool(wS, borrower.address, ethers.parseEther("10"));
    await fundFromPool(USDCe, borrower.address, ethers.parseUnits("0.3", 6));
    await new ethers.Contract(wS, ERC20, borrower).approve(alptAddr, ethers.parseEther("10"));
    await new ethers.Contract(USDCe, ERC20, borrower).approve(alptAddr, ethers.parseUnits("0.3", 6));
    await alpt.connect(borrower).deposit(ethers.parseEther("10"), ethers.parseUnits("0.3", 6), borrower.address, 0);
    const alptBal = await alpt.balanceOf(borrower.address);
    await alpt.connect(borrower).transfer(lp.collateral, alptBal);
    await collateral.connect(borrower).mint(borrower.address);

    snap = await takeSnapshot();
  });

  afterEach(async () => {
    await snap.restore();
  });

  async function maxBorrowWs(): Promise<bigint> {
    const [price0] = await collateral.getPrices();
    const sm = await collateral.safetyMarginSqrt();
    const li = await collateral.liquidationIncentive();
    const [amountCollateral] = await collateral.accountLiquidity.staticCall(borrower.address);
    return (BigInt(amountCollateral) * 10n ** 54n) / (BigInt(price0) * BigInt(sm) * BigInt(li));
  }

  it("borrow → interest accrues → debt and lender exchange-rate both grow", async () => {
    const max = await maxBorrowWs();
    const amt = (max * 50n) / 100n;
    const wst = new ethers.Contract(wS, ERC20, borrower);
    const before = await wst.balanceOf(borrower.address);
    await b0.connect(borrower).borrow(borrower.address, borrower.address, amt, "0x");
    expect((await wst.balanceOf(borrower.address)) - before).to.equal(amt);

    const debt0 = await b0.borrowBalance(borrower.address);
    const rate0 = await b0.exchangeRate.staticCall();
    expect(debt0).to.be.greaterThan(0n);

    await increaseTime(YEAR);
    await b0.accrueInterest();
    const debt1 = await b0.borrowBalance(borrower.address);
    const rate1 = await b0.exchangeRate.staticCall();
    console.log("debt :", ethers.formatEther(debt0), "->", ethers.formatEther(debt1), "wS (after 1y)");
    console.log("xRate:", ethers.formatEther(rate0), "->", ethers.formatEther(rate1));
    expect(debt1).to.be.greaterThan(debt0); // borrower owes more
    expect(rate1).to.be.greaterThan(rate0); // suppliers earned
  });

  it("repay reduces the debt", async () => {
    const amt = (await maxBorrowWs()) / 2n;
    await b0.connect(borrower).borrow(borrower.address, borrower.address, amt, "0x");
    await increaseTime(30 * 24 * 60 * 60);
    await b0.accrueInterest();
    const debtBefore = await b0.borrowBalance(borrower.address);

    // repay half: send wS to the borrowable and call borrow with borrowAmount 0
    const repay = debtBefore / 2n;
    await fundFromPool(wS, borrower.address, repay);
    await new ethers.Contract(wS, ERC20, borrower).transfer(await b0.getAddress(), repay);
    await b0.connect(borrower).borrow(borrower.address, borrower.address, 0, "0x");

    const debtAfter = await b0.borrowBalance(borrower.address);
    console.log("repay: debt", ethers.formatEther(debtBefore), "->", ethers.formatEther(debtAfter), "wS");
    expect(debtAfter).to.be.lessThan(debtBefore);
    expect(debtAfter).to.be.closeTo(debtBefore - repay, repay / 100n);
  });

  it("lender redeems supplied wS with accrued yield", async () => {
    // create utilization + let interest run
    await b0.connect(borrower).borrow(borrower.address, borrower.address, (await maxBorrowWs()) / 2n, "0x");
    await increaseTime(2 * YEAR);
    await b0.accrueInterest();

    // lender redeems a cash-covered slice of their bTAROT
    const shares = await b0.balanceOf(lender.address);
    const redeemShares = shares / 10n; // 10% — well within remaining cash
    const rate = await b0.exchangeRate.staticCall();
    const wst = new ethers.Contract(wS, ERC20, lender);
    const before = await wst.balanceOf(lender.address);
    await b0.connect(lender).transfer(await b0.getAddress(), redeemShares);
    await b0.connect(lender).redeem(lender.address);
    const got = (await wst.balanceOf(lender.address)) - before;

    console.log("redeem:", ethers.formatEther(redeemShares), "shares ->", ethers.formatEther(got), "wS  (xRate", ethers.formatEther(rate) + ")");
    expect(rate).to.be.greaterThan(ethers.parseEther("1")); // > initial 1e18 → yield accrued
    expect(got).to.be.greaterThan(redeemShares); // each share now worth > 1 wS
  });

  it("liquidates an underwater borrower (seize + clear shortfall)", async () => {
    // borrow near the limit, then let interest push the position underwater
    const max = await maxBorrowWs();
    await b0.connect(borrower).borrow(borrower.address, borrower.address, (max * 90n) / 100n, "0x");
    await increaseTime(5 * YEAR);
    await b0.accrueInterest();

    const [, shortfall] = await collateral.accountLiquidity.staticCall(borrower.address);
    console.log("shortfall after 5y:", shortfall.toString());
    expect(shortfall).to.be.greaterThan(0n); // underwater

    const debtBefore = await b0.borrowBalance(borrower.address);
    const liqCollBefore = await collateral.balanceOf(liquidator.address);

    // liquidator repays part of the wS debt and seizes collateral
    const repay = debtBefore / 2n;
    await fundFromPool(wS, liquidator.address, repay);
    await new ethers.Contract(wS, ERC20, liquidator).transfer(await b0.getAddress(), repay);
    await b0.connect(liquidator).liquidate(borrower.address, liquidator.address);

    const debtAfter = await b0.borrowBalance(borrower.address);
    const liqCollAfter = await collateral.balanceOf(liquidator.address);
    console.log("liquidate: debt", ethers.formatEther(debtBefore), "->", ethers.formatEther(debtAfter), "; liquidator seized", (liqCollAfter - liqCollBefore).toString(), "cTAROT");
    expect(debtAfter).to.be.lessThan(debtBefore); // debt repaid
    expect(liqCollAfter).to.be.greaterThan(liqCollBefore); // collateral seized
  });

  it("reserves accrue to the reserves manager", async () => {
    await tarot._setReservesManager(deployer.address); // deployer is reservesAdmin
    await b0.connect(borrower).borrow(borrower.address, borrower.address, (await maxBorrowWs()) / 2n, "0x");
    await increaseTime(2 * YEAR);
    // exchangeRateAccrue mints the reserve cut to the reserves manager
    const before = await b0.balanceOf(deployer.address);
    await b0.exchangeRateAccrue();
    const after = await b0.balanceOf(deployer.address);
    console.log("reserves minted to manager:", ethers.formatEther(after - before), "bTAROT");
    expect(after).to.be.greaterThan(before);
  });
});

describe("lending against a Beets adapter (BPT collateral, Sonic fork)", () => {
  const BEETS_VAULT = "0xbA1333333333a1BA1108E8412f11850A5C319bA9";
  const BPT = "0x75b000584a7d86fb3ef5e15ba26f4c52b41be0e9"; // stS-wS
  const BPT_HOLDER = "0xaE647ea922D392cC825c51967382940A30893f6D";

  it("wraps BPT as collateral and borrows against it", async () => {
    const [deployer, lender, borrower] = await ethers.getSigners();

    // adapter (token0 = wS, token1 = stS)
    const adapter = await (await ethers.getContractFactory("StratusBeetsV3Adapter")).deploy(
      BEETS_VAULT, BPT, "Stratus Beets stS-wS", "s-stS-wS"
    );
    await adapter.waitForDeployment();
    const adapterAddr = await adapter.getAddress();
    const token0 = await adapter.token0(); // wS

    // Tarot pool on the adapter
    const BD = await (await ethers.getContractFactory("BDeployer")).deploy();
    const CD = await (await ethers.getContractFactory("CDeployer")).deploy();
    const tarot = await (await ethers.getContractFactory("TarotFactory")).deploy(
      deployer.address, deployer.address, await BD.getAddress(), await CD.getAddress()
    );
    await tarot.waitForDeployment();
    await tarot.createCollateral(adapterAddr);
    await tarot.createBorrowable0(adapterAddr);
    await tarot.createBorrowable1(adapterAddr);
    await tarot.initializeLendingPool(adapterAddr);
    const lp = await tarot.getLendingPool(adapterAddr);
    const collateral = await ethers.getContractAt("Collateral", lp.collateral);
    const b0 = await ethers.getContractAt("Borrowable", lp.borrowable0); // wS

    // fund the wS borrowable from the Thick pool's reserves
    await fundFromPool(wS, lender.address, ethers.parseEther("100"));
    await new ethers.Contract(wS, ERC20, lender).transfer(lp.borrowable0, ethers.parseEther("100"));
    await b0.connect(lender).mint(lender.address);

    // borrower wraps BPT and posts it as collateral
    await impersonateAccount(BPT_HOLDER);
    await setBalance(BPT_HOLDER, ethers.parseEther("10"));
    const holder = await ethers.getSigner(BPT_HOLDER);
    const bptAmt = ethers.parseEther("100");
    await new ethers.Contract(BPT, ERC20, holder).transfer(borrower.address, bptAmt);
    await new ethers.Contract(BPT, ERC20, borrower).approve(adapterAddr, bptAmt);
    await adapter.connect(borrower).wrap(bptAmt, borrower.address);
    await adapter.connect(borrower).transfer(lp.collateral, bptAmt);
    await collateral.connect(borrower).mint(borrower.address);

    // borrow wS against the wrapped-BPT collateral
    const [price0] = await collateral.getPrices();
    const sm = await collateral.safetyMarginSqrt();
    const li = await collateral.liquidationIncentive();
    const [amountCollateral] = await collateral.accountLiquidity.staticCall(borrower.address);
    const max = (BigInt(amountCollateral) * 10n ** 54n) / (BigInt(price0) * BigInt(sm) * BigInt(li));

    const wst = new ethers.Contract(token0, ERC20, borrower);
    const before = await wst.balanceOf(borrower.address);
    const amt = (max * 40n) / 100n;
    await b0.connect(borrower).borrow(borrower.address, borrower.address, amt, "0x");
    const got = (await wst.balanceOf(borrower.address)) - before;
    console.log("Beets collateral: borrowed", ethers.formatEther(got), "wS against", ethers.formatEther(bptAmt), "wrapped BPT");
    expect(got).to.equal(amt);
    expect(amt).to.be.greaterThan(0n);

    // over-borrow still reverts (collateral cap from the adapter's rate-provider value)
    await expect(
      b0.connect(borrower).borrow(borrower.address, borrower.address, max * 5n, "0x")
    ).to.be.reverted;
    console.log("Beets collateral: over-borrow reverted ✓");
  });
});
