import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

// Proves the fail-closed DLMM price RECOVERS: a trade writes a fresh oracle sample, after
// which the vault can serve a real TWAP again. Without this, a fail-closed market on a
// quiet pair could be indistinguishable from a permanently bricked one.

const ERC20 = [
  "function transfer(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
];
const LB_PAIR_ABI = [
  "function swap(bool swapForY, address to) returns (bytes32)",
  "function getTokenX() view returns (address)",
];
const WS_POOL = "0x324963c267C354c7660Ce8CA3F5f167E05649970";

async function main() {
  const cfg = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "fork-ui", "dlmm-config.json"), "utf8"));
  const [deployer] = await ethers.getSigners();
  const vault = await ethers.getContractAt("StratusDLMMVault", cfg.vault);

  console.log("before trade — isSafePriceAvailable():", await vault.isSafePriceAvailable());

  // Fund a small wS amount from the Shadow pool (never from the LB pair itself) and swap
  // wS -> USSD directly on the pair, which is what writes an oracle sample.
  const amt = ethers.parseEther("1");
  await ethers.provider.send("hardhat_impersonateAccount", [WS_POOL]);
  await ethers.provider.send("hardhat_setBalance", [WS_POOL, "0x21e19e0c9bab2400000"]);
  const whale = await ethers.getSigner(WS_POOL);
  await (await new ethers.Contract(cfg.tokens.wS.address, ERC20, whale).transfer(cfg.pair, amt)).wait();
  await ethers.provider.send("hardhat_stopImpersonatingAccount", [WS_POOL]);

  const pair = new ethers.Contract(cfg.pair, LB_PAIR_ABI, deployer);
  const tokenX: string = await pair.getTokenX();
  const swapForY = tokenX.toLowerCase() === cfg.tokens.wS.address.toLowerCase();
  await (await pair.swap(swapForY, deployer.address)).wait();
  console.log("executed a swap on the pair (writes an oracle sample)");

  // Let a little time pass so the sample is real but still inside the freshness bound.
  await ethers.provider.send("evm_increaseTime", [60]);
  await ethers.provider.send("evm_mine", []);

  const ok = await vault.isSafePriceAvailable();
  console.log("after trade  — isSafePriceAvailable():", ok);
  if (!ok) throw new Error("price did not recover after a trade — market would be permanently paused");

  const price = await vault.twapPrice();
  console.log("twapPrice():", ethers.formatEther(price));
  const value = await vault.getTotalValueSafe();
  console.log("getTotalValueSafe():", ethers.formatEther(value));
  console.log("\nORACLE RECOVERY CONFIRMED — fail-closed is temporary, not terminal");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
