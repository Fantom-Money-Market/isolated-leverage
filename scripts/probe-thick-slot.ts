import { ethers } from "hardhat";

// Find which storage slot of the Thick pool holds slot0 (packed sqrtPriceX96 in low 160 bits).
//   npx hardhat run scripts/probe-thick-slot.ts --network sonic --config hardhat.config.stratus.ts
const POOL = "0xb1BC4B830FCbA2184B92e15b9133c41160518038";
const p = ethers.provider;

async function main() {
  const iface = new ethers.Interface([
    "function slot0() view returns (uint160 sqrtPriceX96,int24 tick,uint16,uint16,uint16,uint8,bool)",
  ]);
  const ret = await p.call({ to: POOL, data: iface.encodeFunctionData("slot0") });
  const dec = iface.decodeFunctionResult("slot0", ret);
  const liveSqrt = BigInt(dec[0]);
  const liveTick = BigInt(dec[1]);
  console.log("live sqrtPriceX96:", liveSqrt.toString());
  console.log("live tick        :", liveTick.toString());

  const mask160 = (1n << 160n) - 1n;
  const tickRaw = liveTick < 0n ? liveTick + (1n << 24n) : liveTick;
  for (let i = 0; i < 60; i++) {
    const raw = BigInt(await p.send("eth_getStorageAt", [POOL, "0x" + i.toString(16), "latest"]));
    if (raw === 0n) continue;
    const low160 = raw & mask160;
    const nextTick = (raw >> 160n) & ((1n << 24n) - 1n);
    const match = low160 === liveSqrt;
    const tickMatch = nextTick === tickRaw;
    if (match || tickMatch || (raw < (1n << 200n) && raw > (1n << 150n))) {
      console.log(
        `slot ${i}: raw=${raw.toString(16).slice(0, 24)}...  low160==sqrt? ${match}  tick@160==tick? ${tickMatch}`
      );
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
