import { ethers } from "hardhat";
import { expect } from "chai";
import { takeSnapshot, SnapshotRestorer } from "@nomicfoundation/hardhat-network-helpers";

/**
 * Drain-resistance test (vector #1): show that getTotalAmounts() (spot) is
 * manipulable by a price move while getTotalAmountsSafe() (TWAP) is not — i.e.
 * a lender MUST price collateral off the *Safe* variant.
 *
 *   npx hardhat test test/stratus/manipulation.fork.test.ts --config hardhat.config.stratus.ts
 *
 * Runs on the forked Sonic `hardhat` network and overrides the pool's slot0
 * (sqrtPriceX96 + tick) directly — equivalent to a large swap for spot, but the
 * historical observations the TWAP reads are untouched.
 */
const VAULT = "0x096245c02268dceC8Ae96331EEc43eAF6cD1e8EA";
const POOL_STORAGE_LOCATION = "0xf047b0c59244a0faf8e48cb6b6fde518e6717176152b6dd953628cd9dccb2800";

// token0 = wS (18), token1 = USDC (6)
const DEC0 = 18, DEC1 = 6;

async function twapPriceUsdcPerWs(pool: any): Promise<number> {
  const [tc] = await pool.observe([1800, 0]);
  const twapTick = Number((tc[1] - tc[0]) / 1800n);
  // raw token1/token0 ratio, then decimal-adjust to human USDC per wS
  return Math.pow(1.0001, twapTick) * 10 ** (DEC0 - DEC1);
}

function valueUsdc(total0: bigint, total1: bigint, wsPrice: number): number {
  return Number(total1) / 10 ** DEC1 + (Number(total0) / 10 ** DEC0) * wsPrice;
}

describe("getTotalAmountsSafe resists spot manipulation (Sonic fork)", () => {
  // This test overwrites the pool's slot0 directly; snapshot/restore so the
  // manipulated price never leaks into other tests sharing the same fork.
  let snap: SnapshotRestorer;
  beforeEach(async () => {
    snap = await takeSnapshot();
  });
  afterEach(async () => {
    await snap.restore();
  });

  it("spot value can be moved a lot; TWAP value barely moves", async () => {
    const v = await ethers.getContractAt("StratusShadowVault", VAULT);
    const pool = await ethers.getContractAt("IShadowV3Pool", await v.pool());

    // A fixed "true" price (TWAP) to value both readings consistently.
    const wsPrice = await twapPriceUsdcPerWs(pool);

    const [sp0a, sp1a] = await v.getTotalAmounts();
    const [sf0a, sf1a] = await v.getTotalAmountsSafe();
    const spotBefore = valueUsdc(sp0a, sp1a, wsPrice);
    const safeBefore = valueUsdc(sf0a, sf1a, wsPrice);
    console.log("before  spot value:", spotBefore.toExponential(4), " safe value:", safeBefore.toExponential(4));

    // ---- manipulate SPOT only: 4x price via sqrtPriceX96, leaving the tick untouched so the
    //      TWAP (observe() extrapolates from the stored tick) is byte-for-byte unchanged. This is
    //      what a flash swap actually does — it moves spot, not the 30-min average — and it keeps
    //      the assertion deterministic regardless of how much fork time earlier tests advanced.
    const raw = BigInt(await ethers.provider.send("eth_getStorageAt", [await pool.getAddress(), POOL_STORAGE_LOCATION, "latest"]));
    const sqrtPriceX96 = raw & ((1n << 160n) - 1n);
    const newSqrt = sqrtPriceX96 * 2n;
    const newWord = ((raw >> 160n) << 160n) | newSqrt;
    await ethers.provider.send("hardhat_setStorageAt", [
      await pool.getAddress(),
      POOL_STORAGE_LOCATION,
      "0x" + newWord.toString(16).padStart(64, "0"),
    ]);

    // confirm the override took
    const s0 = await pool.slot0();
    expect(s0[0]).to.equal(newSqrt);

    const [sp0b, sp1b] = await v.getTotalAmounts();
    const [sf0b, sf1b] = await v.getTotalAmountsSafe();
    const spotAfter = valueUsdc(sp0b, sp1b, wsPrice);
    const safeAfter = valueUsdc(sf0b, sf1b, wsPrice);
    console.log("after   spot value:", spotAfter.toExponential(4), " safe value:", safeAfter.toExponential(4));

    // Composition: a 4x spot move pushes price above all 3 ranges, so getTotalAmounts
    // reports the position fully converted to token1 (wS collapses to ~0) — while the
    // TWAP reading is byte-for-byte identical.
    console.log("spot wS:  before", sp0a.toString(), "-> after", sp0b.toString());
    console.log("safe wS:  before", sf0a.toString(), "-> after", sf0b.toString());

    const spotMovePct = Math.abs(spotAfter - spotBefore) / spotBefore * 100;
    const safeMovePct = Math.abs(safeAfter - safeBefore) / safeBefore * 100;
    console.log(`spot value moved ${spotMovePct.toFixed(2)}% ; safe value moved ${safeMovePct.toFixed(4)}%`);

    // The point: a lender pricing off spot is manipulable; off the TWAP it is
    // materially protected. (This override overstates the TWAP move — it applies
    // the manipulated tick over the whole gap since the last observation; a real
    // 1-block swap moves it far less.)
    expect(spotMovePct).to.be.greaterThan(2); // spot value mis-states the collateral
    expect(safeMovePct).to.be.lessThan(spotMovePct / 3); // TWAP is materially more resistant
    expect(Number(sp0b)).to.be.lessThan(Number(sp0a) / 2); // spot composition fully collapsed
  });
});
