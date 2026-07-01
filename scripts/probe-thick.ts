import { ethers } from "hardhat";

// Thick "main contract" on Sonic (user-provided). Read-only probe to learn:
//   - what it is (factory / position manager / router)
//   - how it keys pools (fee tier vs tick spacing)
//   - a live pool we can fork-test against
//
//   npx hardhat run scripts/probe-thick.ts --network sonic --config hardhat.config.stratus.ts
const MAIN = "0x7Ca1dCCFB4f49564b8f13E18a67747fd428F1C40";
const USDCe = "0x29219dd400f2Bf60E5a23d13Be72B486D4038894";
const wS = "0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38";

const p = ethers.provider;

async function call(to: string, sig: string, args: any[] = []): Promise<any> {
  const iface = new ethers.Interface([`function ${sig}`]);
  const name = sig.slice(0, sig.indexOf("("));
  const data = iface.encodeFunctionData(name, args);
  try {
    const ret = await p.call({ to, data });
    if (ret === "0x") return undefined;
    const dec = iface.decodeFunctionResult(name, ret);
    return dec.length === 1 ? dec[0] : dec;
  } catch {
    return undefined;
  }
}

async function main() {
  console.log("probing", MAIN, "\n");

  // ---- identity probes ----
  const idSigs = [
    "owner() view returns (address)",
    "factory() view returns (address)",
    "WETH9() view returns (address)",
    "name() view returns (string)",
    "symbol() view returns (string)",
    "treasury() view returns (address)",
    "voter() view returns (address)",
    "poolImplementation() view returns (address)",
    "swapFeeProtocol() view returns (uint8)",
  ];
  console.log("== identity ==");
  for (const s of idSigs) {
    const r = await call(MAIN, s);
    if (r !== undefined) console.log("  ", s.split(" ")[0], "->", r.toString());
  }

  // ---- tickSpacing support (Uni V3: feeAmountTickSpacing; Solidly-fork: tickSpacingInitialized) ----
  console.log("\n== fee/tickSpacing map ==");
  for (const fee of [50, 100, 250, 500, 3000, 10000]) {
    const ts = await call(MAIN, "feeAmountTickSpacing(uint24) view returns (int24)", [fee]);
    if (ts !== undefined && ts != 0n) console.log("  feeAmountTickSpacing(", fee, ") ->", ts.toString());
  }

  // ---- getPool both keyings, across common params ----
  console.log("\n== getPool(USDC.e, wS, ...) ==");
  const tickSpacings = [1, 2, 5, 8, 10, 50, 60, 64, 100, 200];
  const feeTiers = [50, 100, 250, 500, 2500, 3000, 10000];
  let found: { pool: string; key: string }[] = [];

  for (const ts of tickSpacings) {
    const pool = await call(MAIN, "getPool(address,address,int24) view returns (address)", [USDCe, wS, ts]);
    if (pool && pool !== ethers.ZeroAddress) found.push({ pool, key: `tickSpacing=${ts}` });
  }
  for (const fee of feeTiers) {
    const pool = await call(MAIN, "getPool(address,address,uint24) view returns (address)", [USDCe, wS, fee]);
    if (pool && pool !== ethers.ZeroAddress) found.push({ pool, key: `fee=${fee}` });
  }
  if (found.length === 0) console.log("  (no USDC.e/wS pool found via getPool on this contract)");
  for (const f of found) console.log("  ", f.key, "->", f.pool);

  // ---- inspect first found pool ----
  if (found.length) {
    const pool = found[0].pool;
    console.log("\n== pool", pool, "==");
    const t0 = await call(pool, "token0() view returns (address)");
    const t1 = await call(pool, "token1() view returns (address)");
    const ts = await call(pool, "tickSpacing() view returns (int24)");
    const fee = await call(pool, "fee() view returns (uint24)");
    const liq = await call(pool, "liquidity() view returns (uint128)");
    const slot0 = await call(
      pool,
      "slot0() view returns (uint160 sqrtPriceX96,int24 tick,uint16 oi,uint16 oc,uint16 ocn,uint8 fp,bool unlocked)"
    );
    console.log("   token0     :", t0);
    console.log("   token1     :", t1);
    console.log("   tickSpacing:", ts?.toString());
    console.log("   fee        :", fee?.toString());
    console.log("   liquidity  :", liq?.toString());
    if (slot0) console.log("   tick       :", slot0[1].toString(), " sqrtP:", slot0[0].toString(), " card:", slot0[3].toString());
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
