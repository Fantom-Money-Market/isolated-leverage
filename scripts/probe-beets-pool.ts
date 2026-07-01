import { ethers } from "hardhat";

// Probe a Beets v3 pool to derive the exact rate/decimal normalization for valuation.
//   npx hardhat run scripts/probe-beets-pool.ts --network sonic --config hardhat.config.stratus.ts
const VAULT = "0xbA1333333333a1BA1108E8412f11850A5C319bA9";
const POOL = "0x75b000584a7d86fb3ef5e15ba26f4c52b41be0e9";
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
    return "ERR:" + (e.shortMessage || e.message || "").slice(0, 60);
  }
}

async function meta(token: string) {
  const sym = await call(token, "symbol() view returns (string)");
  const dec = await call(token, "decimals() view returns (uint8)");
  return `${sym} (${dec?.toString()}d)`;
}

async function main() {
  console.log("pool BPT:", POOL);
  console.log("  name     :", await call(POOL, "name() view returns (string)"));
  console.log("  symbol   :", await call(POOL, "symbol() view returns (string)"));
  console.log("  decimals :", (await call(POOL, "decimals() view returns (uint8)"))?.toString());
  console.log("  bptSupply:", (await call(VAULT, "totalSupply(address) view returns (uint256)", [POOL]))?.toString());
  const poolRate = await call(POOL, "getRate() view returns (uint256)");
  console.log("  getRate():", poolRate?.toString());

  const info = await call(
    VAULT,
    "getPoolTokenInfo(address) view returns (address[] tokens, (uint8 tokenType, address rateProvider, bool paysYieldFees)[] tokenInfo, uint256[] balancesRaw, uint256[] live18)",
    [POOL]
  );
  const rates = await call(
    VAULT,
    "getPoolTokenRates(address) view returns (uint256[] decimalScalingFactors, uint256[] tokenRates)",
    [POOL]
  );
  const live = await call(VAULT, "getCurrentLiveBalances(address) view returns (uint256[])", [POOL]);

  if (typeof info === "string") {
    console.log("getPoolTokenInfo:", info);
    return;
  }
  const [tokens, tokenInfo, balancesRaw, live18] = info;
  const [scalingFactors, tokenRates] = rates;

  console.log("\n# tokens:", tokens.length);
  for (let i = 0; i < tokens.length; i++) {
    console.log(`\n[${i}] ${tokens[i]}  ${await meta(tokens[i])}`);
    console.log("   tokenType      :", tokenInfo[i].tokenType.toString(), tokenInfo[i].tokenType == 1n ? "(WITH_RATE)" : "(STANDARD)");
    console.log("   rateProvider   :", tokenInfo[i].rateProvider);
    if (tokenInfo[i].rateProvider !== ethers.ZeroAddress) {
      const r = await call(tokenInfo[i].rateProvider, "getRate() view returns (uint256)");
      console.log("   rateProvider.getRate():", r?.toString());
    }
    console.log("   balanceRaw     :", balancesRaw[i].toString());
    console.log("   scalingFactor  :", scalingFactors[i].toString());
    console.log("   tokenRate      :", tokenRates[i].toString());
    console.log("   liveScaled18   :", live[i].toString());
    // verify relationship: live18 ?= raw * scalingFactor * rate / 1e18
    const guess = (BigInt(balancesRaw[i]) * BigInt(scalingFactors[i]) * BigInt(tokenRates[i])) / (10n ** 18n);
    console.log("   raw*sf*rate/1e18:", guess.toString(), guess === BigInt(live[i]) ? "== live ✓" : "(differs)");
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
