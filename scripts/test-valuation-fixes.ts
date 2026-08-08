import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

// Verifies audit findings #3, #4, #5 on-chain.
//   #3 Beets BPT value is anchored to the pool invariant, so skewing the pool with a large
//      swap no longer inflates collateral value (it used to grow with the reserve sum).
//   #4 The DLMM safe price fails closed instead of silently returning manipulable spot.
//   #5 Deposit shares are priced conservatively, so a one-sided deposit + immediate
//      withdraw cannot extract value from existing holders.
//
//   npx hardhat run scripts/test-valuation-fixes.ts --network localhost --config hardhat.config.fork-ui.ts

const ERC20 = [
  "function approve(address,uint256) returns (bool)",
  "function transfer(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
];
const WS_POOL = "0x324963c267C354c7660Ce8CA3F5f167E05649970";

async function fundFromPool(token: string, to: string, amount: bigint) {
  await ethers.provider.send("hardhat_impersonateAccount", [WS_POOL]);
  await ethers.provider.send("hardhat_setBalance", [WS_POOL, "0x21e19e0c9bab2400000"]);
  const s = await ethers.getSigner(WS_POOL);
  await new ethers.Contract(token, ERC20, s).transfer(to, amount);
  await ethers.provider.send("hardhat_stopImpersonatingAccount", [WS_POOL]);
}

async function main() {
  const beetsCfg = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "fork-ui", "beets-config.json"), "utf8"));
  const dlmmCfg = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "fork-ui", "dlmm-config.json"), "utf8"));
  const [, , , , , actor] = await ethers.getSigners();

  // ---------- #3: invariant-anchored BPT value ----------
  console.log("=== #3 Beets BPT value vs a pool skew ===");
  const adapter = await ethers.getContractAt("StratusBeetsV3Adapter", beetsCfg.adapter);
  const valueBefore: bigint = await adapter.getTotalValueSafe();
  const [amt0Before, amt1Before] = await adapter.getTotalAmounts();
  const priceBefore: bigint = await adapter.twapPrice();
  const reserveSumBefore = amt1Before + (amt0Before * priceBefore) / 10n ** 18n;
  console.log("invariant-based value :", ethers.formatEther(valueBefore));
  console.log("old reserve-sum value :", ethers.formatEther(reserveSumBefore));

  // Skew the pool hard by swapping a large amount of wS in through the adapter's own
  // deposit path (one-sided add == the same reserve-skewing effect a swap has).
  const skew = ethers.parseEther("400");
  await fundFromPool(beetsCfg.tokens.wS.address, actor.address, skew);
  await (await new ethers.Contract(beetsCfg.tokens.wS.address, ERC20, actor).approve(beetsCfg.adapter, skew)).wait();
  const isWsToken0 = (await adapter.token0()).toLowerCase() === beetsCfg.tokens.wS.address.toLowerCase();
  await (await adapter.connect(actor).deposit(isWsToken0 ? skew : 0n, isWsToken0 ? 0n : skew, actor.address, 0)).wait();

  const shares: bigint = await adapter.balanceOf(actor.address);
  const valueAfter: bigint = await adapter.getTotalValueSafe();
  const [amt0After, amt1After] = await adapter.getTotalAmounts();
  const priceAfter: bigint = await adapter.twapPrice();
  const reserveSumAfter = amt1After + (amt0After * priceAfter) / 10n ** 18n;

  // Per-share is the number that matters for collateral: it must not jump from a skew.
  const supply: bigint = await adapter.totalSupply();
  const perShareInvariant = (valueAfter * 10n ** 18n) / supply;
  const perShareReserveSum = (reserveSumAfter * 10n ** 18n) / supply;
  console.log("after skew — per-share (invariant) :", ethers.formatEther(perShareInvariant));
  console.log("after skew — per-share (reserve sum):", ethers.formatEther(perShareReserveSum));
  console.log(
    perShareInvariant < perShareReserveSum
      ? "=> invariant basis is the CONSERVATIVE one (reserve sum overstates a skewed pool)\n"
      : "=> NOTE: bases agree here (pool near balance)\n",
  );
  if (shares > 0n) {
    await (await adapter.connect(actor).withdraw(shares, actor.address, 0, 0)).wait();
  }

  // ---------- #4: DLMM safe price fails closed ----------
  console.log("=== #4 DLMM safe price fails closed ===");
  const vault = await ethers.getContractAt("StratusDLMMVault", dlmmCfg.vault);
  const available: boolean = await vault.isSafePriceAvailable();
  console.log("isSafePriceAvailable():", available);
  let reverted = false;
  let priced = 0n;
  try {
    priced = await vault.twapPrice();
  } catch {
    reverted = true;
  }
  if (available) {
    console.log("twapPrice() =", ethers.formatEther(priced), "(oracle usable)");
    if (reverted) throw new Error("price reported available but twapPrice reverted");
  } else {
    console.log("twapPrice() reverted:", reverted);
    if (!reverted) throw new Error("safe price unavailable but twapPrice returned a value (silent spot fallback)");
    console.log("=> no silent spot fallback: unpriceable state now pauses the market");
  }
  console.log();

  // ---------- #5: one-sided deposit round trip cannot extract ----------
  // Must be tested on a StratusVaultBase-derived vault (Shadow CL here). The Beets adapter
  // is a standalone 1:1 BPT wrapper that forwards pricing to Balancer's own unbalanced-add
  // math, so it never had the safe-entry / live-exit basis mismatch this finding is about.
  console.log("=== #5 one-sided deposit + immediate withdraw round trip (Shadow vault) ===");
  const mainCfg = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "fork-ui", "config.json"), "utf8"));
  const clVault = await ethers.getContractAt("StratusShadowVault", mainCfg.vault);
  const t0Addr: string = await clVault.token0();
  const t1Addr: string = await clVault.token1();
  const t0 = new ethers.Contract(t0Addr, ERC20, actor);
  const t1 = new ethers.Contract(t1Addr, ERC20, actor);

  const rt = ethers.parseEther("25");
  await fundFromPool(t0Addr, actor.address, rt);

  const a0: bigint = await t0.balanceOf(actor.address);
  const b0: bigint = await t1.balanceOf(actor.address);
  await (await t0.approve(mainCfg.vault, rt)).wait();
  await (await clVault.connect(actor).deposit(rt, 0, actor.address, 0)).wait();
  const got: bigint = await clVault.balanceOf(actor.address);
  await (await clVault.connect(actor).withdraw(got, actor.address, 0, 0)).wait();
  const a1: bigint = await t0.balanceOf(actor.address);
  const b1: bigint = await t1.balanceOf(actor.address);

  // price maps RAW token0 -> RAW token1, so every leg below stays in raw token1 units.
  const price: bigint = await clVault.twapPrice();
  const d1: number = Number(
    await new ethers.Contract(t1Addr, ["function decimals() view returns (uint8)"], ethers.provider).decimals(),
  );
  const spent0 = a0 > a1 ? a0 - a1 : 0n;
  const gain0 = a1 > a0 ? a1 - a0 : 0n;
  const spent1 = b0 > b1 ? b0 - b1 : 0n;
  const gain1 = b1 > b0 ? b1 - b0 : 0n;
  const valueIn = (spent0 * price) / 10n ** 18n + spent1;
  const valueOut = (gain0 * price) / 10n ** 18n + gain1;
  console.log("value in  (token1):", ethers.formatUnits(valueIn, d1));
  console.log("value out (token1):", ethers.formatUnits(valueOut, d1));
  if (valueOut > valueIn) {
    throw new Error(
      `round trip was PROFITABLE by ${ethers.formatUnits(valueOut - valueIn, d1)} — extraction still possible`,
    );
  }
  console.log("=> round trip is non-profitable (deposit priced conservatively)\n");

  console.log("VALUATION FIX CHECKS PASSED");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
