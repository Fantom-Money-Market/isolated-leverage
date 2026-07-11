import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

// Smoke-tests the DLMM market through the UNMODIFIED LeverageRouter/UnwindRouter — the
// key architectural claim (StratusDLMMVault needs zero router changes since it inherits
// StratusVaultBase's deposit/withdraw signature directly).
//   npx hardhat run scripts/test-dlmm-leverage.ts --network localhost --config hardhat.config.fork-ui.ts

const ERC20 = [
  "function approve(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
];

async function main() {
  const cfg = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "fork-ui", "dlmm-config.json"), "utf8"));
  const USER = process.env.USER_ADDR || "0x0190933669d250406efcf18b351b954Ea88D5bfD";

  await ethers.provider.send("hardhat_impersonateAccount", [USER]);
  const user = await ethers.getSigner(USER);

  const wS = new ethers.Contract(cfg.tokens.wS.address, ERC20, user);
  const collateral = await ethers.getContractAt("Collateral", cfg.collateral, user);
  const router = await ethers.getContractAt("LeverageRouter", cfg.leverageRouter, user);

  console.log("user wS balance before:", ethers.formatEther(await wS.balanceOf(USER)));
  console.log("user cToken balance before:", await collateral.balanceOf(USER));

  const own = ethers.parseEther("10");
  const borrow = ethers.parseEther("10");
  await (await wS.approve(cfg.leverageRouter, own)).wait();
  const borrowable0 = await ethers.getContractAt("Borrowable", cfg.borrowable0, user);
  await (await borrowable0.borrowApprove(cfg.leverageRouter, borrow)).wait();

  console.log("--- calling LeverageRouter.leverage() ---");
  const tx = await router.leverage(cfg.collateral, own, 0, borrow, 0, 0);
  const receipt = await tx.wait();
  console.log("leverage() OK, gas used:", receipt.gasUsed.toString());

  console.log("user wS balance after:", ethers.formatEther(await wS.balanceOf(USER)));
  const cTokenBal = await collateral.balanceOf(USER);
  console.log("user cToken balance after:", cTokenBal.toString());

  await ethers.provider.send("hardhat_stopImpersonatingAccount", [USER]);

  if (cTokenBal === 0n) throw new Error("leverage produced zero cToken balance");
  console.log("\nLEVERAGE SMOKE TEST PASSED");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
