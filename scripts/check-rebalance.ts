import { ethers } from "hardhat";

const ADDR = process.env.ADDR || "0x096245c02268dceC8Ae96331EEc43eAF6cD1e8EA";

async function main() {
  const signer = ethers.Wallet.createRandom().connect(ethers.provider);
  const v = await ethers.getContractAt("StratusShadowVault", ADDR, signer);

  console.log("caller      :", signer.address);
  console.log("factory     :", await v.factory());

  try {
    const [need0, need1, surplus0, surplus1] = await v.previewRebalance();
    console.log("previewRebalance:", { need0: need0.toString(), need1: need1.toString(), surplus0: surplus0.toString(), surplus1: surplus1.toString() });
  } catch (e: any) {
    console.log("previewRebalance REVERTED:", e.shortMessage || e.message, "data:", e.data || e.info?.error?.data || "");
  }

  // raw eth_call to get unmangled revert data
  try {
    const data = v.interface.encodeFunctionData("previewRebalance");
    const raw = await ethers.provider.call({ to: ADDR, data });
    console.log("raw call succeeded:", raw);
  } catch (e: any) {
    console.log("raw eth_call error:", JSON.stringify(e.info?.error || e.error || e, null, 2).slice(0, 1000));
  }

  console.log("rangeLower:", (await v.rangeLower(0)).toString(), (await v.rangeLower(1)).toString(), (await v.rangeLower(2)).toString());
  console.log("rangeUpper:", (await v.rangeUpper(0)).toString(), (await v.rangeUpper(1)).toString(), (await v.rangeUpper(2)).toString());
  console.log("tickSpacing:", (await v.tickSpacing()).toString());

  try {
    const [amountOut, amountIn] = await v.previewRebalanceSwap();
    console.log("previewRebalanceSwap:", { amountOut: amountOut.toString(), amountIn: amountIn.toString() });
  } catch (e: any) {
    console.log("previewRebalanceSwap REVERTED:", e.shortMessage || e.message);
  }

  try {
    const result = await v.rebalanceViaSwap.staticCall(ethers.MaxUint256, 0);
    console.log("rebalanceViaSwap staticCall OK:", result);
  } catch (e: any) {
    console.log("rebalanceViaSwap staticCall REVERTED:", e.shortMessage || e.message, e.data || "");
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
