import { ethers } from "hardhat";

const POOL = "0x324963c267C354c7660Ce8CA3F5f167E05649970";
const SHADOW = "0x3333b97138D4b086720b5aE8A7844b1345a33333";
const GAUGE = "0xe879d0E44e6873cf4ab71686055a4f6817685f02";
const HELPER = process.env.HELPER || "0xF8e31cb472bc70500f08Cd84917E5A1912Ec8397";
const MAX_SQRT = 1461446703485210103287273052203988822378723970342n;
const MIN_SQRT = 4295128739n;

const GAUGE_ABI = ["function rewardRate(address) view returns (uint256)", "function left(address) view returns (uint256)"];

async function rate(label: string, gauge: ethers.Contract) {
  const rr = await gauge.rewardRate(SHADOW);
  const left = await gauge.left(SHADOW);
  console.log(label, "rewardRate", ethers.formatEther(rr), "left", ethers.formatEther(left));
}

async function main() {
  const gauge = new ethers.Contract(GAUGE, GAUGE_ABI, ethers.provider);
  const helper = await ethers.getContractAt("PoolSwapHelper", HELPER);
  await rate("before", gauge);

  const tries = [
    { z: false, amt: -1_000_000_000_000_000n, lim: MAX_SQRT - 1n },
    { z: false, amt: -1_000_000_000_000_000_000n, lim: MAX_SQRT - 1n },
    { z: false, amt: -100_000_000_000_000_000_000n, lim: MAX_SQRT - 1n },
    { z: true, amt: -1_000_000_000_000_000n, lim: MIN_SQRT + 1n },
    { z: true, amt: 1_000_000_000_000_000n, lim: MIN_SQRT + 1n },
  ];

  for (const t of tries) {
    try {
      await (await helper.doSwap(POOL, t.z, t.amt, t.lim)).wait();
      await rate(`ok z=${t.z} amt=${t.amt}`, gauge);
    } catch (e: any) {
      console.log(`fail z=${t.z} amt=${t.amt}`, e.shortMessage || e.message);
    }
  }
}

main().catch(console.error);
