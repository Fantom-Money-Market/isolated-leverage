import { ethers } from "hardhat";

// Check the Thick test pool's reserves + TWAP availability before fork-testing.
//   npx hardhat run scripts/probe-thick3.ts --network sonic --config hardhat.config.stratus.ts
const POOL = "0xb1BC4B830FCbA2184B92e15b9133c41160518038"; // wS/USDC.e ts=8
const wS = "0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38";
const USDCe = "0x29219dd400f2Bf60E5a23d13Be72B486D4038894";
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
    return "ERR:" + (e.shortMessage || e.message || "").slice(0, 40);
  }
}

async function main() {
  const bal0 = await call(wS, "balanceOf(address) view returns (uint256)", [POOL]);
  const bal1 = await call(USDCe, "balanceOf(address) view returns (uint256)", [POOL]);
  console.log("pool wS reserve   :", ethers.formatUnits(bal0, 18), "wS");
  console.log("pool USDC.e reserve:", ethers.formatUnits(bal1, 6), "USDC.e");

  // observe() over 30 min — needed for TWAP valuation
  const obs = await call(
    POOL,
    "observe(uint32[]) view returns (int56[] tickCumulatives, uint160[] sp)",
    [[1800, 0]]
  );
  if (Array.isArray(obs)) {
    const tc = obs[0];
    const twapTick = (BigInt(tc[1]) - BigInt(tc[0])) / 1800n;
    console.log("observe(1800,0)   : ok, 30m TWAP tick =", twapTick.toString());
  } else {
    console.log("observe(1800,0)   :", obs);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
