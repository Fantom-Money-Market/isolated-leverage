import { ethers } from "hardhat";

// Thick CL factory on Sonic — resolves pools via getPool(tokenA, tokenB, int24 tickSpacing).
const CL_FACTORY = "0x7Ca1dCCFB4f49564b8f13E18a67747fd428F1C40";

// Run with the intended owner key (fund-moving — yours to send):
//   PRIVATE_KEY=0x.. npx hardhat run scripts/deploy-thick-factory.ts --network sonic --config hardhat.config.stratus.ts
async function main() {
  const pk = process.env.PRIVATE_KEY;
  if (!pk) throw new Error("Set PRIVATE_KEY");
  const signer = new ethers.Wallet(pk, ethers.provider);

  const tm = await (await ethers.getContractFactory("TickMath", signer)).deploy();
  const la = await (await ethers.getContractFactory("LiquidityAmounts", signer)).deploy();
  const ph = await (await ethers.getContractFactory("UniswapV3PriceHelper", { libraries: { TickMath: await tm.getAddress() }, signer })).deploy();
  await tm.waitForDeployment();
  const F = await ethers.getContractFactory("StratusThickVaultFactory", { libraries: { TickMath: await tm.getAddress(), LiquidityAmounts: await la.getAddress(), UniswapV3PriceHelper: await ph.getAddress() }, signer });
  const f = await F.deploy(CL_FACTORY);
  await f.waitForDeployment();
  const addr = await f.getAddress();

  console.log("thick factory:", addr);
  console.log("vaultDeployer:", await f.vaultDeployer());
  console.log("owner        :", await f.owner());
  console.log("clFactory    :", await f.clFactory());
  console.log(
    "\nNext: FACTORY=" + addr + " PRIVATE_KEY=0x.. npx hardhat run scripts/create-thick-vault.ts --network sonic --config hardhat.config.stratus.ts"
  );
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
