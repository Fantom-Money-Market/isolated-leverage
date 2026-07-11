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
const FUNDING_SOURCE = "0x9e81415250996E5cE50B3E3FD99EE9964Dd53008"; // wS/USSD binStep=20

// ALL funding must come from FUNDING_SOURCE (binStep=20), NEVER from PAIR. Pulling tokens
// out of PAIR leaves ERC20 balance < LB's internal _reserves; the next vault mint() then
// reverts with PackedUint128Math__SubUnderflow on deployIdle/rebalance. FUNDING_SOURCE has
// ~5k wS / ~4.9 USSD — keep LEND_USSD small so seed + lend + user fit.
const SEED0 = ethers.parseEther("200"); // wS
const SEED1 = ethers.parseEther("1"); // USSD
const LEND_WS = ethers.parseEther("100");
const LEND_USSD = ethers.parseEther("1");

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

const fundFromExternal = (token: string, to: string, amount: bigint) =>
  fundFromSource(FUNDING_SOURCE, token, to, amount);

async function main() {
  const [deployer, lender] = await ethers.getSigners();
  console.log("deployer:", deployer.address);

  const factory = await (
    await ethers.getContractFactory("StratusDLMMVaultFactory", deployer)
  ).deploy(LB_FACTORY, METRO);
  await factory.waitForDeployment();
  console.log("factory:", await factory.getAddress());

  // --- seed + create vault (auto-resolves the hook from the pair) ---
  await fundFromExternal(wS, deployer.address, SEED0);
  await fundFromExternal(USSD, deployer.address, SEED1);
  await new ethers.Contract(wS, ERC20, deployer).approve(await factory.getAddress(), SEED0);
  await new ethers.Contract(USSD, ERC20, deployer).approve(await factory.getAddress(), SEED1);
  await (await factory.createVault(wS, USSD, BIN_STEP, 100, 10, SEED0, SEED1)).wait();

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
  await fundFromExternal(USSD, lender.address, LEND_USSD);
  await new ethers.Contract(USSD, ERC20, lender).transfer(lp.borrowable1, LEND_USSD);
  await (await (await ethers.getContractAt("Borrowable", lp.borrowable1, lender)).mint(lender.address)).wait();

  // --- fund the real user wallet with test tokens + gas ---
  await ethers.provider.send("hardhat_setBalance", [USER, "0x1b27a8b3fb5be0989f"]); // ~500 S (keeps real balance)
  await fundFromExternal(wS, USER, ethers.parseEther("20"));
  await fundFromExternal(USSD, USER, ethers.parseEther("1"));
  console.log("funded user:", USER);

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
