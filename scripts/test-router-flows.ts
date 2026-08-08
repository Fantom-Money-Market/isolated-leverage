import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

// End-to-end check of the two rewired frontend flows that now go through the routers:
//   supply  -> LeverageRouter.leverage(collateral, a0, a1, 0, 0, minShares)  (zero borrows)
//   withdraw-> UnwindRouter.deleverage(collateral, cTokens, 0, 0)            (zero debt)
// Both must work with approvals pointed at the ROUTER rather than the vault/collateral.
//
//   npx hardhat run scripts/test-router-flows.ts --network localhost --config hardhat.config.fork-ui.ts

const ERC20 = [
  "function approve(address,uint256) returns (bool)",
  "function transfer(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
];
const POOL = "0x324963c267C354c7660Ce8CA3F5f167E05649970";

async function fundFromPool(token: string, to: string, amount: bigint) {
  await ethers.provider.send("hardhat_impersonateAccount", [POOL]);
  await ethers.provider.send("hardhat_setBalance", [POOL, "0x21e19e0c9bab2400000"]);
  const s = await ethers.getSigner(POOL);
  await new ethers.Contract(token, ERC20, s).transfer(to, amount);
  await ethers.provider.send("hardhat_stopImpersonatingAccount", [POOL]);
}

async function main() {
  const cfg = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "fork-ui", "config.json"), "utf8"));
  const [, , , , user] = await ethers.getSigners();
  const wS = cfg.tokens.wS.address;
  const usdc = cfg.tokens.USDCe.address;

  const levRouter = await ethers.getContractAt("LeverageRouter", cfg.leverageRouter, user);
  const unwind = await ethers.getContractAt("UnwindRouter", cfg.unwindRouter, user);
  const collateral = await ethers.getContractAt("Collateral", cfg.collateral);

  const amt0 = ethers.parseEther("5");
  const amt1 = ethers.parseUnits("0.15", 6);
  await fundFromPool(wS, user.address, amt0);
  await fundFromPool(usdc, user.address, amt1);

  console.log("=== supply via LeverageRouter.leverage(..., 0 borrows) ===");
  await (await new ethers.Contract(wS, ERC20, user).approve(cfg.leverageRouter, amt0)).wait();
  await (await new ethers.Contract(usdc, ERC20, user).approve(cfg.leverageRouter, amt1)).wait();

  const cBefore = await collateral.balanceOf(user.address);
  const tx = await levRouter.leverage(cfg.collateral, amt0, amt1, 0, 0, 0);
  const rc = await tx.wait();
  const cAfter = await collateral.balanceOf(user.address);
  console.log("cTokens:", cBefore.toString(), "->", cAfter.toString(), `(gas ${rc!.gasUsed})`);
  if (cAfter <= cBefore) throw new Error("supply produced no collateral");
  console.log("=> supply OK, one transaction, no exposed window\n");

  console.log("=== withdraw via UnwindRouter.deleverage(..., zero debt) ===");
  const wsBefore = await new ethers.Contract(wS, ERC20, ethers.provider).balanceOf(user.address);
  await (await collateral.connect(user).approve(cfg.unwindRouter, cAfter)).wait();
  const tx2 = await unwind.deleverage(cfg.collateral, cAfter, 0, 0);
  const rc2 = await tx2.wait();

  const cFinal = await collateral.balanceOf(user.address);
  const wsAfter = await new ethers.Contract(wS, ERC20, ethers.provider).balanceOf(user.address);
  console.log("cTokens:", cAfter.toString(), "->", cFinal.toString(), `(gas ${rc2!.gasUsed})`);
  console.log("wS returned:", ethers.formatEther(wsAfter - wsBefore));
  if (cFinal >= cAfter) throw new Error("withdraw did not burn collateral");
  if (wsAfter <= wsBefore) throw new Error("withdraw returned no underlying");
  console.log("=> withdraw OK, collateral burned and underlying returned\n");

  console.log("ROUTER FLOW CHECKS PASSED");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
