import { ethers } from "hardhat";

const GAUGE = "0xe879d0E44e6873cf4ab71686055a4f6817685f02";
const SHADOW = "0x3333b97138D4b086720b5aE8A7844b1345a33333";
const VOTER = "0x9F59398D0a397b2EEB8a6123a6c7295cB0b0062D";
const AMOUNT = ethers.parseEther(process.env.SHADOW_AMOUNT || "100");

const ERC20 = [
  "function approve(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
];
const GAUGE_ABI = [
  "function notifyRewardAmount(address token, uint256 amount)",
  "function notifyRewardAmountNextPeriod(address token, uint256 amount)",
  "function rewardRate(address) view returns (uint256)",
  "function left(address) view returns (uint256)",
];

async function read(label: string, gauge: ethers.Contract) {
  const rr = await gauge.rewardRate(SHADOW);
  const left = await gauge.left(SHADOW);
  console.log(`${label}: rewardRate=${ethers.formatEther(rr)} left=${ethers.formatEther(left)}`);
}

async function main() {
  const gauge = new ethers.Contract(GAUGE, GAUGE_ABI, ethers.provider);
  await read("before", gauge);

  await ethers.provider.send("hardhat_impersonateAccount", [VOTER]);
  await ethers.provider.send("hardhat_setBalance", [VOTER, "0x21e19e0c9bab2400000"]);
  const voter = await ethers.getSigner(VOTER);

  const shadow = new ethers.Contract(SHADOW, ERC20, voter);
  console.log("voter SHADOW", ethers.formatEther(await shadow.balanceOf(VOTER)));

  await (await shadow.approve(GAUGE, AMOUNT)).wait();

  for (const fn of ["notifyRewardAmount", "notifyRewardAmountNextPeriod"] as const) {
    try {
      await (await gauge.connect(voter)[fn](SHADOW, AMOUNT)).wait();
      console.log(`ok: ${fn}`);
      await read(`after ${fn}`, gauge);
      break;
    } catch (e: any) {
      console.log(`fail ${fn}:`, e.shortMessage || e.message);
    }
  }

  await ethers.provider.send("hardhat_stopImpersonatingAccount", [VOTER]);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
