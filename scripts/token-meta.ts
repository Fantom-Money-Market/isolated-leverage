import { ethers } from "hardhat";

const VAULT = process.env.VAULT || "0x096245c02268dceC8Ae96331EEc43eAF6cD1e8EA";

async function symbolOf(addr: string): Promise<string> {
  const asStr = new ethers.Contract(addr, ["function symbol() view returns (string)"], ethers.provider);
  try {
    return `string("${await asStr.symbol()}")`;
  } catch {
    // Some tokens (MKR-style) return bytes32 for symbol()
    const asB32 = new ethers.Contract(addr, ["function symbol() view returns (bytes32)"], ethers.provider);
    try {
      const b = await asB32.symbol();
      return `bytes32(${b} => "${ethers.decodeBytes32String(b)}")`;
    } catch {
      return "<symbol() reverts / undecodable>";
    }
  }
}

async function main() {
  const v = await ethers.getContractAt("StratusShadowVault", VAULT);
  console.log("vault       :", VAULT);
  console.log("name        :", JSON.stringify(await v.name()));
  console.log("symbol      :", JSON.stringify(await v.symbol()));
  console.log("decimals    :", (await v.decimals()).toString());

  const t0 = await v.token0();
  const t1 = await v.token1();
  console.log("token0       :", t0, "symbol =>", await symbolOf(t0));
  console.log("token1       :", t1, "symbol =>", await symbolOf(t1));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
