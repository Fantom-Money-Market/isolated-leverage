import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

// Deploys a fresh StratusDLMMVault (Metropolis Liquidity Book) + Tarot lending pool for
// the wS/USSD binStep=10 pair (live METRO reward hook, part of Sonic's USSD bootstrap
// campaign) onto the already-running local fork, funds the user's real wallet with test
// tokens, and writes fork-ui/dlmm-config.json for the UI to read.
//   npx hardhat run scripts/fork-deploy-dlmm.ts --network localhost --config hardhat.config.fork-ui.ts

const LB_FACTORY = "0x39D966c1BaFe7D3F1F53dA4845805E15f7D6EE43";
const wS = "0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38";
const USSD = "0x000000000eCcFf26B795F73fb0A70d48da657fEf";
const METRO = "0x71E99522EaD5E21CF57F1f542Dc4ad2E841F7321";
const BIN_STEP = 10;
const PAIR = "0x361F55337074ae43957204CB30fFBAbbCe4Fb837"; // wS/USSD binStep=10, live METRO hook
// A DIFFERENT wS/USSD pair (binStep=20, no hook) used purely as a funding source. Using
// PAIR itself as the impersonation source was a real bug we hit: funds routed PAIR -> ...
// -> PAIR (deployer -> vault -> mint) net to a ZERO balance change on PAIR, so its
// internal `_reserves` never actually saw an increase and every mint() computed
// amountsReceived == 0, reverting LBPair__ZeroShares regardless of amounts/distribution
// math (confirmed via a `forge test -vvvv` trace). Funding from an unrelated pair avoids
// the round-trip entirely.
// Preferred funding source (wS/USSD binStep=20). Its reserves drift with real mainnet
// activity, so it is a PREFERENCE, not a constant — resolveFundingSource() below falls
// back to whichever sibling pair actually holds enough today. Hardcoding it meant the
// deploy broke the moment this pair's USSD drained below the seed amount.
const PREFERRED_FUNDING_SOURCE = "0x9e81415250996E5cE50B3E3FD99EE9964Dd53008";

// ALL funding must come from a source that is NOT PAIR. Pulling tokens out of PAIR leaves
// its ERC20 balance < LB's internal _reserves; the next vault mint() then reverts with
// PackedUint128Math__SubUnderflow on deployIdle/rebalance.
const SEED0 = ethers.parseEther("200"); // wS
const LEND_WS = ethers.parseEther("100");
const USER_WS = ethers.parseEther("20");
// USSD ceilings, not fixed amounts. Sibling-pair USSD liquidity is thin and drifts with
// mainnet, so the actual seed/lend legs are capped to what a source really holds today
// (see main) — a fixed 1.0 broke the deploy once the pairs drained below it.
const SEED1_MAX = ethers.parseEther("1");
const LEND_USSD_MAX = ethers.parseEther("1");

const USER = process.env.USER_ADDR || "0x0190933669d250406efcf18b351b954Ea88D5bfD";

const ERC20 = [
  "function approve(address,uint256) returns (bool)",
  "function transfer(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
];

async function fundFromSource(source: string, token: string, to: string, amount: bigint) {
  await ethers.provider.send("hardhat_impersonateAccount", [source]);
  await ethers.provider.send("hardhat_setBalance", [source, "0x21e19e0c9bab2400000"]); // 10000 S
  const s = await ethers.getSigner(source);
  await new ethers.Contract(token, ERC20, s).transfer(to, amount);
  await ethers.provider.send("hardhat_stopImpersonatingAccount", [source]);
}

/// Pick a whale for `token` that is NOT PAIR and actually holds `needed` today. Candidates
/// are the preferred pair plus every sibling wS/USSD LB pair, ranked by live balance —
/// mainnet drift silently emptied the hardcoded source and broke the deploy.
const fundingSourceCache = new Map<string, string>();

async function resolveFundingSource(token: string, needed: bigint): Promise<string> {
  const cached = fundingSourceCache.get(token.toLowerCase());
  if (cached) return cached;

  const lbFactory = new ethers.Contract(
    LB_FACTORY,
    ["function getAllLBPairs(address,address) view returns ((uint16,address,bool,bool)[])"],
    ethers.provider,
  );
  const pairs: string[] = (await lbFactory.getAllLBPairs(wS, USSD)).map((p: never[]) => p[1] as string);

  const candidates = [PREFERRED_FUNDING_SOURCE, ...pairs].filter(
    (a, i, arr) =>
      a.toLowerCase() !== PAIR.toLowerCase() && arr.findIndex((b) => b.toLowerCase() === a.toLowerCase()) === i,
  );

  const erc20 = new ethers.Contract(token, ERC20, ethers.provider);
  let best = "";
  let bestBal = 0n;
  for (const c of candidates) {
    const bal: bigint = await erc20.balanceOf(c);
    if (bal > bestBal) {
      bestBal = bal;
      best = c;
    }
  }
  if (!best || bestBal < needed) {
    throw new Error(
      `no funding source holds ${ethers.formatEther(needed)} of ${token} ` +
        `(best: ${best || "none"} with ${ethers.formatEther(bestBal)})`,
    );
  }
  console.log(`funding ${token === wS ? "wS" : "USSD"} from ${best} (holds ${ethers.formatEther(bestBal)})`);
  fundingSourceCache.set(token.toLowerCase(), best);
  return best;
}

const fundFromExternal = async (token: string, to: string, amount: bigint) =>
  fundFromSource(await resolveFundingSource(token, amount), token, to, amount);

async function main() {
  const [deployer, lender] = await ethers.getSigners();
  console.log("deployer:", deployer.address);

  const factory = await (
    await ethers.getContractFactory("StratusDLMMVaultFactory", deployer)
  ).deploy(LB_FACTORY, METRO);
  await factory.waitForDeployment();
  console.log("factory:", await factory.getAddress());

  // Budget the USSD legs against live availability (40% each, leaving headroom) rather
  // than assuming a fixed amount exists.
  const ussdSource = await resolveFundingSource(USSD, 0n);
  const ussdAvail: bigint = await new ethers.Contract(USSD, ERC20, ethers.provider).balanceOf(ussdSource);
  const cap = (want: bigint) => {
    const share = (ussdAvail * 40n) / 100n;
    return want < share ? want : share;
  };
  const seed1 = cap(SEED1_MAX);
  const lendUssd = cap(LEND_USSD_MAX);
  if (seed1 === 0n) throw new Error("no USSD liquidity available to seed the vault");
  console.log("USSD budget — seed:", ethers.formatEther(seed1), "lend:", ethers.formatEther(lendUssd));

  // --- seed + create vault (auto-resolves the hook from the pair) ---
  await fundFromExternal(wS, deployer.address, SEED0);
  await fundFromExternal(USSD, deployer.address, seed1);
  await new ethers.Contract(wS, ERC20, deployer).approve(await factory.getAddress(), SEED0);
  await new ethers.Contract(USSD, ERC20, deployer).approve(await factory.getAddress(), seed1);
  await (await factory.createVault(wS, USSD, BIN_STEP, 100, 10, SEED0, seed1)).wait();

  const vaultAddr = await factory.vaultForPair(PAIR);
  const vault = await ethers.getContractAt("StratusDLMMVault", vaultAddr);
  console.log("vault  :", vaultAddr);
  console.log("hook   :", await vault.hook());
  const binIds: bigint[] = await vault.getBinIds();
  console.log("binIds :", binIds.map((x) => x.toString()));

  // --- Tarot lending pool on top of the ALPT ---
  const BD = await (await ethers.getContractFactory("BDeployer", deployer)).deploy();
  await BD.waitForDeployment();
  const CD = await (await ethers.getContractFactory("CDeployer", deployer)).deploy();
  await CD.waitForDeployment();
  const tarot = await (
    await ethers.getContractFactory("TarotFactory", deployer)
  ).deploy(deployer.address, deployer.address, await BD.getAddress(), await CD.getAddress());
  await tarot.waitForDeployment();

  await (await tarot.createCollateral(vaultAddr)).wait();
  await (await tarot.createBorrowable0(vaultAddr)).wait();
  await (await tarot.createBorrowable1(vaultAddr)).wait();
  await (await tarot.initializeLendingPool(vaultAddr)).wait();
  const lp = await tarot.getLendingPool(vaultAddr);
  console.log("collateral :", lp.collateral);
  console.log("borrowable0:", lp.borrowable0, "(wS)");
  console.log("borrowable1:", lp.borrowable1, "(USSD)");

  // --- seed lender liquidity so borrows are actually possible ---
  await fundFromExternal(wS, lender.address, LEND_WS);
  await new ethers.Contract(wS, ERC20, lender).transfer(lp.borrowable0, LEND_WS);
  await (await (await ethers.getContractAt("Borrowable", lp.borrowable0, lender)).mint(lender.address)).wait();
  await fundFromExternal(USSD, lender.address, lendUssd);
  await new ethers.Contract(USSD, ERC20, lender).transfer(lp.borrowable1, lendUssd);
  await (await (await ethers.getContractAt("Borrowable", lp.borrowable1, lender)).mint(lender.address)).wait();

  // --- fund the real user wallet with test tokens + gas ---
  await ethers.provider.send("hardhat_setBalance", [USER, "0x1b27a8b3fb5be0989f"]); // ~500 S (keeps real balance)
  await fundFromExternal(wS, USER, USER_WS);
  // Whatever USSD the source has left after the seed and lend legs (capped at 1), so the
  // user can still test a two-sided deposit without over-drawing a thin source.
  const ussdLeft: bigint = await new ethers.Contract(USSD, ERC20, ethers.provider).balanceOf(ussdSource);
  const userUssd = ussdLeft < ethers.parseEther("1") ? (ussdLeft * 80n) / 100n : ethers.parseEther("1");
  if (userUssd > 0n) await fundFromExternal(USSD, USER, userUssd);
  console.log("funded user:", USER, "with", ethers.formatEther(userUssd), "USSD");

  // --- write config for the UI (reuses the shared routers from fork-ui/config.json) ---
  const mainCfgPath = path.join(__dirname, "..", "fork-ui", "config.json");
  const mainCfg = JSON.parse(fs.readFileSync(mainCfgPath, "utf8"));

  const config = {
    marketId: "ws-ussd-live-fork", // must match DLMM_MARKET_ID in the frontend's config/contracts.ts
    kind: "dlmm",
    lbFactory: LB_FACTORY,
    pair: PAIR,
    binStep: BIN_STEP,
    hook: await vault.hook(),
    factory: await factory.getAddress(),
    vault: vaultAddr,
    tarotFactory: await tarot.getAddress(),
    collateral: lp.collateral,
    borrowable0: lp.borrowable0,
    borrowable1: lp.borrowable1,
    leverageRouter: mainCfg.leverageRouter,
    unwindRouter: mainCfg.unwindRouter,
    tokens: {
      wS: { address: wS, symbol: "wS", decimals: 18 },
      USSD: { address: USSD, symbol: "USSD", decimals: 18 },
      METRO: { address: METRO, symbol: "METRO", decimals: 18 },
    },
  };

  const outDir = path.join(__dirname, "..", "fork-ui");
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, "dlmm-config.json"), JSON.stringify(config, null, 2));
  console.log("\nwrote fork-ui/dlmm-config.json");
  console.log(JSON.stringify(config, null, 2));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
