import { ethers } from "hardhat";

const GAUGE = "0xaE647ea922D392cC825c51967382940A30893f6D";
const BPT = "0x75b000584a7d86fb3ef5e15ba26f4c52b41be0e9";

const GAUGE_ABI = [
  "function lp_token() view returns (address)",
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function totalSupply() view returns (uint256)",
  "function reward_count() view returns (uint256)",
  "function reward_tokens(uint256) view returns (address)",
  "function claimable_reward(address user, address reward) view returns (uint256)",
];

async function main() {
  const g = await ethers.getContractAt(GAUGE_ABI, GAUGE);
  const bpt = await ethers.getContractAt("IERC20", BPT);

  const lp = await g.lp_token();
  console.log("lp_token     :", lp);
  console.log("matches BPT  :", lp.toLowerCase() === BPT.toLowerCase());
  console.log("name         :", await g.name());
  console.log("symbol       :", await g.symbol());
  console.log("gauge supply :", ethers.formatEther(await g.totalSupply()), "gauge tokens");
  console.log("BPT in gauge :", ethers.formatEther(await bpt.balanceOf(GAUGE)), "BPT");

  const rc = Number(await g.reward_count());
  console.log("reward_count :", rc);
  for (let i = 0; i < rc; i++) {
    const token = await g.reward_tokens(i);
    console.log(` reward[${i}]   :`, token);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
