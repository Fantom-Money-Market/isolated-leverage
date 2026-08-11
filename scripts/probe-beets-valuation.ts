import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

// Cross-checks StratusBeetsV3Adapter.getTotalValueSafe() against the pool's real
// composition. This value IS the collateral price for the Beets lending market, so a
// scaling error here misprices every borrow against it.

const VAULT_ABI = [
  "function getPoolTokenRates(address) view returns (uint256[], uint256[])",
  "function getPoolTokenInfo(address) view returns (address[], (uint8,address,bool,bool)[], uint256[], uint256[])",
];
const ERC20 = ["function decimals() view returns (uint8)", "function symbol() view returns (string)"];

async function main() {
  const cfg = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "fork-ui", "beets-config.json"), "utf8"));
  const a = await ethers.getContractAt("StratusBeetsV3Adapter", cfg.adapter);
  const bpt = await a.bpt();
  const vaultAddr = await a.vault();
  const v = new ethers.Contract(vaultAddr, VAULT_ABI, ethers.provider);

  const supply: bigint = await a.totalSupply();
  const [sf, rates] = await v.getPoolTokenRates(bpt);
  const bptRate: bigint = await new ethers.Contract(bpt, ["function getRate() view returns (uint256)"], ethers.provider).getRate();
  const value: bigint = await a.getTotalValueSafe();
  const pps: bigint = await a.pricePerShareSafe();
  const t1 = await a.token1();
  const dec1: number = Number(await new ethers.Contract(t1, ERC20, ethers.provider).decimals());
  const sym1: string = await new ethers.Contract(t1, ERC20, ethers.provider).symbol();

  console.log("adapter supply (BPT) :", ethers.formatEther(supply));
  console.log("scalingFactors       :", sf.map((x: bigint) => x.toString()).join(", "));
  console.log("token rates          :", rates.map((x: bigint) => x.toString()).join(", "));
  console.log("bpt.getRate()        :", ethers.formatEther(bptRate));
  console.log(`token1               : ${sym1} (${dec1}d)`);
  console.log(`getTotalValueSafe()  : ${ethers.formatUnits(value, dec1)} ${sym1}`);
  console.log(`pricePerShareSafe()  : ${pps} (raw)`);

  // Independent expectation: for a stable pool, 1 BPT is worth ~bptRate units of the
  // pool's INVARIANT numeraire, and token1 is worth rates[1] of that same numeraire per
  // whole token, so:
  //     value_in_token1 = supply * bptRate / rates[1]
  // with sf[1] = 10^(18-decimals1) carrying the result into token1 BASE units.
  //
  // A first pass at this check divided by 1e18 alone and read 0.93x. That was the CHECK
  // being wrong, not the contract: stS is a rate-bearing token trading at 1.076 of the
  // numeraire, and ignoring its rate overstates how many stS a BPT is worth.
  const expected = (supply * bptRate) / (sf[1] * rates[1]);
  console.log(`independent estimate : ${ethers.formatUnits(expected, dec1)} ${sym1}`);
  if (supply > 0n) {
    const diff = value > expected ? value - expected : expected - value;
    const driftBps = expected > 0n ? (diff * 10000n) / expected : 0n;
    console.log(`drift                : ${driftBps} bps`);
    if (driftBps > 1n) {
      throw new Error(`getTotalValueSafe drifts ${driftBps} bps from the pool primitives`);
    }
  }
  console.log("\nBEETS VALUATION SCALE OK");
}
main().catch((e) => { console.error(e); process.exit(1); });
