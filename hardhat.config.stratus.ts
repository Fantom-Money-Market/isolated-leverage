// Scoped Hardhat config for the Stratus-ALM v2 vault stack.
// - Compiles ONLY contracts/Stratus-ALM (+ cross-folder deps via imports),
//   avoiding the overarching lending/oracle layer.
// - Forks Sonic so the new vault can be exercised end-to-end against live Shadow.
// Run: npx hardhat test --config hardhat.config.stratus.ts
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
      forking: {
        url: SONIC_RPC,
        blockNumber: FORK_BLOCK,
      },
      // Sonic (146) isn't in EDR's built-in hardfork history — declare it so the
      // forked node knows which EVM rules to execute the historical block under.
      chains: {
        146: {
          hardforkHistory: {
            cancun: 0,
          },
        },
      },
    },
    sonic: {
      url: process.env.SONIC_RPC_URL || "https://sonic.api.pocket.network",
      chainId: 146,
    },
  },
  paths: {
    sources: "./contracts/Stratus-ALM",
    tests: "./test/stratus",
    cache: "./cache-stratus",
    artifacts: "./artifacts-stratus",
  },
};

export default config;
