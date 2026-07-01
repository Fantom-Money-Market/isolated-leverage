import { ethers } from "hardhat";

const ADDR = process.env.ADDR || "0x92488BDC99969796068391C11E3841CAA77f738e";
const POOL = "0x324963c267C354c7660Ce8CA3F5f167E05649970"; // USDC.e/wS

async function inspectVault(addr: string) {
  const v = await ethers.getContractAt("StratusShadowVault", addr);
  console.log("== VAULT ==", addr);
  console.log("factory     :", await v.factory());
  console.log("pool        :", await v.pool());
  console.log("gauge       :", await v.gauge());
  console.log("totalSupply :", (await v.totalSupply()).toString(), "(1000 => seed locked)");
  const [t0, t1] = await v.getTotalAmounts();
  console.log("totalAmounts:", t0.toString(), t1.toString(), "(>0 => positions minted)");
  const [s0, s1] = await v.getTotalAmountsSafe();
  console.log("safeAmounts :", s0.toString(), s1.toString());
}

async function main() {
  const code = await ethers.provider.getCode(ADDR);
  console.log("address     :", ADDR);
  console.log("code bytes  :", (code.length - 2) / 2);

  // Is it a factory?
  try {
    const f = await ethers.getContractAt("StratusShadowVaultFactory", ADDR);
    const owner = await f.owner();
    const voter = await f.voter();
    const deployer = await f.vaultDeployer();
    const count = await f.vaultCount();
    console.log("== FACTORY ==");
    console.log("owner       :", owner);
    console.log("voter       :", voter);
    console.log("deployer    :", deployer);
    console.log("vaultCount  :", count.toString());
    if (Number(count) > 0) {
      const vaultAddr = await f.vaultForPool(POOL);
      console.log("vault(USDC.e/wS):", vaultAddr);
      if (vaultAddr !== ethers.ZeroAddress) await inspectVault(vaultAddr);
    } else {
      console.log("No vaults created yet — run create-vault next.");
    }
    return;
  } catch {
    // not a factory; try vault
  }

  await inspectVault(ADDR);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
