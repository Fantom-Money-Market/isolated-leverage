import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

// Smoke-tests deleverage/unwind on the DLMM market through the UNMODIFIED UnwindRouter.
//   npx hardhat run scripts/test-dlmm-unwind.ts --network localhost --config hardhat.config.fork-ui.ts

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
  const router = await ethers.getContractAt("UnwindRouter", cfg.unwindRouter, user);

  const cTokenBal: bigint = await collateral.balanceOf(USER);
  console.log("user cToken balance before:", cTokenBal.toString());
  if (cTokenBal === 0n) throw new Error("no cToken position to unwind — run test-dlmm-leverage.ts first");
  console.log("user wS balance before:", ethers.formatEther(await wS.balanceOf(USER)));

  await (await collateral.approve(cfg.unwindRouter, cTokenBal)).wait();

  console.log("--- calling UnwindRouter.deleverage() (full exit) ---");
  const tx = await router.deleverage(cfg.collateral, cTokenBal, 0, 0);
  const receipt = await tx.wait();
  console.log("deleverage() OK, gas used:", receipt.gasUsed.toString());

  const cTokenAfter: bigint = await collateral.balanceOf(USER);
  console.log("user cToken balance after:", cTokenAfter.toString());
  console.log("user wS balance after:", ethers.formatEther(await wS.balanceOf(USER)));

  await ethers.provider.send("hardhat_stopImpersonatingAccount", [USER]);

  if (cTokenAfter >= cTokenBal) throw new Error("deleverage did not reduce cToken balance");
  console.log("\nUNWIND SMOKE TEST PASSED");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
