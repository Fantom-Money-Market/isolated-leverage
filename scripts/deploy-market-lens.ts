import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

// Deploys MarketLens registered with every Tarot factory on the fork and records the
// address in fork-ui/config.json.
//   npx hardhat run scripts/deploy-market-lens.ts --network localhost --config hardhat.config.fork-ui.ts

async function main() {
  const [deployer] = await ethers.getSigners();
  const cfgPath = path.join(__dirname, "..", "fork-ui", "config.json");
  const cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8"));
  const beetsCfgPath = path.join(__dirname, "..", "fork-ui", "beets-config.json");
  const beetsCfg = fs.existsSync(beetsCfgPath) ? JSON.parse(fs.readFileSync(beetsCfgPath, "utf8")) : null;
  const dlmmCfgPath = path.join(__dirname, "..", "fork-ui", "dlmm-config.json");
  const dlmmCfg = fs.existsSync(dlmmCfgPath) ? JSON.parse(fs.readFileSync(dlmmCfgPath, "utf8")) : null;

  const thickCfgPath = path.join(__dirname, "..", "fork-ui", "thick-config.json");
  const thickCfg = fs.existsSync(thickCfgPath) ? JSON.parse(fs.readFileSync(thickCfgPath, "utf8")) : null;

  const candidates = [
    cfg.tarotFactory,
    beetsCfg?.tarotFactory,
    dlmmCfg?.tarotFactory,
    thickCfg?.tarotFactory,
  ].filter(Boolean);

  // Only register addresses that actually behave as a Tarot factory on THIS fork. Config
  // files outlive the chain, and because deploy addresses are derived from the deployer's
  // nonce, a stale entry frequently points at a DIFFERENT contract that happens to occupy
  // the same slot after a redeploy — it has code, so a bytecode check isn't enough.
  // Registering one makes getAllMarkets revert with no reason string. Probe the exact
  // call the lens makes instead.
  const probeAbi = ["function allLendingPoolsLength() view returns (uint256)"];
  const factories: string[] = [];
  for (const f of candidates) {
    try {
      await new ethers.Contract(f, probeAbi, ethers.provider).allLendingPoolsLength();
      factories.push(f);
    } catch {
      console.log(`skipping ${f} — not a live Tarot factory on this fork`);
    }
  }
  if (factories.length === 0) throw new Error("no live Tarot factories found — deploy a market first");
  console.log("registering factories:", factories);

  const lens = await (await ethers.getContractFactory("MarketLens", deployer)).deploy(factories);
  await lens.waitForDeployment();
  const addr = await lens.getAddress();
  console.log("MarketLens:", addr);

  // smoke check: enumerate markets via eth_call
  const markets = await lens.getAllMarkets.staticCall();
  console.log("markets found:", markets.length);
  for (const m of markets) {
    console.log(
      ` kind=${m.kind} ${m.token0.symbol}/${m.token1.symbol}` +
      ` alpt=${m.alpt} collateral=${m.collateral}` +
      ` tvl(token1)=${ethers.formatUnits(m.totalValueSafe, Number(m.token1.decimals))}` +
      ` cash0=${ethers.formatUnits(m.cash0, Number(m.token0.decimals))}` +
      ` cash1=${ethers.formatUnits(m.cash1, Number(m.token1.decimals))}`
    );
  }

  cfg.marketLens = addr;
  fs.writeFileSync(cfgPath, JSON.stringify(cfg, null, 2));
  console.log("updated fork-ui/config.json");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
