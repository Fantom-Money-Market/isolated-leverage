import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

// Isolates whether the second-deployIdleVault-after-a-cycle revert (PackedUint128Math__SubUnderflow)
// is actually fixed, independent of the separate METRO-minting-permission issue — so first
// undo the local mint-flag override back to the real (false) state.
//   npx hardhat run scripts/test-dlmm-second-rebalance.ts --network localhost --config hardhat.config.fork-ui.ts

const METRO_MASTERCHEF = ethers.getAddress("0x1a5ded6adcfc64acede86151b1f142088c6e03da");

async function main() {
  const dlmmCfg = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "fork-ui", "dlmm-config.json"), "utf8"));
  const [deployer] = await ethers.getSigners();

  const mcIface = new ethers.Interface([
    "function getMintMetroFlag() view returns (bool)",
    "function setMintMetro(bool) external",
    "function owner() view returns (address)",
  ]);
  const mc = new ethers.Contract(METRO_MASTERCHEF, mcIface, ethers.provider);
  if (await mc.getMintMetroFlag()) {
    const mcOwner = await mc.owner();
    await ethers.provider.send("hardhat_impersonateAccount", [mcOwner]);
    await ethers.provider.send("hardhat_setBalance", [mcOwner, "0x8ac7230489e80000"]);
    const ownerSigner = await ethers.getSigner(mcOwner);
    await (await mc.connect(ownerSigner).setMintMetro(false)).wait();
    await ethers.provider.send("hardhat_stopImpersonatingAccount", [mcOwner]);
    console.log("reverted getMintMetroFlag() back to:", await mc.getMintMetroFlag());
  }

  const factory = await ethers.getContractAt("StratusDLMMVaultFactory", dlmmCfg.factory, deployer);
  const vault = await ethers.getContractAt("StratusDLMMVault", dlmmCfg.vault, deployer);

  console.log("binIds before:", (await vault.getBinIds()).join(","));
  console.log("--- calling factory.deployIdleVault(vault) a second time ---");
  const tx = await factory.deployIdleVault(dlmmCfg.vault);
  const receipt = await tx.wait();
  console.log("deployIdleVault() OK, gas used:", receipt!.gasUsed.toString());
  console.log("binIds after:", (await vault.getBinIds()).join(","));
  console.log("\nSECOND-REBALANCE FIX CONFIRMED");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
