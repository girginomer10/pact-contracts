import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import solc from 'solc';

export const PACT_SETTLEMENT_V6_EVM_VERSION = 'cancun';
export const PACT_SETTLEMENT_V6_OPTIMIZER_RUNS = 1;
export const PACT_SETTLEMENT_V6_COMPILER_VERSION = solc.version();
export const PACT_SETTLEMENT_V6_RUNTIME_LIMIT = 24_576;

const SOURCE_NAMES = [
  'PactSettlementModuleV6.sol',
  'PactRegistryV6.sol',
  'PactVaultV6.sol',
  'interfaces/IPactSettlementV6.sol',
  'interfaces/IPactSettlementRegistryV6.sol',
  'interfaces/IPactSettlementSinkV6.sol',
  'interfaces/IPactSettlementModuleV6.sol',
  'interfaces/IPactVaultV6.sol',
  'interfaces/IPactERC20V6.sol',
  'libraries/PactAllocationsV6.sol',
  'libraries/PactTimeoutV6.sol',
];

// Every contract in the V6 system must keep its required surface; a rename or a silently
// shrunken artifact must fail the compile gate instead of passing the size check alone.
const REQUIRED_FUNCTIONS = {
  PactSettlementModuleV6: ['settleV6', 'refundTimedOutV6', 'claim', 'validateAllocations',
    'settlementWindowClosesAt', 'settlementDigest', 'domainSeparator'],
  PactRegistryV6: ['createWalkingPactV6', 'createRollingWalkingPactV6', 'createWorkingPactV6',
    'activatePactV6', 'joinWalkingPactV6', 'joinWorkingPactV6', 'leaveWalkingPactV6',
    'leaveWorkingPactV6', 'exitWalkingPactV6', 'exitWorkingPactV6', 'rotateInviteSigner',
    'blockRecipient', 'unblockRecipient', 'cancelWalkingPactV6', 'cancelWorkingPactV6',
    'settleWalkingPactV6', 'settleWorkingPactV6', 'refundWalkingPactV6', 'refundWorkingPactV6',
    'approveRolloverV6', 'rejectRolloverV6', 'releaseRolloverV6', 'activateWithRolloverV6',
    'rolloverOf', 'pactSettlementKind', 'pactSettlementTerms', 'settlementParticipantAt',
    'isActiveParticipant', 'invitePermitDigest', 'generationId'],
  PactVaultV6: ['deposit', 'release', 'exit', 'payout', 'refundPayout', 'claim', 'claimFor',
    'lockRollover', 'moveRolloverReserve', 'releaseRolloverReserve', 'pool', 'unallocatedPool',
    'rolloverReserve', 'claimable', 'paidOut', 'contribution', 'rolloverPrincipal', 'principalOf',
    'rolloverState', 'stakeToken', 'registry', 'module', 'workingModule'],
};

function contractArtifact(output, file, name) {
  const contract = output.contracts[`contracts/src/${file}`]?.[name];
  if (!contract?.evm?.bytecode?.object || !contract?.evm?.deployedBytecode?.object) {
    throw new Error(`${name} compilation produced empty bytecode.`);
  }
  return {
    abi: contract.abi,
    bytecode: `0x${contract.evm.bytecode.object}`,
    deployedBytecode: `0x${contract.evm.deployedBytecode.object}`,
    immutableReferences: contract.evm.deployedBytecode.immutableReferences ?? {},
    metadata: contract.metadata,
  };
}

export function compilePactSettlementV6Artifact() {
  const sources = Object.fromEntries(SOURCE_NAMES.map((name) => [
    `contracts/src/${name}`,
    { content: readFileSync(new URL(`../contracts/src/${name}`, import.meta.url), 'utf8') },
  ]));
  const canonicalSource = SOURCE_NAMES.map((name) =>
    `// contracts/src/${name}\n${sources[`contracts/src/${name}`].content}`).join('\n');
  const sourceSha256 = createHash('sha256').update(canonicalSource).digest('hex');
  const input = {
    language: 'Solidity',
    sources,
    settings: {
      evmVersion: PACT_SETTLEMENT_V6_EVM_VERSION,
      viaIR: true,
      optimizer: { enabled: true, runs: PACT_SETTLEMENT_V6_OPTIMIZER_RUNS },
      outputSelection: { '*': { '*': [
        'abi', 'evm.bytecode.object', 'evm.deployedBytecode.object',
        'evm.deployedBytecode.immutableReferences', 'metadata',
      ] } },
    },
  };
  const output = JSON.parse(solc.compile(JSON.stringify(input)));
  const errors = (output.errors ?? []).filter(({ severity }) => severity === 'error');
  if (errors.length) throw new Error(errors.map(({ formattedMessage }) => formattedMessage).join('\n'));
  return {
    sourceSha256,
    sources: Object.freeze(Object.fromEntries(Object.entries(sources).map(([name, value]) => [name, value.content]))),
    module: contractArtifact(output, 'PactSettlementModuleV6.sol', 'PactSettlementModuleV6'),
    registry: contractArtifact(output, 'PactRegistryV6.sol', 'PactRegistryV6'),
    vault: contractArtifact(output, 'PactVaultV6.sol', 'PactVaultV6'),
  };
}

function runtimeSize(artifact) {
  return (artifact.deployedBytecode.length - 2) / 2;
}

export function settlementV6RuntimeSize(compiled = compilePactSettlementV6Artifact()) {
  return runtimeSize(compiled.module);
}

/** Runtime sizes of every deployable contract in the V6 system. */
export function settlementV6RuntimeSizes(compiled = compilePactSettlementV6Artifact()) {
  return {
    PactSettlementModuleV6: runtimeSize(compiled.module),
    PactRegistryV6: runtimeSize(compiled.registry),
    PactVaultV6: runtimeSize(compiled.vault),
  };
}

/** Fails closed before EIP-170 on every V6 contract and on a missing settlement surface.
 * Shared by the compile gate and the runtime suite so a silently shrunken/renamed module
 * cannot pass either step. Returns the module runtime size for backward compatibility. */
export function assertPactSettlementV6Deployable(compiled = compilePactSettlementV6Artifact()) {
  const sizes = settlementV6RuntimeSizes(compiled);
  for (const [name, size] of Object.entries(sizes)) {
    assert.ok(size <= PACT_SETTLEMENT_V6_RUNTIME_LIMIT,
      `${name} runtime ${size} bytes exceeds EIP-170`);
  }
  const artifacts = {
    PactSettlementModuleV6: compiled.module,
    PactRegistryV6: compiled.registry,
    PactVaultV6: compiled.vault,
  };
  for (const [contractName, required] of Object.entries(REQUIRED_FUNCTIONS)) {
    const functions = new Set(artifacts[contractName].abi.filter((entry) => entry.type === 'function')
      .map((entry) => entry.name));
    for (const name of required) {
      assert.ok(functions.has(name), `${contractName}.${name} missing from ABI`);
    }
  }
  return sizes.PactSettlementModuleV6;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const compiled = compilePactSettlementV6Artifact();
  assertPactSettlementV6Deployable(compiled);
  const sizes = settlementV6RuntimeSizes(compiled);
  const summary = Object.entries(sizes).map(([name, size]) =>
    `${name} ${size} bytes (margin ${PACT_SETTLEMENT_V6_RUNTIME_LIMIT - size})`).join(', ');
  console.log(`Pact Settlement V6 system compiled for ${PACT_SETTLEMENT_V6_EVM_VERSION} ` +
    `(solc ${PACT_SETTLEMENT_V6_COMPILER_VERSION}): ${summary}, source ${compiled.sourceSha256.slice(0, 12)}.`);
}
