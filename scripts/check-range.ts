import { ethers } from "hardhat";

const ADDR = process.env.ADDR || "0x096245c02268dceC8Ae96331EEc43eAF6cD1e8EA";

async function main() {
  const v = await ethers.getContractAt("StratusShadowVault", ADDR);
  const poolAddr = await v.pool();
  const pool = await ethers.getContractAt("ICLPoolView", poolAddr);
  const [sqrtPriceX96, tick] = await pool.slot0();

  console.log("vault       :", ADDR);
  console.log("pool        :", poolAddr);
  console.log("current tick:", tick.toString());
  console.log("sqrtPriceX96:", sqrtPriceX96.toString());
  console.log("");

  const labels = ["tight (50%)", "medium (30%)", "wide (20%)"];
  for (let i = 0; i < 3; i++) {
    const lower = await v.rangeLower(i);
    const upper = await v.rangeUpper(i);
    const inRange = tick >= lower && tick < upper;
    console.log(
      `range ${i} ${labels[i]}: [${lower}, ${upper}) -> ${inRange ? "IN RANGE" : "OUT OF RANGE"}`
    );
  }

  const [t0, t1] = await v.getTotalAmounts();
  console.log("");
  console.log("totalAmounts (token0, token1):", t0.toString(), t1.toString());
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
