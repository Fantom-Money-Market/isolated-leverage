import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

// Deploys a fresh StratusThickVault (Equalizer Thick CL) + Tarot lending pool for the
// live wS/USDC.e ts=8 pool onto the already-running local fork, funds the user's wallet,
// and writes fork-ui/thick-config.json for the UI to read.
//   npx hardhat run scripts/fork-deploy-thick.ts --network localhost --config hardhat.config.fork-ui.ts

const CL_FACTORY = "0x7Ca1dCCFB4f49564b8f13E18a67747fd428F1C40";
const POOL = "0xb1BC4B830FCbA2184B92e15b9133c41160518038"; // wS/USDC.e ts=8
const wS = "0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38";
const USDCe = "0x29219dd400f2Bf60E5a23d13Be72B486D4038894";

const TICK_SPACING = 8;
const UPWARD_BIAS = 100;
const PROTOCOL_FEE = 5;
const SEED0 = ethers.parseEther("1");
const SEED1 = ethers.parseUnits("0.03", 6);

const USER = process.env.USER_ADDR || "0x0190933669d250406efcf18b351b954Ea88D5bfD";

const ERC20 = [
  "function approve(address,uint256) returns (bool)",
  "function transfer(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
];

async function fundFromPool(token: string, to: string, amount: bigint) {
  await ethers.provider.send("hardhat_impersonateAccount", [POOL]);
  await ethers.provider.send("hardhat_setBalance", [POOL, "0x21e19e0c9bab2400000"]);
  const s = await ethers.getSigner(POOL);
  await new ethers.Contract(token, ERC20, s).transfer(to, amount);
  await ethers.provider.send("hardhat_stopImpersonatingAccount", [POOL]);
}

async function main() {
  const [deployer, lender] = await ethers.getSigners();
  console.log("deployer:", deployer.address);

  const tm = await (await ethers.getContractFactory("TickMath", deployer)).deploy();
  await tm.waitForDeployment();
  const la = await (await ethers.getContractFactory("LiquidityAmounts", deployer)).deploy();
  await la.waitForDeployment();
  const ph = await (
    await ethers.getContractFactory("UniswapV3PriceHelper", {
      libraries: { TickMath: await tm.getAddress() },
      signer: deployer,
    })
  ).deploy();
  await ph.waitForDeployment();

  const F = await ethers.getContractFactory("StratusThickVaultFactory", {
    libraries: {
      TickMath: await tm.getAddress(),
      LiquidityAmounts: await la.getAddress(),
      UniswapV3PriceHelper: await ph.getAddress(),
    },
    signer: deployer,
  });
  const factory = await F.deploy(CL_FACTORY);
  await factory.waitForDeployment();
  console.log("factory:", await factory.getAddress());

  await fundFromPool(wS, deployer.address, SEED0);
  await fundFromPool(USDCe, deployer.address, SEED1);
  await new ethers.Contract(wS, ERC20, deployer).approve(await factory.getAddress(), SEED0);
  await new ethers.Contract(USDCe, ERC20, deployer).approve(await factory.getAddress(), SEED1);
  await (
    await factory.createVault(USDCe, wS, TICK_SPACING, UPWARD_BIAS, PROTOCOL_FEE, SEED0, SEED1)
  ).wait();

  const vaultAddr = await factory.vaultForPool(POOL);
  const vault = await ethers.getContractAt("StratusThickVault", vaultAddr);
  console.log("vault  :", vaultAddr);

  // Same rebalance gates as Shadow fork: 5% deviation cap, 0.1% surplus bounty, 2% reward
  // bounty (unused — no gauge), 60% min skew.
  await (await factory.setVaultRebalanceParams(vaultAddr, 500, 10, 200, 6000)).wait();
  console.log("rebalance params set (minSkew 60%, bountyBps 0.1%)");

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
  console.log("borrowable1:", lp.borrowable1, "(USDC.e)");

  await fundFromPool(wS, lender.address, ethers.parseEther("50"));
  await new ethers.Contract(wS, ERC20, lender).transfer(lp.borrowable0, ethers.parseEther("50"));
  await (await (await ethers.getContractAt("Borrowable", lp.borrowable0, lender)).mint(lender.address)).wait();
  await fundFromPool(USDCe, lender.address, ethers.parseUnits("5", 6));
  await new ethers.Contract(USDCe, ERC20, lender).transfer(lp.borrowable1, ethers.parseUnits("5", 6));
  await (await (await ethers.getContractAt("Borrowable", lp.borrowable1, lender)).mint(lender.address)).wait();

  await ethers.provider.send("hardhat_setBalance", [USER, "0x1b27a8b3fb5be0989f"]);
  await fundFromPool(wS, USER, ethers.parseEther("20"));
  await fundFromPool(USDCe, USER, ethers.parseUnits("2", 6));
  console.log("funded user:", USER);

  const mainCfgPath = path.join(__dirname, "..", "fork-ui", "config.json");
  const mainCfg = JSON.parse(fs.readFileSync(mainCfgPath, "utf8"));

  const thickConfig = {
    marketId: "ws-usdc-live-fork",
    kind: "thick",
    clFactory: CL_FACTORY,
    pool: POOL,
    tickSpacing: TICK_SPACING,
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
      USDCe: { address: USDCe, symbol: "USDC.e", decimals: 6 },
    },
  };

  const outDir = path.join(__dirname, "..", "fork-ui");
  fs.mkdirSync(outDir, { recursive: true });
  const configPath = path.join(outDir, "thick-config.json");
  fs.writeFileSync(configPath, JSON.stringify(thickConfig, null, 2));
  console.log("\nwrote fork-ui/thick-config.json");
  console.log(JSON.stringify(thickConfig, null, 2));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
