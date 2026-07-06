import { ethers } from "hardhat";

const VAULT = "0xd559FEFB23283AFED6e1B720369DD55e7C80fFf9";
const HELPER = "0xF8e31cb472bc70500f08Cd84917E5A1912Ec8397";
const POOL = "0x324963c267C354c7660Ce8CA3F5f167E05649970";
const SHADOW = "0x3333b97138D4b086720b5aE8A7844b1345a33333";
const MAX = 1461446703485210103287273052203988822378723970342n;

async function main() {
  const vault = await ethers.getContractAt("StratusShadowVault", VAULT);
  const helper = await ethers.getContractAt("PoolSwapHelper", HELPER);
  const shadow = await ethers.getContractAt(["function balanceOf(address) view returns (uint256)"], SHADOW);

  const before = await shadow.balanceOf(VAULT);
  await (await helper.doSwap(POOL, false, -1_000_000_000_000_000n, MAX - 1n)).wait();
  const mid = await shadow.balanceOf(VAULT);
  await (await vault.collectGaugeRewards()).wait();
  const after = await shadow.balanceOf(VAULT);
  console.log({ before: before.toString(), mid: mid.toString(), after: after.toString() });
}

main().catch(console.error);
