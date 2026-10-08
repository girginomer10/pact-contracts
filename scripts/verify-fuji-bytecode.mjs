// Reproduces the Fuji deployment from this repository's sources and checks it against the chain.
//
//   node scripts/verify-fuji-bytecode.mjs            compare compiled code with Avalanche Fuji
//   node scripts/verify-fuji-bytecode.mjs --write    also write explorer verification inputs to verification/
//
// For every contract in deployments/avalanche-fuji-v6-prototype.json it checks that
//   1. the on-chain runtime code equals the compiled runtime code, byte for byte, once the
//      constructor-set immutables are masked (the CBOR metadata hash is compared too, so the
//      sources and compiler settings must match exactly), and
//   2. the creation transaction starts with the compiled creation code; the remainder is the
//      ABI-encoded constructor arguments.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { keccak256 } from 'viem';
import {
  PACT_SETTLEMENT_V6_EVM_VERSION,
  PACT_SETTLEMENT_V6_OPTIMIZER_RUNS,
  compilePactSettlementV6Artifact,
} from './pact-settlement-v6-artifact.mjs';

const RPC_URL = process.env.FUJI_RPC_URL ?? 'https://api.avax-test.network/ext/bc/C/rpc';
const manifest = JSON.parse(readFileSync(new URL('../deployments/avalanche-fuji-v6-prototype.json', import.meta.url), 'utf8'));

// Creation transactions of the four V6 contracts (one deployer, consecutive nonces).
const CONTRACTS = [
  { key: 'vault', name: 'PactVaultV6', file: 'contracts/src/PactVaultV6.sol', artifact: 'vault',
    creationTx: '0x189f17cd5c7443c44712c9d2a6cbdbd9351a29107a2f353dc18c0441f70be5ae' },
  { key: 'registry', name: 'PactRegistryV6', file: 'contracts/src/PactRegistryV6.sol', artifact: 'registry',
    creationTx: '0x7a5f3b948d6321bac4e2b4e79d8b679c13cfe3c893977f0cb37d0ab0ee9cbd6f' },
  { key: 'settlementModule', name: 'PactSettlementModuleV6', file: 'contracts/src/PactSettlementModuleV6.sol',
    artifact: 'module', creationTx: '0x9c27eb48a406bb60ef38967e3b8c6e7ceb35671006a0671c5fc1f2b2c2ceea0a' },
  { key: 'workingSettlementModule', name: 'PactSettlementModuleV6', file: 'contracts/src/PactSettlementModuleV6.sol',
    artifact: 'module', creationTx: '0x2f42214badc448da2d455306c08219f2251456f674dbbf019be33232333288cd' },
];

async function rpc(method, params) {
  const response = await fetch(RPC_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  });
  const body = await response.json();
  if (body.error) throw new Error(`${method}: ${body.error.message}`);
  return body.result;
}

function maskImmutables(code, references) {
  let hex = code.slice(2).toLowerCase();
  for (const ranges of Object.values(references)) {
    for (const { start, length } of ranges) {
      hex = hex.slice(0, start * 2) + '00'.repeat(length) + hex.slice((start + length) * 2);
    }
  }
  return hex;
}

const write = process.argv.includes('--write');
const compiled = compilePactSettlementV6Artifact();
if (compiled.sourceSha256 !== manifest.sourceSha256) {
  throw new Error(`source digest ${compiled.sourceSha256} does not match the manifest ${manifest.sourceSha256}`);
}
console.log(`sources: sha256 ${compiled.sourceSha256} matches the deployment manifest`);

let failures = 0;
const outputs = [];
for (const contract of CONTRACTS) {
  const artifact = compiled[contract.artifact];
  const address = manifest[contract.key].address;
  const onChain = await rpc('eth_getCode', [address, 'latest']);
  const runtimeMatches = maskImmutables(onChain, artifact.immutableReferences)
    === maskImmutables(artifact.deployedBytecode, artifact.immutableReferences);
  const codeHashMatches = keccak256(onChain) === manifest[contract.key].runtimeCodeHash;

  const tx = await rpc('eth_getTransactionByHash', [contract.creationTx]);
  const receipt = await rpc('eth_getTransactionReceipt', [contract.creationTx]);
  const creation = artifact.bytecode.toLowerCase();
  const creationMatches = tx.input.toLowerCase().startsWith(creation)
    && receipt.contractAddress?.toLowerCase() === address.toLowerCase();
  const constructorArgs = tx.input.slice(creation.length);

  const ok = runtimeMatches && codeHashMatches && creationMatches;
  if (!ok) failures += 1;
  console.log(`${ok ? 'MATCH   ' : 'MISMATCH'} ${contract.key.padEnd(24)} ${address} `
    + `runtime=${runtimeMatches} codeHash=${codeHashMatches} creation=${creationMatches}`);
  outputs.push({ ...contract, address, constructorArgs });
}

if (write) {
  const input = {
    language: 'Solidity',
    sources: Object.fromEntries(Object.entries(compiled.sources).map(([name, content]) => [name, { content }])),
    settings: {
      evmVersion: PACT_SETTLEMENT_V6_EVM_VERSION,
      viaIR: true,
      optimizer: { enabled: true, runs: PACT_SETTLEMENT_V6_OPTIMIZER_RUNS },
      outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object', 'evm.deployedBytecode.object', 'metadata'] } },
    },
  };
  mkdirSync(new URL('../verification/', import.meta.url), { recursive: true });
  writeFileSync(new URL('../verification/standard-input.json', import.meta.url), `${JSON.stringify(input, null, 2)}\n`);
  writeFileSync(new URL('../verification/contracts.json', import.meta.url), `${JSON.stringify(outputs.map(
    ({ key, name, file, address, creationTx, constructorArgs }) => ({
      key, contractName: `${file}:${name}`, address, creationTx, constructorArgs,
    })), null, 2)}\n`);
  console.log('wrote verification/standard-input.json and verification/contracts.json');
}

if (failures) {
  console.error(`${failures} contract(s) did not match`);
  process.exitCode = 1;
}
