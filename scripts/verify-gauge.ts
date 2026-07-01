import { ethers } from "hardhat";

const VAULT = process.env.VAULT || "0x096245c02268dceC8Ae96331EEc43eAF6cD1e8EA";
const GAUGE = "0xe879d0E44e6873cf4ab71686055a4f6817685f02";
const SHADOW = "0x3333b97138D4b086720b5aE8A7844b1345a33333";
const WEEK = 604800n;

const GAUGE_ABI = [
  "function periodEarned(uint256 period, address token, address owner, uint256 index, int24 tickLower, int24 tickUpper) view returns (uint256)",
  "function left(address token) view returns (uint256)",
  "function rewardRate(address token) view returns (uint256)",
];

async function main() {
  const v = await ethers.getContractAt("StratusShadowVault", VAULT);
  const pool = await ethers.getContractAt("IShadowV3Pool", await v.pool());
  const slot0 = await pool.slot0();
  const currentTick = Number(slot0[1]);

  const block = await ethers.provider.getBlock("latest");
  const period = BigInt(block!.timestamp) / WEEK;
  console.log("currentTick      :", currentTick);
  console.log("period           :", period.toString());

  const gauge = new ethers.Contract(GAUGE, GAUGE_ABI, ethers.provider);
  console.log("SHADOW left      :", (await gauge.left(SHADOW)).toString());
  console.log("SHADOW rewardRate:", (await gauge.rewardRate(SHADOW)).toString());

  let total = 0n;
  for (let i = 0; i < 3; i++) {
    const lower = Number(await v.rangeLower(i));
    const upper = Number(await v.rangeUpper(i));
    const inRange = currentTick >= lower && currentTick <= upper;
    try {
      const cur = await gauge.periodEarned(period, SHADOW, VAULT, 0, lower, upper);
      const prev = await gauge.periodEarned(period - 1n, SHADOW, VAULT, 0, lower, upper);
      total += cur;
      console.log(`range[${i}] [${lower},${upper}] inRange=${inRange}  earned(this)=${cur} earned(prev)=${prev}`);
    } catch (e: any) {
      console.log(`range[${i}] [${lower},${upper}] inRange=${inRange}  periodEarned REVERT: ${e.shortMessage || e.message}`);
    }
  }
  console.log("TOTAL SHADOW accrued to the direct position this period:", total.toString());
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
