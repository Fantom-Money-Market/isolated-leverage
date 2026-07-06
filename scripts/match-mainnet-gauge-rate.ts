import { ethers } from "hardhat";

// Bring the fork gauge's SHADOW rewardRate up to the real mainnet weekly budget
// (8,596 SHADOW/week for USDC.e/wS). The gauge itself holds a large SHADOW balance
// on the fork (unclaimed past emissions), so fund the voter from it and notify the
// difference. Gauge rate = totalNotifiedThisPeriod / WEEK, so we notify the delta.
const GAUGE = "0xe879d0E44e6873cf4ab71686055a4f6817685f02";
const SHADOW = "0x3333b97138D4b086720b5aE8A7844b1345a33333";
const VOTER = "0x9F59398D0a397b2EEB8a6123a6c7295cB0b0062D";
const WEEK = 604800n;
// mainnet rewardRate read live: 0.014212598724562858 SHADOW/s * WEEK = 8595.78/wk
const TARGET_WEEKLY = ethers.parseEther("8596");

const ERC20 = [
  "function approve(address,uint256) returns (bool)",
  "function transfer(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
];
const GAUGE_ABI = [
  "function notifyRewardAmount(address token, uint256 amount)",
  "function rewardRate(address) view returns (uint256)",
  "function left(address) view returns (uint256)",
];

async function main() {
  const gauge = new ethers.Contract(GAUGE, GAUGE_ABI, ethers.provider);
  const rateBefore: bigint = await gauge.rewardRate(SHADOW);
  const notifiedSoFar = rateBefore * WEEK;
  console.log("rate before:", ethers.formatEther(rateBefore), "SHADOW/s");
  console.log("already notified this period:", ethers.formatEther(notifiedSoFar));

  if (notifiedSoFar >= TARGET_WEEKLY) {
    console.log("already at/above mainnet weekly budget, nothing to do");
    return;
  }
  const delta = TARGET_WEEKLY - notifiedSoFar;
  console.log("notifying delta:", ethers.formatEther(delta));

  // fund voter from the gauge's own SHADOW balance
  await ethers.provider.send("hardhat_impersonateAccount", [GAUGE]);
  await ethers.provider.send("hardhat_setBalance", [GAUGE, "0x21e19e0c9bab2400000"]);
  const gaugeSigner = await ethers.getSigner(GAUGE);
  const gaugeBal: bigint = await new ethers.Contract(SHADOW, ERC20, ethers.provider).balanceOf(GAUGE);
  console.log("gauge SHADOW balance:", ethers.formatEther(gaugeBal));
  if (gaugeBal < delta) throw new Error("gauge does not hold enough SHADOW to fund the top-up");
  await (await new ethers.Contract(SHADOW, ERC20, gaugeSigner).transfer(VOTER, delta)).wait();
  await ethers.provider.send("hardhat_stopImpersonatingAccount", [GAUGE]);

  // notify from the voter
  await ethers.provider.send("hardhat_impersonateAccount", [VOTER]);
  await ethers.provider.send("hardhat_setBalance", [VOTER, "0x21e19e0c9bab2400000"]);
  const voter = await ethers.getSigner(VOTER);
  await (await new ethers.Contract(SHADOW, ERC20, voter).approve(GAUGE, delta)).wait();
  await (await gauge.connect(voter).notifyRewardAmount(SHADOW, delta)).wait();
  await ethers.provider.send("hardhat_stopImpersonatingAccount", [VOTER]);

  const rateAfter: bigint = await gauge.rewardRate(SHADOW);
  const left: bigint = await gauge.left(SHADOW);
  console.log("rate after:", ethers.formatEther(rateAfter), "SHADOW/s (mainnet: 0.014212598724562858)");
  console.log("left:", ethers.formatEther(left));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
