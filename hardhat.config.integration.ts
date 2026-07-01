// Integration config: compiles BOTH layers (Tarot lending + Stratus-ALM vaults) together
// and forks Sonic, so cross-layer exploit tests can deploy a real ALPT, stand up a Tarot
// lending pool on it, and attack the combination.
//   npx hardhat test --config hardhat.config.integration.ts
import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";

const SONIC_RPC = process.env.SONIC_RPC_URL || "https://rpc.soniclabs.com";
// Pinned for reproducible fork tests (no run-to-run drift from forking `latest`).
// Override with FORK_BLOCK=<n> to test against a different point in history.
const FORK_BLOCK = Number(process.env.FORK_BLOCK) || 75094000;

const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      { version: "0.8.27", settings: { optimizer: { enabled: true, runs: 200 }, viaIR: true } },
      { version: "0.7.6", settings: { optimizer: { enabled: true, runs: 200 }, viaIR: true } },
    ],
  },
  networks: {
    hardhat: {
      chainId: 146,
      hardfork: "cancun",
      forking: { url: SONIC_RPC, blockNumber: FORK_BLOCK },
      chains: { 146: { hardforkHistory: { cancun: 0 } } },
    },
  },
  paths: {
    sources: "./contracts",
    tests: "./test/integration",
    cache: "./cache-integration",
    artifacts: "./artifacts-integration",
  },
};

export default config;
