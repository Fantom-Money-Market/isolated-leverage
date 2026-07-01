import { ethers } from "hardhat";

// Run with the factory OWNER key (moves your seed funds):
//   PRIVATE_KEY=0x.. npx hardhat run scripts/create-vault.ts --network sonic --config hardhat.config.stratus.ts
// Point at the freshly redeployed factory: FACTORY=0x.. npx hardhat run ...
const FACTORY = process.env.FACTORY || "0xA1B617804E4Af18B0eE767B4A9C912B3EE277BCd";
const POOL = "0x324963c267C354c7660Ce8CA3F5f167E05649970";
const USDCe = "0x29219dd400f2Bf60E5a23d13Be72B486D4038894"; // pool token1 (6 dec)
const wS = "0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38";    // pool token0 (18 dec)

const TICK_SPACING = 50;
const UPWARD_BIAS = 100; // symmetric ranges around current tick
const PROTOCOL_FEE = 5;  // %

// Pool order: token0 = wS, token1 = USDC.e
const SEED0 = ethers.parseEther("1");        // 1 wS
const SEED1 = ethers.parseUnits("0.03", 6);  // 0.03 USDC.e

const ERC20 = [
  "function approve(address,uint256) returns (bool)",
  "function allowance(address,address) view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
];

async function main() {
  const pk = process.env.PRIVATE_KEY;
  if (!pk) throw new Error("Set PRIVATE_KEY (factory owner)");
  const signer = new ethers.Wallet(pk, ethers.provider);
  console.log("owner:", signer.address);

  const wsT = new ethers.Contract(wS, ERC20, signer);
  const usdcT = new ethers.Contract(USDCe, ERC20, signer);

  console.log("balances  wS:", (await wsT.balanceOf(signer.address)).toString(),
    " USDC.e:", (await usdcT.balanceOf(signer.address)).toString());

  await (await wsT.approve(FACTORY, SEED0)).wait();
  await (await usdcT.approve(FACTORY, SEED1)).wait();
  console.log("approved seeds");

  const factory = await ethers.getContractAt("StratusShadowVaultFactory", FACTORY, signer);
  // tokenA/tokenB order is irrelevant (resolved via the voter); seed0/seed1 are pool order.
  const tx = await factory.createVault(USDCe, wS, TICK_SPACING, UPWARD_BIAS, PROTOCOL_FEE, SEED0, SEED1);
  const rcpt = await tx.wait();
  console.log("createVault tx:", rcpt?.hash);

  const vault = await factory.vaultForPool(POOL);
  const v = await ethers.getContractAt("StratusShadowVault", vault);
  console.log("vault       :", vault);
  console.log("totalSupply :", (await v.totalSupply()).toString(), "(== 1000 means seed locked)");
  const [t0, t1] = await v.getTotalAmounts();
  console.log("totalAmounts:", t0.toString(), t1.toString(), "(>0 means positions minted)");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
