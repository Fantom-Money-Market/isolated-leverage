import { ethers } from "hardhat";

// Create + seed a Thick vault. Fund-moving (pulls your seed tokens) — yours to send.
//   FACTORY=0x.. PRIVATE_KEY=0x.. npx hardhat run scripts/create-thick-vault.ts --network sonic --config hardhat.config.stratus.ts
const FACTORY = process.env.FACTORY || "";

// wS/USDC.e ts=8 Thick pool (deep, card=1000). token0=wS(18), token1=USDC.e(6).
const wS = "0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38";
const USDCe = "0x29219dd400f2Bf60E5a23d13Be72B486D4038894";
const TICK_SPACING = 8;

const UPWARD_BIAS = 100; // symmetric ranges
const PROTOCOL_FEE = 5; // % of realized fees to factory
const SEED_WS = ethers.parseEther("1"); // seed0 (token0)
const SEED_USDC = ethers.parseUnits("0.03", 6); // seed1 (token1)

const ERC20 = ["function approve(address,uint256) returns (bool)", "function balanceOf(address) view returns (uint256)"];

async function main() {
  if (!FACTORY) throw new Error("Set FACTORY");
  const pk = process.env.PRIVATE_KEY;
  if (!pk) throw new Error("Set PRIVATE_KEY");
  const signer = new ethers.Wallet(pk, ethers.provider);

  const factory = await ethers.getContractAt("StratusThickVaultFactory", FACTORY, signer);

  // approve the factory to pull the seed
  await (await new ethers.Contract(wS, ERC20, signer).approve(FACTORY, SEED_WS)).wait();
  await (await new ethers.Contract(USDCe, ERC20, signer).approve(FACTORY, SEED_USDC)).wait();

  const tx = await factory.createVault(USDCe, wS, TICK_SPACING, UPWARD_BIAS, PROTOCOL_FEE, SEED_WS, SEED_USDC);
  const rcpt = await tx.wait();
  console.log("createVault tx:", rcpt?.hash);

  const pool = await new ethers.Contract(
    FACTORY,
    ["function allVaults(uint256) view returns (address)"],
    signer
  );
  const vaultAddr = await factory.allVaults(0);
  console.log("vault         :", vaultAddr);

  const v = await ethers.getContractAt("StratusThickVault", vaultAddr, signer);
  console.log("name          :", await v.name());
  console.log("symbol        :", await v.symbol());
  console.log("decimals      :", (await v.decimals()).toString());
  console.log("pricePerShare :", (await v.pricePerShareSafe()).toString());
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
