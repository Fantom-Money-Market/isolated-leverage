import { ethers } from "hardhat";

// Mirrors pricePerShareSafe()/getTotalValueSafe() math against the LIVE vault
// (which predates the functions) to validate the logic and show the numbers.
const VAULT = "0x096245c02268dceC8Ae96331EEc43eAF6cD1e8EA";
const DEC1 = 6; // token1 = USDC

async function main() {
  const v = await ethers.getContractAt("StratusShadowVault", VAULT);
  const pool = await ethers.getContractAt("IShadowV3Pool", await v.pool());

  const [t0, t1] = await v.getTotalAmountsSafe();
  const [tc] = await pool.observe([1800, 0]);
  const twapTick = Number((tc[1] - tc[0]) / 1800n);
  // contract uses TickMath.getSqrtRatioAtTick; this float approx is fine for a sanity check
  const price1e18 = BigInt(Math.round(Math.pow(1.0001, twapTick) * 1e18));

  const valueSafe = t1 + (t0 * price1e18) / 10n ** 18n; // token1 base units
  const supply = await v.totalSupply();
  const pps = (valueSafe * 10n ** 18n) / supply; // token1 base units per 1e18 ALPT

  console.log("getTotalAmountsSafe :", t0.toString(), "wS,", t1.toString(), "USDC-raw");
  console.log("twapTick            :", twapTick);
  console.log("getTotalValueSafe   :", valueSafe.toString(), "USDC-raw  (~$" + (Number(valueSafe) / 10 ** DEC1).toFixed(4) + ")");
  console.log("totalSupply         :", supply.toString(), "(wei ALPT)");
  console.log("pricePerShareSafe   :", pps.toString(), "USDC-raw per 1e18 ALPT");
  console.log("  per 1e18 ALPT     : ~$" + (Number(pps) / 10 ** DEC1).toExponential(4));
  console.log("  per 1 wei ALPT    : ~$" + (Number(valueSafe) / 10 ** DEC1 / Number(supply)).toExponential(4));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
