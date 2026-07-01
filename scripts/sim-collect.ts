import { ethers } from "hardhat";

const VAULT = process.env.VAULT || "0x096245c02268dceC8Ae96331EEc43eAF6cD1e8EA";
const PROTOCOL_FEE = 5n; // % (as deployed)

async function main() {
  const v = await ethers.getContractAt("StratusShadowVault", VAULT);
  console.log("Simulating collectGaugeRewards() on", VAULT);

  try {
    const res = await v.collectGaugeRewards.staticCall();
    const tokens: string[] = res[0];
    const net: bigint[] = res[1];
    console.log("SUCCESS — call would not revert.\n");
    console.log("Per reward token (net to LPs, after the", PROTOCOL_FEE.toString() + "% protocol cut):");
    let any = false;
    for (let i = 0; i < tokens.length; i++) {
      const n = net[i];
      // gross = net / (1 - fee/100); protocol cut = gross - net
      const gross = n === 0n ? 0n : (n * 100n) / (100n - PROTOCOL_FEE);
      const proto = gross - n;
      if (n > 0n) any = true;
      console.log(`  ${tokens[i]}  net=${n.toString()}  protocolCut≈${proto.toString()}`);
    }
    if (!any) console.log("  (all zero — nothing claimable yet; let more time pass)");
  } catch (e: any) {
    console.log("REVERT:", e.shortMessage || e.message);
    if (e.data && e.data !== "0x") console.log("data:", e.data);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
