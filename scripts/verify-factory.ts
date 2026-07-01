import { ethers } from "hardhat";

// Live StratusShadowVaultFactory on Sonic.
const FACTORY = "0xA1B617804E4Af18B0eE767B4A9C912B3EE277BCd";

async function main() {
  const net = await ethers.provider.getNetwork();
  console.log("chainId   :", net.chainId.toString());

  const code = await ethers.provider.getCode(FACTORY);
  if (code === "0x") throw new Error("No contract at FACTORY address on this RPC");

  const factory = await ethers.getContractAt("StratusShadowVaultFactory", FACTORY);
  const [owner, voter, deployer, count] = await Promise.all([
    factory.owner(),
    factory.voter(),
    factory.vaultDeployer(),
    factory.vaultCount(),
  ]);

  console.log("factory   :", FACTORY);
  console.log("owner     :", owner);
  console.log("voter     :", voter);
  console.log("deployer  :", deployer);
  console.log("vaultCount:", count.toString());

  const [voterCode, deployerCode] = await Promise.all([
    ethers.provider.getCode(voter),
    ethers.provider.getCode(deployer),
  ]);
  console.log("voter is contract   :", voterCode !== "0x");
  console.log("deployer is contract:", deployerCode !== "0x");

  // If any vaults exist, list the first few.
  const n = Number(count);
  for (let i = 0; i < Math.min(n, 5); i++) {
    console.log(`vault[${i}]  :`, await factory.allVaults(i));
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
