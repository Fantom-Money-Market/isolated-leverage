import { ethers } from "hardhat";

// Find a Thick CL pool with real liquidity + TWAP cardinality for fork testing.
//   npx hardhat run scripts/probe-thick2.ts --network sonic --config hardhat.config.stratus.ts
const FACTORY = "0x7Ca1dCCFB4f49564b8f13E18a67747fd428F1C40";
const p = ethers.provider;

// candidate Sonic tokens
const T: Record<string, string> = {
  wS: "0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38",
  "USDC.e": "0x29219dd400f2Bf60E5a23d13Be72B486D4038894",
  WETH: "0x50c42dEAcD8Fc9773493ED674b675bE577f2634b",
  scUSD: "0xd3DCe716f3eF535C5Ff8d041c1A41C3bd89b97aE",
  stS: "0xE5DA20F15420aD15DE0fa650600aFc998bbE3955",
  EQUAL: "0xddF026a3c95Ef5B1e60f57DF4c1c7A2cd09Fee0E",
};

async function call(to: string, sig: string, args: any[] = []): Promise<any> {
  const iface = new ethers.Interface([`function ${sig}`]);
  const name = sig.slice(0, sig.indexOf("("));
  try {
    const ret = await p.call({ to, data: iface.encodeFunctionData(name, args) });
    if (ret === "0x") return undefined;
    const dec = iface.decodeFunctionResult(name, ret);
    return dec.length === 1 ? dec[0] : dec;
  } catch {
    return undefined;
  }
}

async function inspect(pool: string) {
  const liq = await call(pool, "liquidity() view returns (uint128)");
  const slot0 = await call(
    pool,
    "slot0() view returns (uint160 s,int24 t,uint16 oi,uint16 oc,uint16 ocn,uint8 fp,bool u)"
  );
  const ts = await call(pool, "tickSpacing() view returns (int24)");
  return {
    liq: liq?.toString() ?? "?",
    tick: slot0 ? slot0[1].toString() : "?",
    card: slot0 ? slot0[3].toString() : "?",
    ts: ts?.toString() ?? "?",
  };
}

async function main() {
  const names = Object.keys(T);
  const spacings = [1, 8, 50, 100, 200];
  console.log("scanning Thick pools with liquidity...\n");
  for (let i = 0; i < names.length; i++) {
    for (let j = i + 1; j < names.length; j++) {
      for (const sp of spacings) {
        const pool = await call(FACTORY, "getPool(address,address,int24) view returns (address)", [
          T[names[i]],
          T[names[j]],
          sp,
        ]);
        if (pool && pool !== ethers.ZeroAddress) {
          const info = await inspect(pool);
          if (info.liq !== "0" && info.liq !== "?") {
            console.log(
              `${names[i]}/${names[j]} ts=${sp.toString().padStart(3)} ${pool}  liq=${info.liq}  card=${info.card}  tick=${info.tick}`
            );
          }
        }
      }
    }
  }
  console.log("\n(only pools with non-zero liquidity shown)");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
