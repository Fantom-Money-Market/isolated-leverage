import { ethers } from "hardhat";
// Re-forks the local node from Sonic mainnet, discarding all local state.
//   npx hardhat run scripts/fork-reset.ts --network localhost --config hardhat.config.fork-ui.ts
async function main() {
  const url = process.env.SONIC_RPC_URL || "https://rpc.soniclabs.com";
  await ethers.provider.send("hardhat_reset", [{ forking: { jsonRpcUrl: url } }]);
  const bn = await ethers.provider.getBlockNumber();
  console.log("fork reset — head block", bn);
}
main().catch((e) => { console.error(e); process.exit(1); });
