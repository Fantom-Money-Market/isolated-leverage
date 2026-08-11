import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

const POOL = "0x324963c267C354c7660Ce8CA3F5f167E05649970";
const wS = "0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38";
const USDCe = "0x29219dd400f2Bf60E5a23d13Be72B486D4038894";
const SHADOW = "0x3333b97138D4b086720b5aE8A7844b1345a33333";
const GAUGE = "0xe879d0E44e6873cf4ab71686055a4f6817685f02";
// Read the LIVE Shadow vault out of the config this script also writes to, rather than
// pinning an address. A hardcoded default silently survives a fork reset and then fails
// deep inside the poke with an undecodable `rangeLower` result, which reads like a contract
// bug rather than a stale constant.
const VAULT =
  process.env.VAULT ||
  JSON.parse(fs.readFileSync(path.join(__dirname, "..", "fork-ui", "config.json"), "utf8")).vault;
const MAX_SQRT = 1461446703485210103287273052203988822378723970342n;
const WEEK = 604800n;

const ERC20 = [
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

async function readGauge(label: string, gauge: ethers.Contract, vault: ethers.Contract) {
  const block = await ethers.provider.getBlock("latest");
  const period = BigInt(block!.timestamp) / WEEK;
  const rr = await gauge.rewardRate(SHADOW);
  const left = await gauge.left(SHADOW);
  console.log(`\n[${label}] rewardRate=${rr} left=${left} period=${period}`);
  for (let i = 0; i < 3; i++) {
    const lower = await vault.rangeLower(i);
    const upper = await vault.rangeUpper(i);
    const cur = await gauge.periodEarned(period, SHADOW, VAULT, 0, lower, upper);
    const prev = await gauge.periodEarned(period - 1n, SHADOW, VAULT, 0, lower, upper);
    console.log(`  range[${i}] cur=${cur} prev=${prev}`);
  }
}

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("deployer:", deployer.address);

  const Helper = await ethers.getContractFactory("PoolSwapHelper");
  const helper = await Helper.deploy();
  await helper.waitForDeployment();
  const helperAddr = await helper.getAddress();
  console.log("PoolSwapHelper:", helperAddr);

  await (await helper.setTokens(wS, USDCe)).wait();

  // Fund native S for gas if anything routes through the helper itself
  await ethers.provider.send("hardhat_setBalance", [helperAddr, ethers.toBeHex(ethers.parseEther("10"))]);

  // Fund swap callback tokens
  await fundFromPool(wS, helperAddr, ethers.parseEther("50"));
  await fundFromPool(USDCe, helperAddr, ethers.parseUnits("5", 6));

  const sBal = await ethers.provider.getBalance(helperAddr);
  const wBal = await new ethers.Contract(wS, ERC20, deployer).balanceOf(helperAddr);
  const uBal = await new ethers.Contract(USDCe, ERC20, deployer).balanceOf(helperAddr);
  console.log("balances — S:", ethers.formatEther(sBal), "wS:", ethers.formatEther(wBal), "USDC.e:", ethers.formatUnits(uBal, 6));

  const gaugeAbi = [
    "function rewardRate(address) view returns (uint256)",
    "function left(address) view returns (uint256)",
    "function periodEarned(uint256,address,address,uint256,int24,int24) view returns (uint256)",
  ];
  const gauge = new ethers.Contract(GAUGE, gaugeAbi, ethers.provider);
  const vault = await ethers.getContractAt("StratusShadowVault", VAULT);

  await readGauge("before poke", gauge, vault);

  const attempts: { label: string; zeroForOne: boolean; amount: bigint }[] = [
    { label: "false -1e15", zeroForOne: false, amount: -1_000_000_000_000_000n },
    { label: "true -1e15", zeroForOne: true, amount: -1_000_000_000_000_000n },
    { label: "false -1e12", zeroForOne: false, amount: -1_000_000_000n },
    { label: "true +1e12", zeroForOne: true, amount: 1_000_000_000n },
  ];

  for (const a of attempts) {
    try {
      const tx = await helper.doSwap(POOL, a.zeroForOne, a.amount, MAX_SQRT - 1n);
      await tx.wait();
      console.log(`poke ok: ${a.label}`);
      await readGauge(`after ${a.label}`, gauge, vault);
    } catch (e: any) {
      console.log(`poke FAIL ${a.label}:`, e.shortMessage || e.message);
    }
  }

  const configPath = path.join(__dirname, "..", "fork-ui", "config.json");
  let config: Record<string, unknown> = {};
  if (fs.existsSync(configPath)) {
    config = JSON.parse(fs.readFileSync(configPath, "utf8"));
  }
  config.poolSwapHelper = helperAddr;
  fs.mkdirSync(path.dirname(configPath), { recursive: true });
  fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
  console.log("\nwrote poolSwapHelper to fork-ui/config.json");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
