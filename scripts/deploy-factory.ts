import { ethers } from "hardhat";

// Live Shadow voter + SHADOW reward token on Sonic.
const VOTER = "0x9F59398D0a397b2EEB8a6123a6c7295cB0b0062D";
const SHADOW = "0x3333b97138D4b086720b5aE8A7844b1345a33333";

// Run with the intended owner key:
//   PRIVATE_KEY=0x.. npx hardhat run scripts/deploy-factory.ts --network sonic --config hardhat.config.stratus.ts
async function main() {
  const pk = process.env.PRIVATE_KEY;
  if (!pk) throw new Error("Set PRIVATE_KEY");
  const signer = new ethers.Wallet(pk, ethers.provider);

  const tm = await (await ethers.getContractFactory("TickMath", signer)).deploy();
  const la = await (await ethers.getContractFactory("LiquidityAmounts", signer)).deploy();
  const ph = await (await ethers.getContractFactory("UniswapV3PriceHelper", { libraries: { TickMath: await tm.getAddress() }, signer })).deploy();
  await tm.waitForDeployment();
  const F = await ethers.getContractFactory("StratusShadowVaultFactory", { libraries: { TickMath: await tm.getAddress(), LiquidityAmounts: await la.getAddress(), UniswapV3PriceHelper: await ph.getAddress() }, signer });
  const f = await F.deploy(VOTER, SHADOW);
  await f.waitForDeployment();
  const addr = await f.getAddress();

  console.log("factory      :", addr);
  console.log("vaultDeployer:", await f.vaultDeployer());
  console.log("owner        :", await f.owner());
  console.log("voter        :", await f.voter());
  console.log("\nNext: FACTORY=" + addr + " PRIVATE_KEY=0x.. npx hardhat run scripts/create-vault.ts --network sonic --config hardhat.config.stratus.ts");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
