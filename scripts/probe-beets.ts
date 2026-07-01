import { ethers } from "hardhat";

// Beets v3 (= Balancer v3) Vault on Sonic. Read-only probe to confirm the architecture
// and grab its satellite contracts.
//   npx hardhat run scripts/probe-beets.ts --network sonic --config hardhat.config.stratus.ts
const VAULT = "0xbA1333333333a1BA1108E8412f11850A5C319bA9";
const p = ethers.provider;

async function call(to: string, sig: string, args: any[] = []): Promise<any> {
  const iface = new ethers.Interface([`function ${sig}`]);
  const name = sig.slice(0, sig.indexOf("("));
  try {
    const ret = await p.call({ to, data: iface.encodeFunctionData(name, args) });
    if (ret === "0x") return undefined;
    const dec = iface.decodeFunctionResult(name, ret);
    return dec.length === 1 ? dec[0] : dec;
  } catch (e: any) {
    return "ERR:" + (e.shortMessage || e.message || "").slice(0, 50);
  }
}

async function main() {
  console.log("probing Balancer/Beets v3 Vault", VAULT, "\n");
  const sigs = [
    "version() view returns (string)",
    "getVaultExtension() view returns (address)",
    "getVaultAdmin() view returns (address)",
    "getAuthorizer() view returns (address)",
    "getProtocolFeeController() view returns (address)",
    "isUnlocked() view returns (bool)",
    "getPoolCount() view returns (uint256)",
  ];
  for (const s of sigs) {
    const r = await call(VAULT, s);
    console.log("  ", s.split(" ")[0].padEnd(26), "->", r === undefined ? "(no data)" : r.toString());
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
