import { ethers } from "hardhat";

// Deploy a StratusBeetsV3Adapter for a Beets/Balancer-v3 BPT, making it Tarot-priceable.
// Deploy-only (no funds moved); holders wrap their own BPT afterwards.
//   BPT=0x.. PRIVATE_KEY=0x.. npx hardhat run scripts/deploy-beets-adapter.ts --network sonic --config hardhat.config.stratus.ts
const VAULT = "0xbA1333333333a1BA1108E8412f11850A5C319bA9"; // Beets v3 Vault (Sonic)
const BPT = process.env.BPT || "0x75b000584a7d86fb3ef5e15ba26f4c52b41be0e9"; // stS-wS

async function main() {
  const pk = process.env.PRIVATE_KEY;
  if (!pk) throw new Error("Set PRIVATE_KEY");
  const signer = new ethers.Wallet(pk, ethers.provider);

  const sym = await new ethers.Contract(BPT, ["function symbol() view returns (string)"], signer).symbol();
  const name = "Stratus Beets " + sym;
  const symbol = "s-" + sym;

  const A = await ethers.getContractFactory("StratusBeetsV3Adapter", signer);
  const a = await A.deploy(VAULT, BPT, name, symbol);
  await a.waitForDeployment();
  const addr = await a.getAddress();

  console.log("adapter      :", addr);
  console.log("name/symbol  :", name, "/", symbol);
  console.log("bpt          :", await a.bpt());
  console.log("token0       :", await a.token0());
  console.log("token1       :", await a.token1());
  console.log("twapPrice    :", (await a.twapPrice()).toString());
  console.log("\nUse", addr, "as the `underlying` when creating the Tarot lending market.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
