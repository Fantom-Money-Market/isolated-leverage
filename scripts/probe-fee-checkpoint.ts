import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

async function main() {
  const cfg = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "fork-ui", "dlmm-config.json"), "utf8"));
  const v = await ethers.getContractAt("StratusDLMMVault", cfg.vault);
  const supply = await v.totalSupply();
  const cp = await v.lastValueCheckpoint();
  const fee = await v.protocolFee();
  const factory = await v.factory();
  console.log("vault           :", cfg.vault);
  console.log("totalSupply     :", supply.toString());
  console.log("lastValueCheckpt:", cp.toString());
  console.log("protocolFee     :", fee.toString(), "%");
  console.log("factory bal ALPT:", (await v.balanceOf(factory)).toString());
  console.log("safePriceAvail  :", await v.isSafePriceAvailable());
  try { console.log("getTotalValueSafe:", (await v.getTotalValueSafe()).toString()); }
  catch (e: any) { console.log("getTotalValueSafe: REVERT", e.shortMessage ?? ""); }
  console.log("binIds length   :", (await v.binIdsLength()).toString());
}
main().catch((e) => { console.error(e); process.exit(1); });
