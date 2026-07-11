import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

// Second consecutive DLMM harvest cycle — proves reward growth continues across repeated
// harvests (advance time, deposit to trigger _realizeFees -> hook claim, check growth).
//   npx hardhat run scripts/harvest-again-dlmm.ts --network localhost --config hardhat.config.fork-ui.ts

const ERC20 = ["function approve(address,uint256) returns (bool)"];

async function main() {
  const dlmmCfg = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "fork-ui", "dlmm-config.json"), "utf8"));
  const USER = process.env.USER_ADDR || "0x0190933669d250406efcf18b351b954Ea88D5bfD";

  await ethers.provider.send("hardhat_impersonateAccount", [USER]);
  const user = await ethers.getSigner(USER);
  const vault = await ethers.getContractAt("StratusDLMMVault", dlmmCfg.vault, user);

  const rpsBefore = await vault.rewardPerShareStored(dlmmCfg.tokens.METRO.address);
  console.log("rewardPerShareStored[METRO] before:", rpsBefore.toString());

  await ethers.provider.send("evm_increaseTime", [24 * 60 * 60]);
  await ethers.provider.send("evm_mine", []);

  const wS = new ethers.Contract(dlmmCfg.tokens.wS.address, ERC20, user);
  await (await wS.approve(dlmmCfg.vault, ethers.parseEther("1"))).wait();
  const isWsToken0 = (await vault.token0()).toLowerCase() === dlmmCfg.tokens.wS.address.toLowerCase();
  await (
    await vault.deposit(isWsToken0 ? ethers.parseEther("1") : 0, isWsToken0 ? 0 : ethers.parseEther("1"), USER, 0)
  ).wait();

  const rpsAfter = await vault.rewardPerShareStored(dlmmCfg.tokens.METRO.address);
  console.log("rewardPerShareStored[METRO] after: ", rpsAfter.toString());
  if (rpsAfter <= rpsBefore) throw new Error("no growth on second harvest cycle");
  console.log("\nSECOND CONSECUTIVE DLMM HARVEST PASSED");

  await ethers.provider.send("hardhat_stopImpersonatingAccount", [USER]);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
