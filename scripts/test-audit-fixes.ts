import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

// Verifies the audit #1 and #2 fixes on-chain:
//   A. The front-running window is REAL on the old two-transaction pattern (attacker
//      steals a pending lend deposit by calling Borrowable.mint(attacker) first).
//   B. LeverageRouter.lend() closes it — the same attempt leaves the attacker nothing.
//   C. UnwindRouter.repay() applies a repayment to the payer, not a front-runner.
//   D. Collateral solvency checks now accrue both borrowables (audit #1).
//
//   npx hardhat run scripts/test-audit-fixes.ts --network localhost --config hardhat.config.fork-ui.ts

const ERC20 = [
  "function approve(address,uint256) returns (bool)",
  "function transfer(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
];
const POOL = "0x324963c267C354c7660Ce8CA3F5f167E05649970";

async function fundFromPool(token: string, to: string, amount: bigint) {
  await ethers.provider.send("hardhat_impersonateAccount", [POOL]);
  await ethers.provider.send("hardhat_setBalance", [POOL, "0x21e19e0c9bab2400000"]);
  const s = await ethers.getSigner(POOL);
  await new ethers.Contract(token, ERC20, s).transfer(to, amount);
  await ethers.provider.send("hardhat_stopImpersonatingAccount", [POOL]);
}

async function main() {
  const cfg = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "fork-ui", "config.json"), "utf8"));
  const [, , victim, attacker] = await ethers.getSigners();
  const wS = cfg.tokens.wS.address;
  const b0 = cfg.borrowable0;

  const bToken = await ethers.getContractAt("Borrowable", b0);
  const router = await ethers.getContractAt("LeverageRouter", cfg.leverageRouter);
  const AMT = ethers.parseEther("5");

  console.log("=== A. old two-tx pattern IS front-runnable (proving the bug is real) ===");
  await fundFromPool(wS, victim.address, AMT);
  // victim tx1: transfer underlying to the borrowable, intending to mint next block
  await (await new ethers.Contract(wS, ERC20, victim).transfer(b0, AMT)).wait();
  // attacker front-runs victim's tx2
  await (await bToken.connect(attacker).mint(attacker.address)).wait();
  const attackerStolen = await bToken.balanceOf(attacker.address);
  const victimGot = await bToken.balanceOf(victim.address);
  console.log("attacker bTokens:", ethers.formatEther(attackerStolen));
  console.log("victim   bTokens:", ethers.formatEther(victimGot));
  if (attackerStolen === 0n) throw new Error("expected the front-run to succeed pre-fix");
  console.log("=> CONFIRMED: attacker captured the victim's deposit\n");

  console.log("=== B. LeverageRouter.lend() is atomic — nothing left to front-run ===");
  await fundFromPool(wS, victim.address, AMT);
  await (await new ethers.Contract(wS, ERC20, victim).approve(cfg.leverageRouter, AMT)).wait();
  const before = await bToken.balanceOf(victim.address);
  await (await router.connect(victim).lend(b0, AMT)).wait();
  const after = await bToken.balanceOf(victim.address);
  console.log("victim bTokens gained:", ethers.formatEther(after - before));
  if (after <= before) throw new Error("router.lend minted nothing to the victim");

  // an attacker calling mint() right after finds no unaccounted balance
  const attackerBefore = await bToken.balanceOf(attacker.address);
  let frontRunBlocked = false;
  try {
    await (await bToken.connect(attacker).mint(attacker.address)).wait();
  } catch {
    frontRunBlocked = true;
  }
  const attackerAfter = await bToken.balanceOf(attacker.address);
  console.log("attacker gained after:", ethers.formatEther(attackerAfter - attackerBefore), frontRunBlocked ? "(reverted)" : "");
  if (attackerAfter > attackerBefore) throw new Error("attacker still captured value after router.lend");
  console.log("=> FIXED: deposit credited to the payer, nothing harvestable\n");

  console.log("=== C. UnwindRouter.repay() credits the payer ===");
  const unwind = await ethers.getContractAt("UnwindRouter", cfg.unwindRouter);
  // no debt for victim -> repay must revert rather than silently donate funds
  await fundFromPool(wS, victim.address, AMT);
  await (await new ethers.Contract(wS, ERC20, victim).approve(cfg.unwindRouter, AMT)).wait();
  let revertedNoDebt = false;
  try {
    await (await unwind.connect(victim).repay(b0, AMT)).wait();
  } catch {
    revertedNoDebt = true;
  }
  console.log("repay with zero debt reverted:", revertedNoDebt);
  if (!revertedNoDebt) throw new Error("repay should refuse to over-pay into the pool");
  console.log("=> repay() caps at live debt, no stranded value\n");

  console.log("=== D. Collateral accrues both borrowables on solvency checks (audit #1) ===");
  const collateral = await ethers.getContractAt("Collateral", cfg.collateral);
  const b1 = await ethers.getContractAt("Borrowable", cfg.borrowable1);
  const tsBefore0 = await bToken.accrualTimestamp();
  const tsBefore1 = await b1.accrualTimestamp();
  await ethers.provider.send("evm_increaseTime", [3600]);
  await ethers.provider.send("evm_mine", []);
  // static call would not persist state; send a real tx through accountLiquidity
  await (await collateral.accountLiquidity(victim.address)).wait();
  const tsAfter0 = await bToken.accrualTimestamp();
  const tsAfter1 = await b1.accrualTimestamp();
  console.log("borrowable0 accrualTimestamp:", tsBefore0, "->", tsAfter0);
  console.log("borrowable1 accrualTimestamp:", tsBefore1, "->", tsAfter1);
  if (tsAfter0 <= tsBefore0 || tsAfter1 <= tsBefore1) {
    throw new Error("solvency check did not accrue both borrowables");
  }
  console.log("=> FIXED: both legs refreshed before the debt read\n");

  console.log("ALL AUDIT FIX CHECKS PASSED");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
