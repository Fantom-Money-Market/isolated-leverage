import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

// Redeploys BOTH routers and syncs every fork-ui config that references them.
// The per-venue configs (beets/dlmm/thick) copy the router addresses out of the main
// config at deploy time, so patching only config.json silently leaves the other markets
// pointing at a stale router — which is exactly how the adversarial suite ended up
// calling an UnwindRouter that predated unlend().
//
//   npx hardhat run scripts/deploy-routers-all.ts --network localhost --config hardhat.config.fork-ui.ts

const CONFIGS = ["config.json", "beets-config.json", "dlmm-config.json", "thick-config.json"];

async function main() {
  const [deployer] = await ethers.getSigners();

  const lev = await (await ethers.getContractFactory("LeverageRouter", deployer)).deploy();
  await lev.waitForDeployment();
  const levAddr = await lev.getAddress();

  const unwind = await (await ethers.getContractFactory("UnwindRouter", deployer)).deploy();
  await unwind.waitForDeployment();
  const unwindAddr = await unwind.getAddress();

  console.log("LeverageRouter:", levAddr);
  console.log("UnwindRouter  :", unwindAddr);

  for (const name of CONFIGS) {
    const p = path.join(__dirname, "..", "fork-ui", name);
    if (!fs.existsSync(p)) {
      console.log(`skip ${name} (absent)`);
      continue;
    }
    const cfg = JSON.parse(fs.readFileSync(p, "utf8"));
    cfg.leverageRouter = levAddr;
    cfg.unwindRouter = unwindAddr;
    fs.writeFileSync(p, JSON.stringify(cfg, null, 2));
    console.log(`updated fork-ui/${name}`);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
