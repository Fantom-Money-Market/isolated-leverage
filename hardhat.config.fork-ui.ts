// Throwaway config for the local interactive fork-ui playground ONLY.
// Same as hardhat.config.integration.ts but reports a distinct chainId (31337, the
// standard "Hardhat Network / Localhost 8545" id most wallets already recognize) so it
// never collides with a wallet's real built-in Sonic (146) network entry.
//   npx hardhat node --config hardhat.config.fork-ui.ts
import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";

const SONIC_RPC = process.env.SONIC_RPC_URL || "https://rpc.soniclabs.com";

const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      { version: "0.8.27", settings: { optimizer: { enabled: true, runs: 200 }, viaIR: true } },
      { version: "0.7.6", settings: { optimizer: { enabled: true, runs: 200 }, viaIR: true } },
    ],
  },
  networks: {
    hardhat: {
      chainId: 31337,
      hardfork: "cancun",
      forking: { url: SONIC_RPC },
      // The underlying fork state is still real Sonic (146) history; only the
      // JSON-RPC-reported chainId changes, which is all a wallet keys off of.
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
