import { ethers } from "hardhat";
import { expect } from "chai";
import { impersonateAccount, setBalance } from "@nomicfoundation/hardhat-network-helpers";

/**
 * Regression test for the SAME accumulator bug found in StratusVaultBase, reproduced in
 * Collateral.sol's own "MasterChef accumulator over cToken balances" (harvestVaultRewards /
 * _settleVaultRewards / pendingVaultReward): a harvest landing while cToken totalSupply is
 * still tiny (just after the first mint, no real borrower yet) inflates rewardPerShareStored
 * by an unbounded factor, which then feeds an overflow-unsafe raw multiplication in
 * _settleVaultRewards on every mint/redeem/transfer/seize.
 *
 * Strictly worse here than the vault-level bug: _settleVaultRewards runs INSIDE seize(), so
 * an unguarded overflow there would revert liquidation of an underwater borrower — a direct
 * threat to protocol solvency, not just one user's claim/withdraw.
 *
 * Two fixes (Collateral.sol), mirroring the vault's: (1) harvestVaultRewards floors its
 * denominator with +MINIMUM_LIQUIDITY; (2) _settleVaultRewards / pendingVaultReward use
 * Math.mulDiv instead of raw `*`/`/`.
 *
 *   npx hardhat test test/integration/collateral-reward-accumulator.fork.test.ts --config hardhat.config.integration.ts
 */
const VOTER = "0x9F59398D0a397b2EEB8a6123a6c7295cB0b0062D";
const POOL = "0x324963c267C354c7660Ce8CA3F5f167E05649970"; // wS/USDC.e ts=50 (gauged)
const wS = "0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38"; // token0 (18d)
const USDCe = "0x29219dd400f2Bf60E5a23d13Be72B486D4038894"; // token1 (6d)
const TICK_SPACING = 50;

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

describe("Collateral MasterChef accumulator floor (live-bug-class regression, Sonic fork)", () => {
  it("a tiny-cToken-supply harvest stays bounded, and an extreme accumulator never blocks claim/pending/liquidation", async () => {
    const [deployer, firstDepositor, borrower, liquidator] = await ethers.getSigners();

    // ---------- mock reward token + gauge (deterministic, matches the vault-level test) ----------
    const mockToken = await (await ethers.getContractFactory("MockERC20")).deploy("Mock Reward", "MOCK");
    await mockToken.waitForDeployment();
    const mockTokenAddr = await mockToken.getAddress();

    const mockGauge = await (await ethers.getContractFactory("MockGauge")).deploy(mockTokenAddr, 0n);
    await mockGauge.waitForDeployment();
    const mockGaugeAddr = await mockGauge.getAddress();

    // ---------- real Shadow vault on a real gauged pool ----------
    const tm = await (await ethers.getContractFactory("TickMath")).deploy();
    const la = await (await ethers.getContractFactory("LiquidityAmounts")).deploy();
    const ph = await (await ethers.getContractFactory("UniswapV3PriceHelper", { libraries: { TickMath: await tm.getAddress() } })).deploy();
    const F = await ethers.getContractFactory("StratusShadowVaultFactory", {
      libraries: { TickMath: await tm.getAddress(), LiquidityAmounts: await la.getAddress(), UniswapV3PriceHelper: await ph.getAddress() },
    });
    const factory = await F.connect(deployer).deploy(VOTER, mockTokenAddr);
    await factory.waitForDeployment();
    const factoryAddr = await factory.getAddress();

    const seed0 = ethers.parseEther("1");
    const seed1 = ethers.parseUnits("0.03", 6);
    await fundFromPool(wS, deployer.address, seed0);
    await fundFromPool(USDCe, deployer.address, seed1);
    await new ethers.Contract(wS, ERC20, deployer).approve(factoryAddr, seed0);
    await new ethers.Contract(USDCe, ERC20, deployer).approve(factoryAddr, seed1);
    await factory.createVault(USDCe, wS, TICK_SPACING, 100, 5, seed0, seed1);
    const alpt = await ethers.getContractAt("StratusShadowVault", await factory.vaultForPool(POOL));
    const alptAddr = await alpt.getAddress();
    await factory.setVaultGauge(alptAddr, mockGaugeAddr);

    // ---------- Tarot lending pool on the ALPT ----------
    const BD = await (await ethers.getContractFactory("BDeployer")).deploy();
    const CD = await (await ethers.getContractFactory("CDeployer")).deploy();
    const tarot = await (await ethers.getContractFactory("TarotFactory")).deploy(
      deployer.address, deployer.address, await BD.getAddress(), await CD.getAddress()
    );
    await tarot.waitForDeployment();
    await tarot.createCollateral(alptAddr);
    await tarot.createBorrowable0(alptAddr);
    await tarot.createBorrowable1(alptAddr);
    await tarot.initializeLendingPool(alptAddr);
    const lp = await tarot.getLendingPool(alptAddr);
    const collateral = await ethers.getContractAt("Collateral", lp.collateral);
    const b0 = await ethers.getContractAt("Borrowable", lp.borrowable0); // wS

    // fund the wS borrowable so there's cash to borrow/liquidate against
    await fundFromPool(wS, deployer.address, ethers.parseEther("50"));
    await new ethers.Contract(wS, ERC20, deployer).transfer(lp.borrowable0, ethers.parseEther("50"));
    await b0.connect(deployer).mint(deployer.address);

    // ---------- replicate the live incident at the COLLATERAL level: a tiny first mint,
    //            then a harvest lands before any real borrower exists ----------
    const tinyDep0 = ethers.parseEther("0.001");
    const tinyDep1 = ethers.parseUnits("0.00003", 6);
    await fundFromPool(wS, firstDepositor.address, tinyDep0);
    await fundFromPool(USDCe, firstDepositor.address, tinyDep1);
    await new ethers.Contract(wS, ERC20, firstDepositor).approve(alptAddr, tinyDep0);
    await new ethers.Contract(USDCe, ERC20, firstDepositor).approve(alptAddr, tinyDep1);
    await alpt.connect(firstDepositor).deposit(tinyDep0, tinyDep1, firstDepositor.address, 0);
    const tinyAlptBal = await alpt.balanceOf(firstDepositor.address);
    await alpt.connect(firstDepositor).transfer(lp.collateral, tinyAlptBal);
    await collateral.connect(firstDepositor).mint(firstDepositor.address);

    const supplyAfterFirstMint = await collateral.totalSupply();
    console.log("Collateral totalSupply after the first (tiny) mint:", supplyAfterFirstMint.toString());

    const ORDINARY_REWARD = ethers.parseEther("0.00083"); // ~ what actually got harvested live
    await mockGauge.setRewardPerCall(ORDINARY_REWARD);
    await alpt.collectGaugeRewards(); // vault-level harvest: gauge -> vault, credits Collateral's share
    await collateral.harvestVaultRewards(); // pull-through: vault -> Collateral, credits cToken holders

    const accAfterTinySupplyHarvest = await collateral.rewardPerShareStored(mockTokenAddr);
    console.log("Collateral rewardPerShareStored after tiny-supply harvest:", accAfterTinySupplyHarvest.toString());

    const harvestedNet = ORDINARY_REWARD * 3n; // 3 ranges on the Shadow vault
    const MINIMUM_LIQUIDITY = 1000n;
    const REWARD_ACC_PRECISION = 10n ** 18n;
    const maxPossibleAcc = (harvestedNet * REWARD_ACC_PRECISION) / MINIMUM_LIQUIDITY;
    expect(accAfterTinySupplyHarvest).to.be.lessThanOrEqual(maxPossibleAcc);
    console.log("bounded by the MINIMUM_LIQUIDITY floor: acc <=", maxPossibleAcc.toString(), "✓");

    // ---------- a real borrower posts a LARGE collateral position, checkpointed at the
    //            current (already-bounded) acc ----------
    const dep0 = ethers.parseEther("10");
    const dep1 = ethers.parseUnits("0.3", 6);
    await fundFromPool(wS, borrower.address, dep0);
    await fundFromPool(USDCe, borrower.address, dep1);
    await new ethers.Contract(wS, ERC20, borrower).approve(alptAddr, dep0);
    await new ethers.Contract(USDCe, ERC20, borrower).approve(alptAddr, dep1);
    await alpt.connect(borrower).deposit(dep0, dep1, borrower.address, 0);
    const borrowerAlptBal = await alpt.balanceOf(borrower.address);
    await alpt.connect(borrower).transfer(lp.collateral, borrowerAlptBal);
    await collateral.connect(borrower).mint(borrower.address);
    const borrowerCBal = await collateral.balanceOf(borrower.address);
    expect(await collateral.userRewardPerSharePaid(mockTokenAddr, borrower.address)).to.equal(accAfterTinySupplyHarvest);

    // ---------- force an EXTREME accumulator via one more (mocked) harvest ----------
    await mockGauge.setRewardPerCall(10n ** 60n);
    await alpt.collectGaugeRewards();
    await collateral.harvestVaultRewards();

    const accExtreme = await collateral.rewardPerShareStored(mockTokenAddr);
    const paid = await collateral.userRewardPerSharePaid(mockTokenAddr, borrower.address);
    const naiveProduct = borrowerCBal * (accExtreme - paid);
    console.log("borrower cToken bal:", borrowerCBal.toString());
    console.log("acc delta:", (accExtreme - paid).toString());
    console.log("naive bal*(acc-paid) > uint256 max?", naiveProduct > 2n ** 256n - 1n);
    expect(naiveProduct).to.be.greaterThan(2n ** 256n - 1n); // confirms this WOULD have overflowed pre-fix

    // ---------- pendingVaultReward (view) must not revert ----------
    const pending = await collateral.pendingVaultReward(borrower.address, mockTokenAddr);
    expect(pending).to.be.greaterThan(0n);
    console.log("pendingVaultReward survived the extreme accumulator ✓");

    // ---------- claimVaultRewards (state-changing, exercises _settleVaultRewards) ----------
    const before = await mockToken.balanceOf(borrower.address);
    await expect(collateral.connect(borrower).claimVaultRewards()).to.not.be.reverted;
    const after = await mockToken.balanceOf(borrower.address);
    expect(after - before).to.equal(pending);
    console.log("claimVaultRewards succeeded despite an overflow-triggering accumulator ✓");

    // ---------- THE critical check: seize() (liquidation) must still work. This is the
    //            consequence that's strictly worse than the vault-level bug — an unguarded
    //            overflow here would make an underwater borrower's collateral unseizable. ----------
    const [price0] = await collateral.getPrices();
    const sm = await collateral.safetyMarginSqrt();
    const li = await collateral.liquidationIncentive();
    const [amountCollateral] = await collateral.accountLiquidity.staticCall(borrower.address);
    const maxBorrow = (BigInt(amountCollateral) * 10n ** 54n) / (BigInt(price0) * BigInt(sm) * BigInt(li));
    await b0.connect(borrower).borrow(borrower.address, borrower.address, (maxBorrow * 90n) / 100n, "0x");
    await increaseTime(5 * YEAR);
    await b0.accrueInterest();

    const [, shortfall] = await collateral.accountLiquidity.staticCall(borrower.address);
    expect(shortfall).to.be.greaterThan(0n); // underwater
    console.log("borrower underwater, shortfall:", shortfall.toString());

    const debtBefore = await b0.borrowBalance(borrower.address);
    const liqCollBefore = await collateral.balanceOf(liquidator.address);
    const repay = debtBefore / 2n;
    await fundFromPool(wS, liquidator.address, repay);
    await new ethers.Contract(wS, ERC20, liquidator).transfer(await b0.getAddress(), repay);

    await expect(b0.connect(liquidator).liquidate(borrower.address, liquidator.address)).to.not.be.reverted;

    const liqCollAfter = await collateral.balanceOf(liquidator.address);
    expect(liqCollAfter).to.be.greaterThan(liqCollBefore);
    console.log("liquidation succeeded despite the extreme accumulator ✓ (seized:", (liqCollAfter - liqCollBefore).toString(), "cTAROT)");
  });
});
