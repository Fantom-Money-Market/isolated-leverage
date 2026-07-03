import { ethers } from "hardhat";

const ADDR = process.env.ADDR || "0x096245c02268dceC8Ae96331EEc43eAF6cD1e8EA";

async function main() {
  const signer = ethers.Wallet.createRandom().connect(ethers.provider);
  const iface = new ethers.Interface(["function rebalance()"]);
  const data = iface.encodeFunctionData("rebalance");

  try {
    const result = await ethers.provider.call({ to: ADDR, from: signer.address, data });
    console.log("rebalance() eth_call OK, returned:", result);
  } catch (e: any) {
    console.log("rebalance() eth_call REVERTED:", e.shortMessage || e.message);
    console.log("raw error:", JSON.stringify(e.info?.error || e.error || {}, null, 2).slice(0, 800));
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
