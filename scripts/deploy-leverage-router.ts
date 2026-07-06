import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

// Deploys LeverageRouter against the EXISTING fork deployment (no full redeploy) and
// records its address in fork-ui/config.json.
//   npx hardhat run scripts/deploy-leverage-router.ts --network localhost --config hardhat.config.fork-ui.ts

async function main() {
  const [deployer] = await ethers.getSigners();
  const router = await (await ethers.getContractFactory("LeverageRouter", deployer)).deploy();
  await router.waitForDeployment();
  const addr = await router.getAddress();
  console.log("LeverageRouter:", addr);

  const cfgPath = path.join(__dirname, "..", "fork-ui", "config.json");
  const cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8"));
  cfg.leverageRouter = addr;
  fs.writeFileSync(cfgPath, JSON.stringify(cfg, null, 2));
  console.log("updated fork-ui/config.json");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
