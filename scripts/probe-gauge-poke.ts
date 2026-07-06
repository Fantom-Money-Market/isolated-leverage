import { ethers } from "hardhat";

const POOL = "0x324963c267C354c7660Ce8CA3F5f167E05649970";
const SHADOW = "0x3333b97138D4b086720b5aE8A7844b1345a33333";
const GAUGE = "0xe879d0E44e6873cf4ab71686055a4f6817685f02";
const VAULT = "0xd559FEFB23283AFED6e1B720369DD55e7C80fFf9";
const HELPER = process.env.HELPER || "0xF8e31cb472bc70500f08Cd84917E5A1912Ec8397";
const MAX_SQRT = 1461446703485210103287273052203988822378723970342n;
const WEEK = 604800n;

const GAUGE_ABI = [
  "function rewardRate(address) view returns (uint256)",
  "function left(address) view returns (uint256)",
  "function periodEarned(uint256,address,address,uint256,int24,int24) view returns (uint256)",
  "function cachePeriodEarned(uint256 period, address token, address owner, uint256 index, int24 tickLower, int24 tickUpper, bool caching) returns (uint256)",
  "function tokenTotalSupplyByPeriod(uint256 period, address token) view returns (uint256)",
];

async function dump(label: string, gauge: ethers.Contract, vault: ethers.Contract) {
  const block = await ethers.provider.getBlock("latest");
  const period = BigInt(block!.timestamp) / WEEK;
  console.log(`\n=== ${label} (period ${period}) ===`);
  console.log("rewardRate", (await gauge.rewardRate(SHADOW)).toString());
  console.log("left", (await gauge.left(SHADOW)).toString());
  let curSum = 0n;
  let prevSum = 0n;
  for (let i = 0; i < 3; i++) {
    const l = await vault.rangeLower(i);
    const u = await vault.rangeUpper(i);
    const cur = await gauge.periodEarned(period, SHADOW, VAULT, 0, l, u);
    const prev = await gauge.periodEarned(period - 1n, SHADOW, VAULT, 0, l, u);
    curSum += cur;
    prevSum += prev;
    let cached = 0n;
    try {
      cached = await gauge.cachePeriodEarned.staticCall(period, SHADOW, VAULT, 0, l, u, true);
    } catch {}
    console.log(`range[${i}] [${l},${u}] cur=${cur} prev=${prev} cacheCall=${cached}`);
  }
  console.log("TOTAL cur", curSum.toString(), "prev", prevSum.toString());
  const totals = await vault.getTotalAmounts();
  console.log("vault TVL raw", totals[0].toString(), totals[1].toString());
}

async function main() {
  const gauge = new ethers.Contract(GAUGE, GAUGE_ABI, ethers.provider);
  const vault = await ethers.getContractAt("StratusShadowVault", VAULT);
  const helper = await ethers.getContractAt("PoolSwapHelper", HELPER);

  await dump("start", gauge, vault);

  await (await helper.doSwap(POOL, false, -1_000_000_000_000_000n, MAX_SQRT - 1n)).wait();
  await dump("after poke", gauge, vault);

  await ethers.provider.send("evm_increaseTime", [Number(WEEK)]);
  await ethers.provider.send("evm_mine", []);
  await dump("after +1 week", gauge, vault);

  await (await helper.doSwap(POOL, false, -1_000_000_000n, MAX_SQRT - 1n)).wait();
  await dump("after week+poke", gauge, vault);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
