import { ethers } from "hardhat";

/**
 * Lower minSkewBps on an existing fork vault (factory owner only).
 *   npx hardhat run scripts/set-rebalance-skew.ts --network localhost --config hardhat.config.integration.ts
 */
const VAULT = process.env.VAULT_ADDR || "0xd559FEFB23283AFED6e1B720369DD55e7C80fFf9";
const MIN_SKEW_BPS = Number(process.env.MIN_SKEW_BPS || "6000");

async function main() {
  const [deployer] = await ethers.getSigners();
  const vault = await ethers.getContractAt("StratusShadowVault", VAULT);
  const factoryAddr = await vault.factory();
  const factory = await ethers.getContractAt("StratusShadowVaultFactory", factoryAddr);

  const owner = await factory.owner();
  if (owner.toLowerCase() !== deployer.address.toLowerCase()) {
    throw new Error(`deployer ${deployer.address} is not factory owner ${owner}`);
  }

  const [dev, bounty, reward, minSkew] = await Promise.all([
    vault.deviationCapBps(),
    vault.bountyBps(),
    vault.rewardBountyBps(),
    vault.minSkewBps(),
  ]);
  console.log("before:", {
    deviationCapBps: Number(dev),
    bountyBps: Number(bounty),
    rewardBountyBps: Number(reward),
    minSkewBps: Number(minSkew),
  });

  await (
    await factory.setVaultRebalanceParams(VAULT, dev, bounty, reward, MIN_SKEW_BPS)
  ).wait();

  const minSkewAfter = await vault.minSkewBps();
  console.log("after minSkewBps:", Number(minSkewAfter));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
