import { ethers } from "hardhat";

const VOTER = "0x9F59398D0a397b2EEB8a6123a6c7295cB0b0062D";

const A = process.env.TOKEN_A || ethers.ZeroAddress;
const B = process.env.TOKEN_B || ethers.ZeroAddress;
const TS = Number(process.env.TICK_SPACING || 0);

// Shadow/Ramses-style CL tick spacings to probe if not given / not enumerable.
const CANDIDATES = [1, 2, 5, 10, 25, 50, 100, 200, 250, 500, 1000, 2000];

async function main() {
  const voter = await ethers.getContractAt("IShadowVoter", VOTER);

  if (A === ethers.ZeroAddress) {
    const dummy = await voter.gaugeForClPool(ethers.ZeroAddress, ethers.ZeroAddress, 1);
    console.log("IShadowVoter ABI matches live voter. gaugeForClPool(0,0,1) =>", dummy);
    return;
  }

  // Build the list of tick spacings to try.
  let spacings: number[] = TS ? [TS] : [];
  if (spacings.length === 0) {
    // Try the voter's enumerator first (raw ABI; may not exist on this deployment).
    try {
      const raw = new ethers.Contract(
        VOTER,
        ["function tickSpacingsForPair(address,address) view returns (int24[])"],
        ethers.provider
      );
      const arr: bigint[] = await raw.tickSpacingsForPair(A, B);
      spacings = arr.map((x) => Number(x));
      console.log("tickSpacingsForPair:", spacings.join(", ") || "(empty)");
    } catch {
      console.log("tickSpacingsForPair not available; probing common spacings.");
    }
    if (spacings.length === 0) spacings = CANDIDATES;
  }

  // Find a tick spacing that has a gauge.
  let tickSpacing = 0;
  let gauge = ethers.ZeroAddress;
  for (const s of spacings) {
    try {
      const g = await voter.gaugeForClPool(A, B, s);
      if (g !== ethers.ZeroAddress) {
        tickSpacing = s;
        gauge = g;
        break;
      }
    } catch {
      /* skip */
    }
  }

  if (gauge === ethers.ZeroAddress) {
    console.log("No gauged CL pool found for this pair across:", spacings.join(", "));
    return;
  }

  const g = await ethers.getContractAt("IShadowGaugeV3", gauge);
  const pool = await g.pool();
  const p = await ethers.getContractAt("IShadowV3Pool", pool);
  const slot0 = await p.slot0();

  console.log("tickSpacing :", tickSpacing);
  console.log("gauge       :", gauge);
  console.log("pool        :", pool);
  console.log("token0      :", await p.token0());
  console.log("token1      :", await p.token1());
  console.log("currentTick :", slot0[1].toString());
  console.log("rewardTokens:", await g.getRewardTokens());
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
