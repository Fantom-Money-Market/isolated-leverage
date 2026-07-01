import { ethers } from "hardhat";
import { expect } from "chai";
import { impersonateAccount, setBalance } from "@nomicfoundation/hardhat-network-helpers";

/**
 * CROSS-LAYER exploit test: stand up a real Stratus ALPT (Thick vault) + a real Tarot
 * lending pool on top of it, fund it, and try to drain it. The headline vector is the one
 * that only exists at the seam of the two layers: manipulate the underlying CL pool's SPOT
 * price to inflate the collateral and over-borrow. Collateral.getPrices() now reads the
 * ALPT's manipulation-resistant safe surface (getTotalValueSafe / twapPrice), so the attack
 * must fail.
 *
 *   npx hardhat test test/integration/drain.fork.test.ts --config hardhat.config.integration.ts
 */
const CL_FACTORY = "0x7Ca1dCCFB4f49564b8f13E18a67747fd428F1C40"; // Thick CL factory
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
  await impersonateAccount(POOL);
  await setBalance(POOL, ethers.parseEther("100"));
  const s = await ethers.getSigner(POOL);
  await new ethers.Contract(token, ERC20, s).transfer(to, amount);
}

describe("cross-layer drain attempts (Thick ALPT + Tarot, Sonic fork)", () => {
  it("layers compose; spot manipulation grants no extra borrow power; over-borrow reverts", async () => {
    const [deployer, lender, borrower] = await ethers.getSigners();

    // ---------- 1. make an ALPT (Thick vault) ----------
    const tm = await (await ethers.getContractFactory("TickMath")).deploy();
    const la = await (await ethers.getContractFactory("LiquidityAmounts")).deploy();
    const ph = await (await ethers.getContractFactory("UniswapV3PriceHelper", { libraries: { TickMath: await tm.getAddress() } })).deploy();
    const VF = await ethers.getContractFactory("StratusThickVaultFactory", { libraries: { TickMath: await tm.getAddress(), LiquidityAmounts: await la.getAddress(), UniswapV3PriceHelper: await ph.getAddress() } });
    const vfac = await VF.connect(deployer).deploy(CL_FACTORY);
    await vfac.waitForDeployment();
    const seed0 = ethers.parseEther("1");
    const seed1 = ethers.parseUnits("0.03", 6);
    await fundFromPool(wS, deployer.address, seed0);
    await fundFromPool(USDCe, deployer.address, seed1);
    await new ethers.Contract(wS, ERC20, deployer).approve(await vfac.getAddress(), seed0);
    await new ethers.Contract(USDCe, ERC20, deployer).approve(await vfac.getAddress(), seed1);
    await vfac.createVault(USDCe, wS, TICK_SPACING, 100, 5, seed0, seed1);
    const alpt = await ethers.getContractAt("StratusThickVault", await vfac.vaultForPool(POOL));
    const alptAddr = await alpt.getAddress();

    // ---------- 2. make a Tarot lending pool on the ALPT ----------
    const BD = await (await ethers.getContractFactory("BDeployer")).deploy();
    const CD = await (await ethers.getContractFactory("CDeployer")).deploy();
    const TF = await ethers.getContractFactory("TarotFactory");
    const tarot = await TF.deploy(deployer.address, deployer.address, await BD.getAddress(), await CD.getAddress());
    await tarot.waitForDeployment();

    await tarot.createCollateral(alptAddr);
    await tarot.createBorrowable0(alptAddr);
    await tarot.createBorrowable1(alptAddr);
    await tarot.initializeLendingPool(alptAddr);

    const lp = await tarot.getLendingPool(alptAddr);
    const collateral = await ethers.getContractAt("Collateral", lp.collateral);
    const borrowable0 = await ethers.getContractAt("Borrowable", lp.borrowable0); // wS
    const borrowable1 = await ethers.getContractAt("Borrowable", lp.borrowable1); // USDC
    console.log("collateral :", lp.collateral);
    console.log("borrowable0:", lp.borrowable0, "(wS)");
    console.log("borrowable1:", lp.borrowable1, "(USDC)");

    // ---------- 3. fund the borrowables (lenders supply cash) ----------
    const fund0 = ethers.parseEther("50");
    const fund1 = ethers.parseUnits("5", 6);
    await fundFromPool(wS, lender.address, fund0);
    await fundFromPool(USDCe, lender.address, fund1);
    await new ethers.Contract(wS, ERC20, lender).transfer(lp.borrowable0, fund0);
    await borrowable0.connect(lender).mint(lender.address);
    await new ethers.Contract(USDCe, ERC20, lender).transfer(lp.borrowable1, fund1);
    await borrowable1.connect(lender).mint(lender.address);

    // ---------- 4. borrower gets ALPT collateral ----------
    const dep0 = ethers.parseEther("10");
    const dep1 = ethers.parseUnits("0.3", 6);
    await fundFromPool(wS, borrower.address, dep0);
    await fundFromPool(USDCe, borrower.address, dep1);
    await new ethers.Contract(wS, ERC20, borrower).approve(alptAddr, dep0);
    await new ethers.Contract(USDCe, ERC20, borrower).approve(alptAddr, dep1);
    await alpt.connect(borrower).deposit(dep0, dep1, borrower.address, 0);
    const alptBal = await alpt.balanceOf(borrower.address);
    await alpt.connect(borrower).transfer(lp.collateral, alptBal);
    await collateral.connect(borrower).mint(borrower.address);
    console.log("borrower ALPT collateral:", ethers.formatUnits(alptBal, await alpt.decimals()));

    // ---------- compute the borrower's max wS borrow from the SAFE price ----------
    const [price0] = await collateral.getPrices();
    const sm = await collateral.safetyMarginSqrt();
    const li = await collateral.liquidationIncentive();
    const [amountCollateral] = await collateral.accountLiquidity.staticCall(borrower.address); // no debt yet
    // collateralNeeded(x) = x*price0/1e18 * sm/1e18 * li/1e18 ; solve = amountCollateral
    const maxBorrow0 = (BigInt(amountCollateral) * 10n ** 54n) / (BigInt(price0) * BigInt(sm) * BigInt(li));
    console.log("max wS borrow (safe) :", ethers.formatEther(maxBorrow0));

    // ---------- 5. happy path: borrow 30% of capacity ----------
    const safeBorrow = (maxBorrow0 * 30n) / 100n;
    const wsBefore = await new ethers.Contract(wS, ERC20, borrower).balanceOf(borrower.address);
    await borrowable0.connect(borrower).borrow(borrower.address, borrower.address, safeBorrow, "0x");
    const wsAfter = await new ethers.Contract(wS, ERC20, borrower).balanceOf(borrower.address);
    expect(wsAfter - wsBefore).to.equal(safeBorrow);
    console.log("happy borrow         :", ethers.formatEther(safeBorrow), "wS received ✓");

    // ---------- 6. over-borrow reverts ----------
    await expect(
      borrowable0.connect(borrower).borrow(borrower.address, borrower.address, maxBorrow0 * 5n, "0x")
    ).to.be.reverted;
    console.log("over-borrow (5x cap) : reverted ✓");

    // ---------- 7. THE cross-layer attack: inflate SPOT to over-borrow ----------
    // Override only slot0.sqrtPriceX96 (leave the tick alone, so the TWAP is untouched).
    // Thick's slot0 lives at storage slot 1 (verified: low 160 bits == live sqrtPriceX96).
    const slot = "0x1";
    const raw = BigInt(await ethers.provider.send("eth_getStorageAt", [POOL, slot, "latest"]));
    const curSqrt = raw & ((1n << 160n) - 1n);
    const slot0 = await ethers.getContractAt("IThickV3Pool", POOL);
    const live = (await slot0.slot0())[0];
    expect(curSqrt).to.equal(BigInt(live)); // confirm slot0 really lives at storage slot 0

    const safeValBefore = await alpt.getTotalValueSafe();
    const spotValBefore = await alpt.getTotalValue();
    const [liqBefore] = await collateral.accountLiquidity.staticCall(borrower.address);

    const upper = raw >> 160n; // tick + observation fields — keep, so observe()/TWAP is unchanged
    const newWord = (upper << 160n) | (curSqrt * 2n); // 2x sqrt => 4x spot price
    await ethers.provider.send("hardhat_setStorageAt", [POOL, slot, "0x" + newWord.toString(16).padStart(64, "0")]);

    const safeValAfter = await alpt.getTotalValueSafe();
    const spotValAfter = await alpt.getTotalValue();
    const [liqAfter] = await collateral.accountLiquidity.staticCall(borrower.address);
    console.log("spot value  :", spotValBefore.toString(), "->", spotValAfter.toString());
    console.log("safe value  :", safeValBefore.toString(), "->", safeValAfter.toString());
    console.log("borrow power:", liqBefore.toString(), "->", liqAfter.toString());

    // spot moved a lot; the safe value and the borrowing capacity did NOT move at all.
    expect(spotValAfter).to.not.equal(spotValBefore);
    expect(safeValAfter).to.equal(safeValBefore);
    expect(liqAfter).to.equal(liqBefore);

    // the attacker tries to draw the "extra" the inflated spot would have unlocked → revert
    const remaining = maxBorrow0 - safeBorrow;
    await expect(
      borrowable0.connect(borrower).borrow(borrower.address, borrower.address, remaining * 3n, "0x")
    ).to.be.reverted;
    console.log("post-manipulation over-borrow: reverted ✓ (collateral priced off TWAP, not spot)");

    // restore the manipulated slot0 so it doesn't leak into other test files sharing the fork
    await ethers.provider.send("hardhat_setStorageAt", [POOL, slot, "0x" + raw.toString(16).padStart(64, "0")]);

    // ---------- 8. reentrancy via the tarotBorrow flash callback ----------
    const att = await (await ethers.getContractFactory("ReentrantAttacker")).deploy();
    await expect(att.attack(lp.borrowable0, ethers.parseEther("0.001"))).to.be.reverted;
    console.log("reentrant borrow via tarotBorrow callback: reverted ✓");
  });
});
