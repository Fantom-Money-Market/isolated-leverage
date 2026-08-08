import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

// Mirrors the supply modal's computeMinShares() and checks it on-chain:
//   1. the estimate is close enough to the real mint that an honest deposit passes at 1%
//   2. the floor is genuinely enforced (an over-tight floor reverts with Slippage)
//
//   npx hardhat run scripts/test-min-shares.ts --network localhost --config hardhat.config.fork-ui.ts

const ERC20 = [
  "function approve(address,uint256) returns (bool)",
  "function transfer(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
];
const WS_POOL = "0x324963c267C354c7660Ce8CA3F5f167E05649970";
const MINT_SLIPPAGE_BPS = 100n; // keep in sync with lp-supply-modal.tsx
const ONE = 10n ** 18n;

async function fundFromPool(token: string, to: string, amount: bigint) {
  await ethers.provider.send("hardhat_impersonateAccount", [WS_POOL]);
  await ethers.provider.send("hardhat_setBalance", [WS_POOL, "0x21e19e0c9bab2400000"]);
  const s = await ethers.getSigner(WS_POOL);
  await new ethers.Contract(token, ERC20, s).transfer(to, amount);
  await ethers.provider.send("hardhat_stopImpersonatingAccount", [WS_POOL]);
}

async function main() {
  const cfg = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "fork-ui", "config.json"), "utf8"));
  const [, , , , , , user] = await ethers.getSigners();
  const vault = await ethers.getContractAt("StratusShadowVault", cfg.vault);
  const collateral = await ethers.getContractAt("Collateral", cfg.collateral);
  const router = await ethers.getContractAt("LeverageRouter", cfg.leverageRouter, user);

  const t0Addr: string = await vault.token0();
  const amount0 = ethers.parseEther("10");
  await fundFromPool(t0Addr, user.address, amount0 * 2n);

  // --- replicate computeMinShares() ---
  const supply: bigint = await vault.totalSupply();
  const price0in1: bigint = await vault.twapPrice();
  const depositValue1 = 0n + (amount0 * price0in1) / ONE;
  const expected: bigint = await vault.convertToShares(depositValue1);
  const minShares = (expected * (10000n - MINT_SLIPPAGE_BPS)) / 10000n;
  console.log("supply          :", supply.toString());
  console.log("ALPT decimals   :", (await vault.decimals()).toString());
  console.log("depositValue1   :", depositValue1.toString());
  console.log("estimated shares:", expected.toString());
  console.log("minShares (1%)  :", minShares.toString());

  // --- 1. honest deposit must pass at that floor ---
  const cBefore: bigint = await collateral.balanceOf(user.address);
  await (await new ethers.Contract(t0Addr, ERC20, user).approve(cfg.leverageRouter, amount0)).wait();
  await (await router.leverage(cfg.collateral, amount0, 0, 0, 0, minShares)).wait();
  const cAfter: bigint = await collateral.balanceOf(user.address);
  console.log("\nhonest deposit at 1% floor: OK");

  // How close was the estimate? cTokens are not vault shares 1:1, so compare the vault
  // shares the router actually minted via the collateral exchange rate.
  const rate: bigint = await collateral.exchangeRate.staticCall();
  const actualShares = ((cAfter - cBefore) * rate) / ONE;
  const driftBps = expected > 0n ? ((expected - actualShares) * 10000n) / expected : 0n;
  console.log("actual shares   :", actualShares.toString());
  console.log("estimate drift  :", driftBps.toString(), "bps (must stay well inside", MINT_SLIPPAGE_BPS.toString() + ")");
  if (driftBps >= MINT_SLIPPAGE_BPS) {
    throw new Error("estimate drifts past the tolerance — honest deposits would revert");
  }

  // --- 2. the floor must actually bind ---
  await (await new ethers.Contract(t0Addr, ERC20, user).approve(cfg.leverageRouter, amount0)).wait();
  let rejected = false;
  try {
    await (await router.leverage(cfg.collateral, amount0, 0, 0, 0, expected * 2n)).wait();
  } catch {
    rejected = true;
  }
  console.log("\nimpossible floor rejected:", rejected);
  if (!rejected) throw new Error("minShares was not enforced");

  // --- 3. Beets adapter uses the fallback branch (no convertToShares). A one-sided add
  //        pays Balancer composition fees, so confirm that stays inside the tolerance. ---
  const beetsCfg = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "fork-ui", "beets-config.json"), "utf8"));
  const adapter = await ethers.getContractAt("StratusBeetsV3Adapter", beetsCfg.adapter, user);
  const bWs = beetsCfg.tokens.wS.address;
  const bAmt = ethers.parseEther("20");
  await fundFromPool(bWs, user.address, bAmt);

  const isWsT0 = (await adapter.token0()).toLowerCase() === bWs.toLowerCase();

  // A fresh adapter has zero supply, so pricePerShareSafe() is 0 and no floor is
  // computable — the frontend returns 0 there (bootstrap: nothing to protect). Seed it
  // once so the estimate below is exercised the way a real second deposit would be.
  if ((await adapter.totalSupply()) === 0n) {
    const seed = ethers.parseEther("10");
    await fundFromPool(bWs, user.address, seed);
    await (await new ethers.Contract(bWs, ERC20, user).approve(beetsCfg.adapter, seed)).wait();
    await (await adapter.deposit(isWsT0 ? seed : 0n, isWsT0 ? 0n : seed, user.address, 0)).wait();
    console.log("\nseeded Beets adapter (was empty; frontend would pass a 0 floor there)");
  }

  const bPrice: bigint = await adapter.twapPrice();
  const bDec: bigint = BigInt(await adapter.decimals());
  const bPps: bigint = await adapter.pricePerShareSafe();
  if (bPps === 0n) throw new Error("adapter still unpriced after seeding");
  const bValue1 = isWsT0 ? (bAmt * bPrice) / ONE : bAmt;
  const bExpected = (bValue1 * 10n ** bDec) / bPps;

  const bBefore: bigint = await adapter.balanceOf(user.address);
  await (await new ethers.Contract(bWs, ERC20, user).approve(beetsCfg.adapter, bAmt)).wait();
  await (await adapter.deposit(isWsT0 ? bAmt : 0n, isWsT0 ? 0n : bAmt, user.address, 0)).wait();
  const bActual: bigint = (await adapter.balanceOf(user.address)) - bBefore;
  const bDrift = bExpected > 0n ? ((bExpected - bActual) * 10000n) / bExpected : 0n;
  console.log("\nBeets fallback estimate:", bExpected.toString());
  console.log("Beets actual BPT       :", bActual.toString());
  console.log("Beets drift            :", bDrift.toString(), "bps (one-sided add pays composition fees)");
  if (bDrift >= MINT_SLIPPAGE_BPS) {
    throw new Error(`Beets one-sided add drifts ${bDrift} bps — past the ${MINT_SLIPPAGE_BPS} bps floor, deposits would revert`);
  }

  console.log("\nMIN-SHARES FLOOR CHECKS PASSED");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
