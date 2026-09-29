import hardhatNetworkHelpers from "@nomicfoundation/hardhat-network-helpers";
import hardhatNodeTestRunner from "@nomicfoundation/hardhat-node-test-runner";
import hardhatViem from "@nomicfoundation/hardhat-viem";
import { defineConfig } from "hardhat/config";

// Tests compile with solc-js through scripts/pact-settlement-v6-artifact.mjs, which holds the
// exact settings used for the Fuji deployment. Hardhat only provides the in-process network.
export default defineConfig({
  plugins: [hardhatViem, hardhatNodeTestRunner, hardhatNetworkHelpers],
  solidity: {
    version: "0.8.30",
    settings: {
      evmVersion: "cancun",
      viaIR: true,
      optimizer: {
        enabled: true,
        runs: 1,
      },
    },
  },
  paths: {
    artifacts: ".hardhat/artifacts",
    cache: ".hardhat/cache",
  },
});
