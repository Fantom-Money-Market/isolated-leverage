import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

// Simulates real harvest activity on the fork so the frontend's useVenueRewardApy hook has
// actual rewardPerShareStored growth to sample (rather than a permanently-null "—").
//   npx hardhat run scripts/simulate-harvest.ts --network localhost --config hardhat.config.fork-ui.ts

const ERC20 = [
  "function approve(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
];

const THREE_DAYS = 3 * 24 * 60 * 60;

async function advanceTime(seconds: number) {
  await ethers.provider.send("evm_increaseTime", [seconds]);
  await ethers.provider.send("evm_mine", []);
}

async function main() {
  const dlmmCfg = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "fork-ui", "dlmm-config.json"), "utf8"));
  const beetsCfg = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "fork-ui", "beets-config.json"), "utf8"));
  const USER = process.env.USER_ADDR || "0x0190933669d250406efcf18b351b954Ea88D5bfD";

  await ethers.provider.send("hardhat_impersonateAccount", [USER]);
  const user = await ethers.getSigner(USER);

  // ===== 1. Let existing DLMM bins accrue METRO, then harvest via a plain deposit() =====
  // The hook pays rewards from real balances, NOT minting (verified source: LBHooksMCRewarder.
  // _updateRewards() calls masterChef.claim(pids), and with the MasterChef's mint-metro flag
  // in its normal `false` state that transfers METRO from the MC's own funded balance; the
  // hook's _getPendingTotalRewards() additionally counts METRO topped up directly to the hook).
  // Do NOT flip the MC's getMintMetroFlag() on the fork: MC has no mint rights on METRO, so
  // forcing it makes every hook-touching claim/mint/burn revert OwnableUnauthorizedAccount.
  console.log("--- advancing time 3 days for DLMM METRO accrual ---");
  await advanceTime(THREE_DAYS);

  const vault = await ethers.getContractAt("StratusDLMMVault", dlmmCfg.vault, user);
  const rpsBefore = await vault.rewardPerShareStored(dlmmCfg.tokens.METRO.address);
  console.log("DLMM rewardPerShareStored[METRO] before:", rpsBefore.toString());

  const vaultToken0 = await vault.token0();
  const isWsToken0 = vaultToken0.toLowerCase() === dlmmCfg.tokens.wS.address.toLowerCase();
  const wS = new ethers.Contract(dlmmCfg.tokens.wS.address, ERC20, user);
  const depositWs = ethers.parseEther("1");
  await (await wS.approve(dlmmCfg.vault, depositWs)).wait();
  const tx1 = await vault.deposit(
    isWsToken0 ? depositWs : 0,
    isWsToken0 ? 0 : depositWs,
    USER,
    0
  );
  await tx1.wait();
  console.log("DLMM deposit() OK (triggers _realizeFees -> harvest hook rewards)");

  const rpsAfter = await vault.rewardPerShareStored(dlmmCfg.tokens.METRO.address);
  console.log("DLMM rewardPerShareStored[METRO] after: ", rpsAfter.toString());
  if (rpsAfter <= rpsBefore) throw new Error("DLMM harvest produced no reward growth");

  // ===== 2. Stake real Beets shares (adapter currently has 0 supply), then let the gauge
  //          accrue BEETS/stS emissions on the freshly-staked BPT before harvesting =====
  const adapter = await ethers.getContractAt("StratusBeetsV3Adapter", beetsCfg.adapter, user);
  const adapterToken0 = await adapter.token0();
  const isWsAdapterToken0 = adapterToken0.toLowerCase() === beetsCfg.tokens.wS.address.toLowerCase();

  const wSForBeets = new ethers.Contract(beetsCfg.tokens.wS.address, ERC20, user);
  const stS = new ethers.Contract(beetsCfg.tokens.stS.address, ERC20, user);
  const depositWsBeets = ethers.parseEther("50");
  const depositSts = ethers.parseEther("50");
  await (await wSForBeets.approve(beetsCfg.adapter, depositWsBeets)).wait();
  await (await stS.approve(beetsCfg.adapter, depositSts)).wait();

  console.log("--- depositing into Beets adapter (creates real, persistent shares) ---");
  const tx2 = await adapter.deposit(
    isWsAdapterToken0 ? depositWsBeets : depositSts,
    isWsAdapterToken0 ? depositSts : depositWsBeets,
    USER,
    0
  );
  await tx2.wait();
  const supplyAfterDeposit = await adapter.totalSupply();
  console.log("Beets adapter totalSupply after deposit:", ethers.formatEther(supplyAfterDeposit));
  if (supplyAfterDeposit === 0n) throw new Error("Beets deposit produced zero shares");

  console.log("--- advancing time 3 more days for Beets gauge accrual ---");
  await advanceTime(THREE_DAYS);

  const rpsBeetsBefore = await adapter.rewardPerShareStored(beetsCfg.tokens.BEETS.address);
  const rpsStsBefore = await adapter.rewardPerShareStored(beetsCfg.tokens.stS.address);

  const tx3 = await adapter.collectGaugeRewards();
  const receipt3 = await tx3.wait();
  console.log("Beets collectGaugeRewards() OK, gas used:", receipt3!.gasUsed.toString());

  const rpsBeetsAfter = await adapter.rewardPerShareStored(beetsCfg.tokens.BEETS.address);
  const rpsStsAfter = await adapter.rewardPerShareStored(beetsCfg.tokens.stS.address);
  console.log("Beets rewardPerShareStored[BEETS]:", rpsBeetsBefore.toString(), "->", rpsBeetsAfter.toString());
  console.log("Beets rewardPerShareStored[stS]:  ", rpsStsBefore.toString(), "->", rpsStsAfter.toString());
  if (rpsBeetsAfter <= rpsBeetsBefore && rpsStsAfter <= rpsStsBefore) {
    throw new Error("Beets harvest produced no reward growth on either reward token");
  }

  await ethers.provider.send("hardhat_stopImpersonatingAccount", [USER]);
  console.log("\nHARVEST SIMULATION PASSED — both vaults now have real reward growth to sample.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
