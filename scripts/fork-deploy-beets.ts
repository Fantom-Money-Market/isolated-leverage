import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * Deploy StratusBeetsV3Adapter + Tarot lending pool for the live stS-wS Balancer/Beets BPT
 * on the already-running local fork (chainId 31337).
 *
 *   npx hardhat run scripts/fork-deploy-beets.ts --network localhost --config hardhat.config.integration.ts
 */
const BEETS_VAULT = "0xbA1333333333a1BA1108E8412f11850A5C319bA9";
const BPT = "0x75b000584a7d86fb3ef5e15ba26f4c52b41be0e9";
const GAUGE = "0xaE647ea922D392cC825c51967382940A30893f6D";
const BEETS = "0x2D0E0814E62D80056181F5cd932274405966e4f0";
const stS = "0xE5DA20F15420aD15DE0fa650600aFc998bbE3955";
const wS = "0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38";
const BPT_SOURCE = GAUGE;
const WS_POOL = "0x324963c267C354c7660Ce8CA3F5f167E05649970"; // USDC.e/wS Shadow pool
// NOTE: never fund stS by impersonating BEETS_VAULT — pulling tokens out of the v3
// singleton desyncs its internal reserve accounting, and the adapter's deposit() path
// settles against those reserves (every later deposit would revert BalanceNotSettled).
// stS is sourced cleanly below by round-tripping wS through the adapter itself.

const USER = process.env.USER_ADDR || "0x0190933669d250406efcf18b351b954Ea88D5bfD";
const SEED_BPT = ethers.parseEther("50");
const LEND_WS = ethers.parseEther("100");
const LEND_STS = ethers.parseEther("100");

const ERC20 = [
  "function approve(address,uint256) returns (bool)",
  "function transfer(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
  "function symbol() view returns (string)",
];

async function fundBpt(to: string, amount: bigint) {
  await ethers.provider.send("hardhat_impersonateAccount", [BPT_SOURCE]);
  await ethers.provider.send("hardhat_setBalance", [BPT_SOURCE, "0x21e19e0c9bab2400000"]);
  const holder = await ethers.getSigner(BPT_SOURCE);
  await new ethers.Contract(BPT, ERC20, holder).transfer(to, amount);
  await ethers.provider.send("hardhat_stopImpersonatingAccount", [BPT_SOURCE]);
}

async function fundFromAccount(holder: string, token: string, to: string, amount: bigint) {
  await ethers.provider.send("hardhat_impersonateAccount", [holder]);
  await ethers.provider.send("hardhat_setBalance", [holder, "0x21e19e0c9bab2400000"]);
  const signer = await ethers.getSigner(holder);
  await new ethers.Contract(token, ERC20, signer).transfer(to, amount);
  await ethers.provider.send("hardhat_stopImpersonatingAccount", [holder]);
}

async function main() {
  const [deployer, lender] = await ethers.getSigners();
  console.log("deployer:", deployer.address);

  const sym = await new ethers.Contract(BPT, ERC20, deployer).symbol();
  const adapter = await (
    await ethers.getContractFactory("StratusBeetsV3Adapter", deployer)
  ).deploy(BEETS_VAULT, BPT, GAUGE, `Stratus Beets ${sym}`, `s-${sym}`);
  await adapter.waitForDeployment();
  const adapterAddr = await adapter.getAddress();
  console.log("adapter   :", adapterAddr);

  await (await adapter.setRewardTokens([BEETS, stS])).wait();
  console.log("rewards   : BEETS + stS");

  const BD = await (await ethers.getContractFactory("BDeployer", deployer)).deploy();
  await BD.waitForDeployment();
  const CD = await (await ethers.getContractFactory("CDeployer", deployer)).deploy();
  await CD.waitForDeployment();
  const tarot = await (
    await ethers.getContractFactory("TarotFactory", deployer)
  ).deploy(deployer.address, deployer.address, await BD.getAddress(), await CD.getAddress());
  await tarot.waitForDeployment();

  await (await tarot.createCollateral(adapterAddr)).wait();
  await (await tarot.createBorrowable0(adapterAddr)).wait();
  await (await tarot.createBorrowable1(adapterAddr)).wait();
  await (await tarot.initializeLendingPool(adapterAddr)).wait();
  const lp = await tarot.getLendingPool(adapterAddr);
  console.log("collateral:", lp.collateral);
  console.log("borrowable0:", lp.borrowable0, "(wS)");
  console.log("borrowable1:", lp.borrowable1, "(stS)");

  await fundFromAccount(WS_POOL, wS, lender.address, LEND_WS);
  await new ethers.Contract(wS, ERC20, lender).transfer(lp.borrowable0, LEND_WS);
  await (await ethers.getContractAt("Borrowable", lp.borrowable0, lender)).mint(lender.address);

  // Source stS WITHOUT touching the v3 vault's reserves: deposit wS one-sided through the
  // adapter, then withdraw proportionally — the exit pays out in the pool's mix, all
  // through legitimate vault accounting. How much stS a given wS input yields tracks the
  // pool's LIVE composition, so a hardcoded input silently goes short whenever the pool
  // drifts (it did). Measure the observed yield and top up from it instead.
  const adapterAsLender = adapter.connect(lender) as typeof adapter;
  const stSToken = new ethers.Contract(stS, ERC20, lender);

  async function roundTripWsForSts(wsAmount: bigint) {
    await fundFromAccount(WS_POOL, wS, lender.address, wsAmount);
    await (await new ethers.Contract(wS, ERC20, lender).approve(adapterAddr, wsAmount)).wait();
    await (await adapterAsLender.deposit(wsAmount, 0, lender.address, 0)).wait();
    const shares = await adapter.balanceOf(lender.address);
    await (await adapterAsLender.withdraw(shares, lender.address, 0, 0)).wait();
  }

  let stSGot: bigint = await stSToken.balanceOf(lender.address);
  let nextWs = ethers.parseEther("160");
  for (let attempt = 0; stSGot < LEND_STS && attempt < 5; attempt++) {
    const before = stSGot;
    await roundTripWsForSts(nextWs);
    stSGot = await stSToken.balanceOf(lender.address);
    const gained = stSGot - before;
    if (stSGot >= LEND_STS) break;
    const shortfall = LEND_STS - stSGot;
    // Size the next pass off the rate we just measured, +25% margin. If a pass somehow
    // yielded nothing, fall back to doubling rather than dividing by zero.
    nextWs = gained > 0n ? ((nextWs * shortfall) / gained) * 5n / 4n : nextWs * 2n;
  }
  console.log("stS sourced via adapter round-trip:", ethers.formatEther(stSGot));
  if (stSGot < LEND_STS) throw new Error(`stS conversion came up short: ${ethers.formatEther(stSGot)} < ${ethers.formatEther(LEND_STS)}`);

  await new ethers.Contract(stS, ERC20, lender).transfer(lp.borrowable1, LEND_STS);
  await (await ethers.getContractAt("Borrowable", lp.borrowable1, lender)).mint(lender.address);

  await ethers.provider.send("hardhat_setBalance", [USER, "0x1b27a8b3fb5be0989f"]);
  await fundBpt(USER, SEED_BPT);
  console.log("funded user BPT:", ethers.formatEther(SEED_BPT));

  // give the user raw stS too (same adapter round-trip) so the supply modal's two-token
  // deposit is testable, not just wS-one-sided
  const USER_STS_WS = ethers.parseEther("120");
  await fundFromAccount(WS_POOL, wS, lender.address, USER_STS_WS);
  await (await new ethers.Contract(wS, ERC20, lender).approve(adapterAddr, USER_STS_WS)).wait();
  await (await adapterAsLender.deposit(USER_STS_WS, 0, lender.address, 0)).wait();
  const userConvShares = await adapter.balanceOf(lender.address);
  await (await adapterAsLender.withdraw(userConvShares, USER, 0, 0)).wait();
  await fundFromAccount(WS_POOL, wS, USER, ethers.parseEther("500"));
  console.log("funded user: 500 wS + adapter-sourced stS mix");

  // Reuse the existing stateless routers (they resolve everything via collateral.underlying()).
  const mainCfgPath = path.join(__dirname, "..", "fork-ui", "config.json");
  const mainCfg = JSON.parse(fs.readFileSync(mainCfgPath, "utf8"));

  const beetsConfig = {
    marketId: "sts-ws-live-fork", // must match BEETS_MARKET_ID in the frontend's config/contracts.ts
    kind: "beets-adapter",
    beetsVault: BEETS_VAULT,
    bpt: BPT,
    gauge: GAUGE,
    adapter: adapterAddr,
    tarotFactory: await tarot.getAddress(),
    collateral: lp.collateral,
    borrowable0: lp.borrowable0,
    borrowable1: lp.borrowable1,
    leverageRouter: mainCfg.leverageRouter,
    unwindRouter: mainCfg.unwindRouter,
    tokens: {
      wS: { address: wS, symbol: "wS", decimals: 18 },
      stS: { address: stS, symbol: "stS", decimals: 18 },
      BEETS: { address: BEETS, symbol: "BEETS", decimals: 18 },
      BPT: { address: BPT, symbol: sym, decimals: 18 },
    },
  };

  const outDir = path.join(__dirname, "..", "fork-ui");
  fs.mkdirSync(outDir, { recursive: true });
  const configPath = path.join(outDir, "beets-config.json");
  fs.writeFileSync(configPath, JSON.stringify(beetsConfig, null, 2));
  console.log("\nwrote fork-ui/beets-config.json");
  console.log(JSON.stringify(beetsConfig, null, 2));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
