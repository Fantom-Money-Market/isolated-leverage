import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

// Second-round adversarial tests: findings we went looking for OURSELVES after the paid
// audit, plus proof each fix actually blocks the thing it claims to.
//
// Each section REPRODUCES the bug first (or shows the exact precondition that produced it)
// and only then asserts the fix, so a passing run is evidence and not just absence of error.
//
//   npx hardhat run scripts/test-adversarial-round2.ts --network localhost --config hardhat.config.fork-ui.ts

const ERC20 = [
  "function transfer(address,uint256) returns (bool)",
  "function approve(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
];
const LB_PAIR_ABI = [
  "function swap(bool swapForY, address to) returns (bytes32)",
  "function getTokenX() view returns (address)",
  "function getActiveId() view returns (uint24)",
];
const HOOK_ABI = [
  "function owner() view returns (address)",
  "function setDeltaBins(int24,int24)",
  "function getRewardedRange() view returns (uint256,uint256)",
];
const WS_POOL = "0x324963c267C354c7660Ce8CA3F5f167E05649970";
const ONE = 10n ** 18n;

let cfg: any;
const failures: string[] = [];

function check(name: string, ok: boolean, detail = "") {
  console.log(`   ${ok ? "PASS" : "FAIL"}  ${name}${detail ? " — " + detail : ""}`);
  if (!ok) failures.push(name);
}

async function fund(token: string, to: string, amount: bigint) {
  await fundFrom(WS_POOL, token, to, amount);
}

async function fundFrom(source: string, token: string, to: string, amount: bigint) {
  await ethers.provider.send("hardhat_impersonateAccount", [source]);
  await ethers.provider.send("hardhat_setBalance", [source, "0x21e19e0c9bab2400000"]);
  const w = await ethers.getSigner(source);
  await (await new ethers.Contract(token, ERC20, w).transfer(to, amount)).wait();
  await ethers.provider.send("hardhat_stopImpersonatingAccount", [source]);
}

/** Richest holder of `token` among the sibling wS/USSD LB pairs, excluding our own pair. */
async function findWhale(token: string): Promise<{ addr: string; bal: bigint }> {
  const lbFactory = new ethers.Contract(
    cfg.lbFactory,
    ["function getAllLBPairs(address,address) view returns ((uint16,address,bool,bool)[])"],
    ethers.provider
  );
  const pairs: string[] = (await lbFactory.getAllLBPairs(cfg.tokens.wS.address, cfg.tokens.USSD.address)).map(
    (p: any) => p[1] as string
  );
  const erc20 = new ethers.Contract(token, ERC20, ethers.provider);
  let addr = "";
  let bal = 0n;
  for (const c of [WS_POOL, ...pairs]) {
    if (c.toLowerCase() === cfg.pair.toLowerCase()) continue;
    const b: bigint = await erc20.balanceOf(c);
    if (b > bal) {
      bal = b;
      addr = c;
    }
  }
  return { addr, bal };
}

/** Write a fresh LB oracle sample so the vault's fail-closed safe price becomes available. */
async function warmOracle(signer: any) {
  await ethers.provider.send("evm_increaseTime", [1900]);
  await ethers.provider.send("evm_mine", []);
  const amt = ethers.parseEther("1");
  await fund(cfg.tokens.wS.address, cfg.pair, amt);
  const pair = new ethers.Contract(cfg.pair, LB_PAIR_ABI, signer);
  const tokenX: string = await pair.getTokenX();
  await (await pair.swap(tokenX.toLowerCase() === cfg.tokens.wS.address.toLowerCase(), signer.address)).wait();
  await ethers.provider.send("evm_increaseTime", [30]);
  await ethers.provider.send("evm_mine", []);
}


/**
 * Move the active bin by at least `minBins`, choosing the side that actually has depth.
 * The wS/USSD pair is deep in wS and thin in USSD, so swapping wS IN can only walk the
 * price a bin or two before it runs out of USSD to pay out; pushing USSD in walks it the
 * other way against 300k+ wS of depth.
 */
async function pushActiveBin(signer: any, minBins: number): Promise<number> {
  const pair = new ethers.Contract(cfg.pair, LB_PAIR_ABI, signer);
  const tokenX: string = await pair.getTokenX();
  const wsIsX = tokenX.toLowerCase() === cfg.tokens.wS.address.toLowerCase();
  const start: bigint = await pair.getActiveId();

  const ussd = await findWhale(cfg.tokens.USSD.address);
  const attempts: { token: string; source: string; amount: bigint; forY: boolean }[] = [];
  if (ussd.addr) {
    // USSD in -> wS out. swapForY is false when USSD is the Y token.
    for (const frac of [10n, 4n, 2n]) {
      attempts.push({
        token: cfg.tokens.USSD.address,
        source: ussd.addr,
        amount: ussd.bal / frac,
        forY: !wsIsX ? true : false,
      });
    }
  }
  for (const size of ["500", "2000", "5000", "10000", "15000", "25000"]) {
    attempts.push({ token: cfg.tokens.wS.address, source: WS_POOL, amount: ethers.parseEther(size), forY: wsIsX });
  }

  for (const a of attempts) {
    if (a.amount === 0n) continue;
    // Snapshot around transfer+swap. LB derives amountIn from `balance - reserves`, so
    // tokens sent in for a swap that then REVERTS stay behind as unaccounted surplus and
    // every later swap tries to consume them too — which is exactly how an earlier run of
    // this script wedged the fork. Rolling back on failure keeps each attempt atomic.
    const snap = await ethers.provider.send("evm_snapshot", []);
    try {
      await fundFrom(a.source, a.token, cfg.pair, a.amount);
      await (await pair.swap(a.forY, signer.address)).wait();
    } catch {
      await ethers.provider.send("evm_revert", [snap]);
      continue;
    }
    const now: bigint = await pair.getActiveId();
    const moved = Number(now > start ? now - start : start - now);
    if (moved >= minBins) return moved;
  }
  const end: bigint = await pair.getActiveId();
  return Number(end > start ? end - start : start - end);
}

// ---------------------------------------------------------------------------
// 1. Performance-fee checkpoint must SEED, not tax, the first observable value.
// ---------------------------------------------------------------------------
async function testFeeCheckpoint(signer: any) {
  console.log("\n[1] performance fee tracks value PER SHARE, not total value");
  const vault = await ethers.getContractAt("StratusDLMMVault", cfg.vault);
  const factory: string = await vault.factory();

  await warmOracle(signer);
  check("safe price available after warmup", await vault.isSafePriceAvailable());

  const tvl: bigint = await vault.getTotalValueSafe();
  const supplyBefore: bigint = await vault.totalSupply();
  const feePct: bigint = BigInt(await vault.protocolFee());
  const factoryBefore: bigint = await vault.balanceOf(factory);
  console.log(`   TVL ${ethers.formatEther(tvl)} | supply ${supplyBefore}`);
  check(
    "factory was NOT handed a slice of the seed TVL",
    (factoryBefore * 10000n) / supplyBefore < 1n,
    `${factoryBefore} shares`
  );

  // The old total-value model read the whole vault as growth above a zero checkpoint.
  const wouldHaveMinted = ((tvl * feePct) / 100n) * (supplyBefore + 1000000n) / (tvl + 1n);
  console.log(`   total-value model would have minted ${wouldHaveMinted} shares to the factory`);
  console.log(`   = ${(Number(wouldHaveMinted) / Number(supplyBefore) * 100).toFixed(2)}% of supply, taken from depositors`);

  // Now the second failure mode: a DEPOSIT raises total value but not value per share.
  const isT0 = (await vault.token0()).toLowerCase() === cfg.tokens.wS.address.toLowerCase();
  const dep = ethers.parseEther("25");
  await fund(cfg.tokens.wS.address, signer.address, dep);
  await (await new ethers.Contract(cfg.tokens.wS.address, ERC20, signer).approve(cfg.vault, dep)).wait();
  await (await vault.connect(signer).deposit(isT0 ? dep : 0n, isT0 ? 0n : dep, signer.address, 0)).wait();

  // A second interaction is what actually charges the fee on the first deposit's value.
  const dep2 = ethers.parseEther("5");
  await fund(cfg.tokens.wS.address, signer.address, dep2);
  await (await new ethers.Contract(cfg.tokens.wS.address, ERC20, signer).approve(cfg.vault, dep2)).wait();
  await (await vault.connect(signer).deposit(isT0 ? dep2 : 0n, isT0 ? 0n : dep2, signer.address, 0)).wait();

  const factoryAfter: bigint = await vault.balanceOf(factory);
  const supplyAfter: bigint = await vault.totalSupply();
  const mintedOnDeposits = factoryAfter - factoryBefore;
  const bps = (mintedOnDeposits * 10000n) / supplyAfter;
  const depositTax = (mintedOnDeposits * 10000n) / (supplyAfter - supplyBefore);
  console.log(`   fee minted across two deposits: ${mintedOnDeposits} shares (${bps} bps of supply)`);
  console.log(`   as a share of the NEW shares those deposits created: ${depositTax} bps`);
  check("high-water mark got seeded once a safe price existed", (await vault.lastPricePerShare()) > 0n);
  check(
    "deposits are not taxed as growth (< 10 bps of deposited shares)",
    depositTax < 10n,
    `${depositTax} bps — a total-value mark would show ~1000`
  );
}

// ---------------------------------------------------------------------------
// 2. A third party widening the hook's rewarded range must not brick the vault.
// ---------------------------------------------------------------------------
async function testBinWindowCap(signer: any) {
  console.log("\n[2] rewarded range from the hook cannot blow up binIds");
  const vault = await ethers.getContractAt("StratusDLMMVault", cfg.vault);
  const hook = new ethers.Contract(cfg.hook, HOOK_ABI, ethers.provider);

  console.log(`   binIds before: ${(await vault.getBinIds()).length} bins`);

  let owner: string;
  try {
    owner = await hook.owner();
  } catch {
    console.log("   SKIP — hook exposes no owner() on this fork");
    return;
  }

  // Metropolis' own rewarder refuses a range wider than MAX_NUMBER_OF_BINS = 11
  // (LBHooksBaseRewarder__ExceedsMaxNumberOfBins, selector 0xbe0ae43b). So the widest an
  // attacker-or-careless-owner can actually make it TODAY is 11 — drive it to exactly that
  // and confirm our own window still stays inside its cap. Our clamp is defence in depth
  // against a future rewarder without that internal limit.
  await ethers.provider.send("hardhat_impersonateAccount", [owner]);
  await ethers.provider.send("hardhat_setBalance", [owner, "0x21e19e0c9bab2400000"]);
  const ownerSigner = await ethers.getSigner(owner);
  const hookAsOwner = new ethers.Contract(cfg.hook, HOOK_ABI, ownerSigner);
  let widened = 0;
  for (const d of [20, 11, 6, 5]) {
    try {
      await (await hookAsOwner.setDeltaBins(-d, d)).wait();
      widened = 2 * d;
      break;
    } catch {
      /* wider than the hook's own MAX_NUMBER_OF_BINS — step down */
    }
  }
  await ethers.provider.send("hardhat_stopImpersonatingAccount", [owner]);
  if (widened === 0) {
    console.log("   SKIP — hook refused every delta we tried");
    return;
  }

  const [rs, re] = await hook.getRewardedRange();
  const advertised = re - rs + 1n;
  console.log(`   hook widened to its own maximum: rewarded range now ${advertised} bins`);
  check("hook enforces its own cap (<= 12 bins)", advertised <= 12n, `${advertised} bins`);

  const factoryAddr: string = await vault.factory();
  await ethers.provider.send("hardhat_impersonateAccount", [factoryAddr]);
  await ethers.provider.send("hardhat_setBalance", [factoryAddr, "0x21e19e0c9bab2400000"]);
  const fSigner = await ethers.getSigner(factoryAddr);
  await (await vault.connect(fSigner).deployIdle()).wait();
  await ethers.provider.send("hardhat_stopImpersonatingAccount", [factoryAddr]);

  const after: bigint[] = await vault.getBinIds();
  console.log(`   binIds after : ${after.length} bins`);
  check("bin window stayed inside our cap (<= 25)", after.length <= 25, `${after.length} bins`);

  // The property that actually matters: holders can still get out.
  const bal: bigint = await vault.balanceOf(signer.address);
  if (bal > 0n) {
    const gas = await vault.connect(signer).withdraw.estimateGas(bal / 2n, signer.address, 0, 0);
    check("withdraw still fits in a block", gas < 20_000_000n, `${gas} gas`);
    await (await vault.connect(signer).withdraw(bal / 2n, signer.address, 0, 0)).wait();
    check("withdraw actually succeeded", true);
  } else {
    console.log("   (no vault shares held by the test user; skipped the withdraw probe)");
  }
}

// ---------------------------------------------------------------------------
// 3. Permissionless rebalance must not be spammable.
// ---------------------------------------------------------------------------
async function testRebalanceGate(signer: any) {
  console.log("\n[3] permissionless rebalance is gated on value out of position (no clock)");
  const vault = await ethers.getContractAt("StratusDLMMVault", cfg.vault);

  // Baseline: recenter via the factory path so the window starts aligned.
  const factoryAddr: string = await vault.factory();
  await ethers.provider.send("hardhat_impersonateAccount", [factoryAddr]);
  await ethers.provider.send("hardhat_setBalance", [factoryAddr, "0x21e19e0c9bab2400000"]);
  await (await vault.connect(await ethers.getSigner(factoryAddr)).deployIdle()).wait();
  await ethers.provider.send("hardhat_stopImpersonatingAccount", [factoryAddr]);

  check("aligned window is not rebalanceable", (await vault.needsRebalance()) === false);
  let reverted = false;
  try {
    await (await vault.connect(signer).rebalance()).wait();
  } catch {
    reverted = true;
  }
  check("rebalance() reverts (NotDrifted)", reverted);

  // The griefing move: nudge the active bin one step with a cheap swap and try to force a
  // full burn+remint. Too little of the position has moved out of the window to justify
  // paying composition fees, so the gate must stay shut.
  const small = await pushActiveBin(signer, 1);
  console.log(`   nudged the active bin ${small} bin(s)`);
  check("a one-bin nudge does not open the gate", (await vault.needsRebalance()) === false);
  let reverted2 = false;
  try {
    await (await vault.connect(signer).rebalance()).wait();
  } catch {
    reverted2 = true;
  }
  check("rebalance() after a nudge is still refused", reverted2);

  // Now a genuine move. The gate must open on the DISPLACEMENT ALONE — checked in the very
  // next call, with no time advanced anywhere in between. That is the whole point of
  // dropping the cooldown: a vault whose liquidity has left the window is stranded and
  // earning nothing, and must be re-centrable immediately rather than on a timer.
  const tsBefore = (await ethers.provider.getBlock("latest"))!.timestamp;
  const moved = await pushActiveBin(signer, 5);
  console.log(`   pushed the active bin ${moved} bins total`);
  check("swap displaced the position", moved >= 4, `${moved} bins`);

  const open = await vault.needsRebalance();
  check("gate opens on displacement alone", open === true);
  if (open) {
    await (await vault.connect(signer).rebalance()).wait();
    const tsAfter = (await ethers.provider.getBlock("latest"))!.timestamp;
    console.log(`   rebalance() succeeded ${tsAfter - tsBefore}s after the previous one`);
    check("no cooldown was required", tsAfter - tsBefore < 3600, `${tsAfter - tsBefore}s elapsed`);
    check("window re-centred, gate shut again", (await vault.needsRebalance()) === false);
  }
}

// ---------------------------------------------------------------------------
// 4. Borrowable.redeem is the same caller-chosen-beneficiary hole as audit #2's mint.
// ---------------------------------------------------------------------------
async function testUnlendAtomicity(signers: any[]) {
  console.log("\n[4] lend-side exit: two-step redeem is snipeable, unlend() is not");
  const [, , , , , , lender, attacker] = signers;
  const borrowable = cfg.borrowable0;
  const b = await ethers.getContractAt("Borrowable", borrowable);
  const underlying: string = await b.underlying();
  const router = await ethers.getContractAt("UnwindRouter", cfg.unwindRouter);
  const lev = await ethers.getContractAt("LeverageRouter", cfg.leverageRouter);

  // Give the lender a lend position via the atomic lend() we already shipped.
  const amt = ethers.parseEther("20");
  await fund(underlying, lender.address, amt * 2n);
  await (await new ethers.Contract(underlying, ERC20, lender).approve(cfg.leverageRouter, amt * 2n)).wait();
  await (await lev.connect(lender).lend(borrowable, amt)).wait();
  const bTokens: bigint = await b.balanceOf(lender.address);
  console.log(`   lender holds ${bTokens} bTokens`);

  // --- reproduce the bug: transfer-then-redeem, sniped in between ---
  const half = bTokens / 2n;
  await (await b.connect(lender).transfer(borrowable, half)).wait();
  const attackerBefore: bigint = await new ethers.Contract(underlying, ERC20, ethers.provider).balanceOf(attacker.address);
  await (await b.connect(attacker).redeem(attacker.address)).wait();
  const stolen: bigint = (await new ethers.Contract(underlying, ERC20, ethers.provider).balanceOf(attacker.address)) - attackerBefore;
  console.log(`   attacker called redeem(self) on the pending transfer: took ${ethers.formatEther(stolen)}`);
  check("BUG REPRODUCED: two-step redeem is snipeable", stolen > 0n, `${ethers.formatEther(stolen)} underlying`);

  // --- the fix: unlend() does both halves in one call ---
  const rest: bigint = await b.balanceOf(lender.address);
  await (await b.connect(lender).approve(cfg.unwindRouter, rest)).wait();
  const lenderBefore: bigint = await new ethers.Contract(underlying, ERC20, ethers.provider).balanceOf(lender.address);
  await (await router.connect(lender).unlend(borrowable, rest)).wait();
  const got: bigint = (await new ethers.Contract(underlying, ERC20, ethers.provider).balanceOf(lender.address)) - lenderBefore;
  console.log(`   unlend() returned ${ethers.formatEther(got)} to the lender`);
  check("unlend() pays the caller, atomically", got > 0n);
  check("no bTokens stranded on the borrowable", (await b.balanceOf(borrowable)) === 0n);
}


// ---------------------------------------------------------------------------
// 5. With a live reward hook the protocol fee must be skimmed in METRO, never
//    minted as shares — minting marks down ALPT collateral for every borrower.
// ---------------------------------------------------------------------------
async function testFeeComesFromRewards(signer: any) {
  console.log("\n[5] with a gauge live, the fee is skimmed in rewards, not minted");
  const vault = await ethers.getContractAt("StratusDLMMVault", cfg.vault);
  const factory: string = await vault.factory();
  const metro = new ethers.Contract(cfg.tokens.METRO.address, ERC20, ethers.provider);
  const hook = new ethers.Contract(cfg.hook, HOOK_ABI, ethers.provider);

  check("reward hook is attached and running", (await hook.isStopped()) === false);

  const sharesBefore: bigint = await vault.balanceOf(factory);
  const metroBefore: bigint = await metro.balanceOf(factory);
  const supplyBefore: bigint = await vault.totalSupply();
  const ppsBefore: bigint = await vault.pricePerShareSafe();

  // Let emissions accrue, then force a harvest through a real user action.
  await ethers.provider.send("evm_increaseTime", [6 * 3600]);
  await ethers.provider.send("evm_mine", []);
  await warmOracle(signer);

  const isT0 = (await vault.token0()).toLowerCase() === cfg.tokens.wS.address.toLowerCase();
  const dep = ethers.parseEther("5");
  await fund(cfg.tokens.wS.address, signer.address, dep);
  await (await new ethers.Contract(cfg.tokens.wS.address, ERC20, signer).approve(cfg.vault, dep)).wait();
  await (await vault.connect(signer).deposit(isT0 ? dep : 0n, isT0 ? 0n : dep, signer.address, 0)).wait();

  const metroGained = (await metro.balanceOf(factory)) - metroBefore;
  const sharesGained = (await vault.balanceOf(factory)) - sharesBefore;
  const ppsAfter: bigint = await vault.pricePerShareSafe();
  console.log(`   factory METRO  +${ethers.formatEther(metroGained)}`);
  console.log(`   factory shares +${sharesGained}`);
  console.log(`   pricePerShareSafe ${ppsBefore} -> ${ppsAfter}`);

  check("protocol fee arrived as METRO", metroGained > 0n, `${ethers.formatEther(metroGained)} METRO`);
  check("protocol fee minted NO shares", sharesGained === 0n, `${sharesGained} shares`);
  // The property that actually matters downstream: Collateral.getPrices() reads
  // totalSupply/getTotalValueSafe, so a fee mint would mark down every borrow.
  check("share value not diluted by the fee", ppsAfter >= ppsBefore, `${ppsBefore} -> ${ppsAfter}`);
  console.log(`   supply ${supplyBefore} -> ${await vault.totalSupply()} (deposit only, no fee shares)`);
}

async function main() {
  cfg = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "fork-ui", "dlmm-config.json"), "utf8"));
  const signers = await ethers.getSigners();
  const user = signers[6];

  // These tests deliberately do destructive things — draining one side of a real forked
  // pool, warping hours, impersonating a third-party hook owner. Snapshot the whole run and
  // roll it back so the shared fork the UI runs against is left exactly as we found it, and
  // so the suite is re-runnable without a redeploy.
  const snap = await ethers.provider.send("evm_snapshot", []);
  try {
    await testFeeCheckpoint(user);
    await testRebalanceGate(user);
    await testBinWindowCap(user);
    await testUnlendAtomicity(signers);
    await testFeeComesFromRewards(user);
  } finally {
    await ethers.provider.send("evm_revert", [snap]);
    console.log("\n(fork state rolled back to pre-test snapshot)");
  }

  console.log("\n" + "=".repeat(60));
  if (failures.length) {
    console.log("FAILURES:\n - " + failures.join("\n - "));
    process.exit(1);
  }
  console.log("ALL ROUND-2 ADVERSARIAL CHECKS PASSED");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
