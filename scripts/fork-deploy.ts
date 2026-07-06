import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

// Deploys a fresh, disposable Shadow ALPT vault + full Tarot lending pool onto the
// already-running local fork (npx hardhat node --fork ... on 127.0.0.1:8545), funds the
// user's real wallet with test tokens, and writes fork-ui/config.json for the UI to read.
//   npx hardhat run scripts/fork-deploy.ts --network localhost --config hardhat.config.integration.ts

const VOTER = "0x9F59398D0a397b2EEB8a6123a6c7295cB0b0062D";
const SHADOW = "0x3333b97138D4b086720b5aE8A7844b1345a33333";
const POOL = "0x324963c267C354c7660Ce8CA3F5f167E05649970"; // USDC.e/wS, ts=50
const USDCe = "0x29219dd400f2Bf60E5a23d13Be72B486D4038894"; // token1 (6d)
const wS = "0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38";    // token0 (18d)

const TICK_SPACING = 50;
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
  await ethers.provider.send("hardhat_setBalance", [POOL, "0x21e19e0c9bab2400000"]); // 10000 S
  const s = await ethers.getSigner(POOL);
  await new ethers.Contract(token, ERC20, s).transfer(to, amount);
  await ethers.provider.send("hardhat_stopImpersonatingAccount", [POOL]);
}

async function main() {
  const [deployer, lender] = await ethers.getSigners();
  console.log("deployer:", deployer.address);

  // --- libraries + factory ---
  const tm = await (await ethers.getContractFactory("TickMath", deployer)).deploy();
  await tm.waitForDeployment();
  const la = await (await ethers.getContractFactory("LiquidityAmounts", deployer)).deploy();
  await la.waitForDeployment();
  const ph = await (
    await ethers.getContractFactory("UniswapV3PriceHelper", { libraries: { TickMath: await tm.getAddress() }, signer: deployer })
  ).deploy();
  await ph.waitForDeployment();

  const F = await ethers.getContractFactory("StratusShadowVaultFactory", {
    libraries: { TickMath: await tm.getAddress(), LiquidityAmounts: await la.getAddress(), UniswapV3PriceHelper: await ph.getAddress() },
    signer: deployer,
  });
  const factory = await F.deploy(VOTER, SHADOW);
  await factory.waitForDeployment();
  console.log("factory:", await factory.getAddress());

  // --- seed + create vault (auto-wires gauge, reward tokens, deploys idle) ---
  await fundFromPool(wS, deployer.address, SEED0);
  await fundFromPool(USDCe, deployer.address, SEED1);
  await new ethers.Contract(wS, ERC20, deployer).approve(await factory.getAddress(), SEED0);
  await new ethers.Contract(USDCe, ERC20, deployer).approve(await factory.getAddress(), SEED1);
  await (await factory.createVault(USDCe, wS, TICK_SPACING, UPWARD_BIAS, PROTOCOL_FEE, SEED0, SEED1)).wait();

  const vaultAddr = await factory.vaultForPool(POOL);
  const vault = await ethers.getContractAt("StratusShadowVault", vaultAddr);
  console.log("vault  :", vaultAddr);

  // 5% spot/TWAP cap, 0.1% surplus fallback bounty, 2% gauge bounty, 60% min skew.
  await (await factory.setVaultRebalanceParams(vaultAddr, 500, 10, 200, 6000)).wait();
  console.log("rebalance params set (minSkew 60%)");

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
  console.log("borrowable1:", lp.borrowable1, "(USDC.e)");

  // --- seed lender liquidity so borrows are actually possible ---
  await fundFromPool(wS, lender.address, ethers.parseEther("50"));
  await new ethers.Contract(wS, ERC20, lender).transfer(lp.borrowable0, ethers.parseEther("50"));
  await (await (await ethers.getContractAt("Borrowable", lp.borrowable0, lender)).mint(lender.address)).wait();
  await fundFromPool(USDCe, lender.address, ethers.parseUnits("5", 6));
  await new ethers.Contract(USDCe, ERC20, lender).transfer(lp.borrowable1, ethers.parseUnits("5", 6));
  await (await (await ethers.getContractAt("Borrowable", lp.borrowable1, lender)).mint(lender.address)).wait();

  // --- fund the real user wallet with test tokens + gas ---
  await ethers.provider.send("hardhat_setBalance", [USER, "0x1b27a8b3fb5be0989f"]); // ~500 S (keeps real balance)
  await fundFromPool(wS, USER, ethers.parseEther("20"));
  await fundFromPool(USDCe, USER, ethers.parseUnits("2", 6));
  console.log("funded user:", USER);

  // --- write config for the UI ---
  const config = {
    rpcUrl: "http://127.0.0.1:8545",
    chainId: Number((await ethers.provider.getNetwork()).chainId),
    user: USER,
    tokens: {
      wS: { address: wS, symbol: "wS", decimals: 18 },
      USDCe: { address: USDCe, symbol: "USDC.e", decimals: 6 },
      SHADOW: { address: SHADOW, symbol: "SHADOW", decimals: 18 },
    },
    pool: POOL,
    factory: await factory.getAddress(),
    vault: vaultAddr,
    tarotFactory: await tarot.getAddress(),
    collateral: lp.collateral,
    borrowable0: lp.borrowable0,
    borrowable1: lp.borrowable1,
  };
  const outDir = path.join(__dirname, "..", "fork-ui");
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, "config.json"), JSON.stringify(config, null, 2));
  console.log("\nwrote fork-ui/config.json");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
