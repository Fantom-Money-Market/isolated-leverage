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

  const factories = [cfg.tarotFactory, beetsCfg?.tarotFactory, dlmmCfg?.tarotFactory].filter(Boolean);
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
