// Reproduces the gem-generation Fuji deployment from this repository's sources and checks it against the chain.
//
//   node scripts/verify-fuji-gem-bytecode.mjs            compare compiled code with Avalanche Fuji
//   node scripts/verify-fuji-gem-bytecode.mjs --write    also write explorer verification inputs to verification/gem/
//
// For every contract in deployments/avalanche-fuji-v6-gem-prototype.json it checks that
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
  compilePactGemGenerationArtifact,
} from './pact-settlement-v6-artifact.mjs';

const RPC_URL = process.env.FUJI_RPC_URL ?? 'https://api.avax-test.network/ext/bc/C/rpc';
const manifest = JSON.parse(readFileSync(new URL('../deployments/avalanche-fuji-v6-gem-prototype.json', import.meta.url), 'utf8'));

// Creation transactions of the seven gem-generation contracts (one deployer, nonces 0 to 6).
const CONTRACTS = [
  { key: 'stakeToken', name: 'PactGemV6', file: 'contracts/src/PactGemV6.sol', artifact: 'gem',
    address: manifest.stakeToken, creationTx: '0x2ff39c09c56640fa15059a2b7946afa2768adb090291b7a02e5c4dfec889faf7' },
  { key: 'vault', name: 'PactGemVaultV6', file: 'contracts/src/PactGemVaultV6.sol', artifact: 'vault',
    address: manifest.vault, creationTx: '0x11c29e7f6ab9ba0ea9a3ef58f9ff0e4f066a2f751844ea4a3305f3702d0daab9' },
  { key: 'registry', name: 'PactGemRegistryV6', file: 'contracts/src/PactGemRegistryV6.sol', artifact: 'registry',
    address: manifest.registry, creationTx: '0xd9c22b183a5d8297579021e2aaef0aacfd1eb3770253064fe5554548f4b391d3' },
  { key: 'walkingModule', name: 'PactSettlementModuleV6', file: 'contracts/src/PactSettlementModuleV6.sol',
    artifact: 'module', address: manifest.settlementModules.walking,
    creationTx: '0x945b9a9ff118856aaf81ecb692491f406f03d116cba3448eb0cb68d802c18097' },
  { key: 'workingModule', name: 'PactSettlementModuleV6', file: 'contracts/src/PactSettlementModuleV6.sol',
    artifact: 'module', address: manifest.settlementModules.working,
    creationTx: '0xd83d0b2b50aaa5cbf78e6633860ca0085533091cb37cb996a41b68c6f83db1d8' },
  { key: 'proofModule', name: 'PactSettlementModuleV6', file: 'contracts/src/PactSettlementModuleV6.sol',
    artifact: 'module', address: manifest.settlementModules.proof,
    creationTx: '0x3ccfed628deacbbb861950c5614b3c92706b6bb669fa7680f0ffe385184ef84d' },
  { key: 'catCards', name: 'PactCatCardsV6', file: 'contracts/src/PactCatCardsV6.sol', artifact: 'cards',
    address: manifest.catCards, creationTx: '0x2268f5a2de172a902bb41fdaedff6625abfabbdfc183b3b6a717b2e880adc880' },
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
const compiled = compilePactGemGenerationArtifact();
if (compiled.sourceSha256 !== manifest.sourceSha256) {
  throw new Error(`source digest ${compiled.sourceSha256} does not match the manifest ${manifest.sourceSha256}`);
}
console.log(`sources: sha256 ${compiled.sourceSha256} matches the gem deployment manifest`);

let failures = 0;
const outputs = [];
for (const contract of CONTRACTS) {
  const artifact = compiled[contract.artifact];
  const { address, runtimeCodeHash } = contract.address;
  const onChain = await rpc('eth_getCode', [address, 'latest']);
  const runtimeMatches = maskImmutables(onChain, artifact.immutableReferences)
    === maskImmutables(artifact.deployedBytecode, artifact.immutableReferences);
  const codeHashMatches = keccak256(onChain) === runtimeCodeHash;

  const tx = await rpc('eth_getTransactionByHash', [contract.creationTx]);
  const receipt = await rpc('eth_getTransactionReceipt', [contract.creationTx]);
  const creation = artifact.bytecode.toLowerCase();
  const creationMatches = tx.input.toLowerCase().startsWith(creation)
    && receipt.contractAddress?.toLowerCase() === address.toLowerCase();
  const constructorArgs = tx.input.slice(creation.length);

  const ok = runtimeMatches && codeHashMatches && creationMatches;
  if (!ok) failures += 1;
  console.log(`${ok ? 'MATCH   ' : 'MISMATCH'} ${contract.key.padEnd(14)} ${address} `
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
  mkdirSync(new URL('../verification/gem/', import.meta.url), { recursive: true });
  writeFileSync(new URL('../verification/gem/standard-input.json', import.meta.url), `${JSON.stringify(input, null, 2)}\n`);
  writeFileSync(new URL('../verification/gem/contracts.json', import.meta.url), `${JSON.stringify(outputs.map(
    ({ key, name, file, address, creationTx, constructorArgs }) => ({
      key, contractName: `${file}:${name}`, address, creationTx, constructorArgs,
    })), null, 2)}\n`);
  console.log('wrote verification/gem/standard-input.json and verification/gem/contracts.json');
}

if (failures) {
  console.error(`${failures} contract(s) did not match`);
  process.exitCode = 1;
}
