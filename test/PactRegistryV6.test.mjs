import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { describe, it } from 'node:test';
import hre from 'hardhat';
import solc from 'solc';
import {
  encodeAbiParameters,
  getContract,
  getContractAddress,
  hashDomain,
  hashTypedData,
  keccak256,
  parseEventLogs,
  toFunctionSelector,
  zeroAddress,
} from 'viem';
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts';
import {
  assertPactSettlementV6Deployable,
  compilePactSettlementV6Artifact,
  settlementV6RuntimeSizes,
} from '../scripts/pact-settlement-v6-artifact.mjs';

// Local EVM only. The V6 system is deliberately not deployed anywhere yet.
const compiled = compilePactSettlementV6Artifact();
const HOUR = 3_600n;
const DAY = 86_400n;
const ROLLOVER_WINDOW = 7n * DAY;
const REVIEW_WINDOW = DAY;
const SETTLEMENT_WINDOW = DAY;
const STAKE = 1_000_000n;
const TERMS = `0x${'11'.repeat(32)}`;
const RESULTS = `0x${'22'.repeat(32)}`;
const EVIDENCE = `0x${'33'.repeat(32)}`;
const ZERO_HASH = `0x${'00'.repeat(32)}`;
const INVITE_PERMIT_TYPES = {
  InvitePermit: [
    { name: 'pactId', type: 'uint256' },
    { name: 'termsHash', type: 'bytes32' },
    { name: 'recipient', type: 'address' },
    { name: 'inviteEpoch', type: 'uint256' },
    { name: 'deadline', type: 'uint40' },
    { name: 'nonce', type: 'bytes32' },
  ],
};
const AUTHORIZATION_TYPES = {
  SettlementAuthorization: [
    { name: 'pactId', type: 'uint256' },
    { name: 'termsHash', type: 'bytes32' },
    { name: 'resultsHash', type: 'bytes32' },
    { name: 'evidenceHash', type: 'bytes32' },
    { name: 'allocationsHash', type: 'bytes32' },
    { name: 'outcome', type: 'uint8' },
    { name: 'nonce', type: 'bytes32' },
    { name: 'deadline', type: 'uint40' },
    { name: 'registry', type: 'address' },
    { name: 'generationId', type: 'bytes32' },
  ],
};
const ALLOCATION_TUPLE = { type: 'tuple[]', components: [
  { name: 'recipient', type: 'address' }, { name: 'amount', type: 'uint256' }] };

const LOCAL_SOURCE_NAMES = [
  'contracts/test/MockERC20.sol',
  'contracts/test/NoReturnERC20.sol',
  'contracts/test/FeeOnTransferERC20.sol',
  'contracts/test/ReentrantERC20.sol',
  'contracts/test/MockVaultActorsV6.sol',
  'contracts/src/interfaces/IPactSettlementSinkV6.sol',
  'contracts/src/interfaces/IPactVaultV6.sol',
];
const localSources = Object.fromEntries(LOCAL_SOURCE_NAMES.map((name) => [name,
  { content: readFileSync(new URL(`../${name}`, import.meta.url), 'utf8') }]));
const localCompilation = JSON.parse(solc.compile(JSON.stringify({ language: 'Solidity', sources: localSources,
  settings: { evmVersion: 'cancun', optimizer: { enabled: true, runs: 1 },
    outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object'] } } } })));
assert.deepEqual((localCompilation.errors ?? []).filter(({ severity }) => severity === 'error'), []);
const localArtifacts = Object.fromEntries(Object.values(localCompilation.contracts).flatMap((contracts) =>
  Object.entries(contracts).map(([name, contract]) => [name,
    { abi: contract.abi, bytecode: `0x${contract.evm.bytecode.object}` }])));

const allocation = (recipient, amount) => ({ recipient, amount });
const allocationsHashOf = (allocations) =>
  keccak256(encodeAbiParameters([ALLOCATION_TUPLE], [allocations]));
const randomNonce = () => `0x${randomBytes(32).toString('hex')}`;
const asAccount = (wallet) => wallet.account ?? wallet;

function randomAccounts(count) {
  const accounts = [];
  const seen = new Set();
  while (accounts.length < count) {
    const account = privateKeyToAccount(generatePrivateKey());
    if (seen.has(account.address)) continue;
    seen.add(account.address);
    accounts.push(account);
  }
  return accounts;
}

async function send(client, transaction) {
  const receipt = await client.waitForTransactionReceipt({ hash: await transaction });
  assert.equal(receipt.status, 'success');
  return receipt;
}

async function deploy(client, wallet, item, args = []) {
  const receipt = await send(client, wallet.deployContract({ abi: item.abi, bytecode: item.bytecode, args,
    account: wallet.account }));
  assert.ok(receipt.contractAddress);
  return getContract({ address: receipt.contractAddress, abi: item.abi, client: { public: client, wallet } });
}

async function expectError(call, name) {
  await assert.rejects(call, (error) => {
    // Hardhat's viem adapter and the test can load distinct ESM instances.
    // Check the actual revert node and exact error/selector, never class identity.
    assert.equal(error.name, 'ContractFunctionExecutionError', String(error));
    assert.equal(typeof error.walk, 'function');
    const reverted = error.walk((candidate) => candidate.name === 'ContractFunctionRevertedError');
    assert.ok(reverted, 'expected an actual EVM revert in the cause chain');
    if (reverted?.data?.errorName) assert.equal(reverted.data.errorName, name, error.shortMessage);
    else assert.match(error.shortMessage, new RegExp(toFunctionSelector(`${name}()`), 'i'));
    return true;
  });
}

function event(abi, receipt, name) {
  const [parsed] = parseEventLogs({ abi, eventName: name, logs: receipt.logs });
  assert.ok(parsed, `${name} event missing from receipt`);
  return parsed.args;
}

const PACT_FIELDS = ['creator', 'termsHash', 'stakeAmount', 'joinDeadline', 'activationDeadline',
  'startsAt', 'endAt', 'duration', 'evidenceGrace', 'evidenceClosesAt', 'reviewClosesAt',
  'settlementClosesAt', 'capacity', 'domain', 'startMode', 'exitPenaltyBps', 'status'];

async function fixture({ tokenName = 'MockERC20', capacity = 4 } = {}) {
  const connection = await hre.network.create();
  const client = await connection.viem.getPublicClient();
  const [creator, bob, carol, dave, erin, outsider] = await connection.viem.getWalletClients();
  const walkingVerifier = privateKeyToAccount(generatePrivateKey());
  const workingVerifier = privateKeyToAccount(generatePrivateKey());
  const inviteSigner = privateKeyToAccount(generatePrivateKey());
  const tokenArtifact = localArtifacts[tokenName];
  const usdc = await deploy(client, creator, tokenArtifact);

  // The registry <-> vault <-> modules wiring is a CREATE-address cycle, so the addresses are
  // predicted before deployment and checked after. Order: vault, registry, walking, working.
  const startNonce = BigInt(await client.getTransactionCount({ address: creator.account.address }));
  const predicted = {
    vault: getContractAddress({ from: creator.account.address, nonce: startNonce }),
    registry: getContractAddress({ from: creator.account.address, nonce: startNonce + 1n }),
    walkingModule: getContractAddress({ from: creator.account.address, nonce: startNonce + 2n }),
    workingModule: getContractAddress({ from: creator.account.address, nonce: startNonce + 3n }),
  };
  const vault = await deploy(client, creator, compiled.vault,
    [usdc.address, predicted.registry, predicted.walkingModule, predicted.workingModule]);
  const registry = await deploy(client, creator, compiled.registry,
    [usdc.address, vault.address, predicted.walkingModule, predicted.workingModule, inviteSigner.address]);
  const settlement = await deploy(client, creator, compiled.module,
    [registry.address, walkingVerifier.address, vault.address]);
  const workingSettlement = await deploy(client, creator, compiled.module,
    [registry.address, workingVerifier.address, vault.address]);
  assert.equal(vault.address.toLowerCase(), predicted.vault.toLowerCase());
  assert.equal(registry.address.toLowerCase(), predicted.registry.toLowerCase());
  assert.equal(settlement.address.toLowerCase(), predicted.walkingModule.toLowerCase());
  assert.equal(workingSettlement.address.toLowerCase(), predicted.workingModule.toLowerCase());
  assert.equal((await vault.read.registry()).toLowerCase(), registry.address.toLowerCase());
  assert.equal((await vault.read.module()).toLowerCase(), settlement.address.toLowerCase());
  assert.equal((await vault.read.workingModule()).toLowerCase(), workingSettlement.address.toLowerCase());
  assert.equal((await settlement.read.registry()).toLowerCase(), registry.address.toLowerCase());
  assert.equal((await settlement.read.sink()).toLowerCase(), vault.address.toLowerCase());
  assert.equal((await workingSettlement.read.registry()).toLowerCase(), registry.address.toLowerCase());

  for (const wallet of [creator, bob, carol, dave, erin]) {
    await send(client, usdc.write.mint([wallet.account.address, STAKE * 50n]));
    await send(client, usdc.write.approve([vault.address, STAKE * 50n], { account: wallet.account }));
  }

  const chainId = await client.getChainId();
  const now = async () => BigInt(await connection.networkHelpers.time.latest());
  const generationId = await registry.read.generationId();

  async function readPact(pactId) {
    const raw = await registry.read.pacts([pactId]);
    const pact = {};
    for (const [index, name] of PACT_FIELDS.entries()) {
      const value = raw[index];
      pact[name] = ['capacity', 'domain', 'startMode', 'status', 'exitPenaltyBps'].includes(name)
        ? Number(value) : (name === 'creator' || name === 'termsHash' ? value : BigInt(value));
    }
    return pact;
  }

  async function createPact({ wallet = creator, stakeAmount = STAKE, joinWindow = HOUR,
    startsIn = 2n * HOUR, duration = DAY, capacity: pactCapacity = capacity, termsHash = TERMS,
    exitPenaltyBps = 0, rolloverAllowed = false } = {}) {
    const time = await now();
    const receipt = await send(client, registry.write.createWalkingPactV6([
      stakeAmount, time + joinWindow, time + startsIn, duration, pactCapacity, termsHash, exitPenaltyBps, rolloverAllowed],
      { account: asAccount(wallet) }));
    const pactId = (await registry.read.nextPactId()) - 1n;
    const created = event(compiled.registry.abi, receipt, 'PactCreatedV6');
    assert.equal(created.pactId, pactId);
    return { pactId, receipt, ...(await readPact(pactId)) };
  }

  async function createRollingPact({ wallet = creator, stakeAmount = STAKE, joinWindow = HOUR,
    activationDelay = 2n * HOUR, duration = DAY, capacity: pactCapacity = capacity, termsHash = TERMS,
    exitPenaltyBps = 0, rolloverAllowed = false } = {}) {
    const time = await now();
    const receipt = await send(client, registry.write.createRollingWalkingPactV6([
      stakeAmount, time + joinWindow, time + activationDelay, duration, pactCapacity, termsHash,
      exitPenaltyBps, rolloverAllowed], { account: asAccount(wallet) }));
    const pactId = (await registry.read.nextPactId()) - 1n;
    return { pactId, receipt, ...(await readPact(pactId)) };
  }

  async function createWorking({ wallet = creator, stakeAmount = STAKE, joinWindow = HOUR,
    startsIn = 2n * HOUR, duration = DAY, capacity: pactCapacity = capacity, termsHash = TERMS,
    evidenceGrace = DAY, exitPenaltyBps = 0, rolloverAllowed = false } = {}) {
    const time = await now();
    const receipt = await send(client, registry.write.createWorkingPactV6([
      stakeAmount, time + joinWindow, time + startsIn, duration, pactCapacity, termsHash, evidenceGrace,
      exitPenaltyBps, rolloverAllowed], { account: asAccount(wallet) }));
    const pactId = (await registry.read.nextPactId()) - 1n;
    return { pactId, receipt, ...(await readPact(pactId)) };
  }

  const inviteDomain = () => ({ name: 'PactRegistryV6', version: '1', chainId,
    verifyingContract: registry.address });

  async function permitFor(pactId, wallet, overrides = {}, signer = inviteSigner, domain = inviteDomain()) {
    const permit = {
      pactId,
      termsHash: TERMS,
      recipient: asAccount(wallet).address,
      inviteEpoch: await registry.read.inviteEpoch([pactId]),
      deadline: (await now()) + 60n,
      nonce: randomNonce(),
      ...overrides,
    };
    const typed = { domain, types: INVITE_PERMIT_TYPES, primaryType: 'InvitePermit', message: permit };
    return { permit, signature: await signer.signTypedData(typed), digest: hashTypedData(typed) };
  }

  async function join(pactId, wallet = bob, { permitOverrides = {}, signer = inviteSigner,
    domain = 'walking', ticket, termsHash = TERMS } = {}) {
    const resolved = ticket ?? await permitFor(pactId, wallet, { termsHash, ...permitOverrides }, signer);
    const functionName = domain === 'working' ? 'joinWorkingPactV6' : 'joinWalkingPactV6';
    return send(client, registry.write[functionName]([resolved.permit, resolved.signature],
      { account: asAccount(wallet) }));
  }

  async function activate(pactId, wallet = creator) {
    return send(client, registry.write.activatePactV6([pactId], { account: asAccount(wallet) }));
  }

  async function leave(pactId, wallet, domain = 'walking') {
    const functionName = domain === 'working' ? 'leaveWorkingPactV6' : 'leaveWalkingPactV6';
    return send(client, registry.write[functionName]([pactId], { account: asAccount(wallet) }));
  }

  async function exit(pactId, wallet, domain = 'walking') {
    const functionName = domain === 'working' ? 'exitWorkingPactV6' : 'exitWalkingPactV6';
    return send(client, registry.write[functionName]([pactId], { account: asAccount(wallet) }));
  }

  async function cancel(pactId, wallet = creator, domain = 'walking') {
    const functionName = domain === 'working' ? 'cancelWorkingPactV6' : 'cancelWalkingPactV6';
    return send(client, registry.write[functionName]([pactId], { account: asAccount(wallet) }));
  }

  async function rotate(pactId, signer, wallet = creator) {
    return send(client, registry.write.rotateInviteSigner([pactId, signer.address],
      { account: asAccount(wallet) }));
  }

  async function block(pactId, recipient, wallet = creator) {
    return send(client, registry.write.blockRecipient([pactId, asAccount(recipient).address ?? recipient],
      { account: asAccount(wallet) }));
  }

  async function unblock(pactId, recipient, wallet = creator) {
    return send(client, registry.write.unblockRecipient([pactId, asAccount(recipient).address ?? recipient],
      { account: asAccount(wallet) }));
  }

  async function approveRollover(sourcePactId, destinationPactId, wallet, approved = true) {
    return send(client, registry.write.approveRolloverV6([sourcePactId, destinationPactId, approved],
      { account: asAccount(wallet) }));
  }

  async function rejectRollover(sourcePactId, wallet) {
    return send(client, registry.write.rejectRolloverV6([sourcePactId], { account: asAccount(wallet) }));
  }

  async function releaseRollover(sourcePactId, wallet = outsider) {
    return send(client, registry.write.releaseRolloverV6([sourcePactId], { account: asAccount(wallet) }));
  }

  async function activateWithRollover(sourcePactId, destinationPactId, wallet) {
    return send(client, registry.write.activateWithRolloverV6([sourcePactId, destinationPactId],
      { account: asAccount(wallet) }));
  }

  async function rolloverOf(pactId) {
    const [deadline, reserve, state, rejected] = await registry.read.rolloverOf([pactId]);
    return { deadline: BigInt(deadline), reserve, state: Number(state), rejected };
  }

  async function ticketFor(pactId, allocations, { domain = 'walking', overrides = {},
    signer = domain === 'working' ? workingVerifier : walkingVerifier, module = domain === 'working'
      ? workingSettlement : settlement } = {}) {
    const authorization = { pactId, termsHash: TERMS, resultsHash: RESULTS, evidenceHash: EVIDENCE,
      allocationsHash: allocationsHashOf(allocations), outcome: 0, nonce: randomNonce(),
      deadline: (await now()) + 7n * DAY, registry: registry.address, generationId, ...overrides };
    const typed = { domain: { name: 'PactSettlementModuleV6', version: '1', chainId,
      verifyingContract: module.address }, types: AUTHORIZATION_TYPES,
    primaryType: 'SettlementAuthorization', message: authorization };
    return { authorization, signature: await signer.signTypedData(typed), digest: hashTypedData(typed) };
  }

  async function settle(ticket, allocations, wallet = creator, domain = 'walking') {
    const functionName = domain === 'working' ? 'settleWorkingPactV6' : 'settleWalkingPactV6';
    return send(client, registry.write[functionName](
      [ticket.authorization, allocations, ticket.signature], { account: asAccount(wallet) }));
  }

  async function refund(pactId, wallet = outsider, domain = 'walking') {
    const functionName = domain === 'working' ? 'refundWorkingPactV6' : 'refundWalkingPactV6';
    return send(client, registry.write[functionName]([pactId], { account: asAccount(wallet) }));
  }

  async function claim(pactId, wallet, domain = 'walking') {
    const target = domain === 'working' ? workingSettlement : settlement;
    return send(client, target.write.claim([pactId], { account: asAccount(wallet) }));
  }

  async function claimVault(pactId, wallet) {
    return send(client, vault.write.claim([pactId], { account: asAccount(wallet) }));
  }

  async function credited(pactId, wallets) {
    let total = 0n;
    for (const wallet of wallets) total += await vault.read.claimable([pactId, asAccount(wallet).address]);
    return total;
  }

  async function accounts(pactId, wallets = []) {
    const [pool, reserve, paidOut, deposited, tokenBalance] = await Promise.all([
      vault.read.unallocatedPool([pactId]), vault.read.rolloverReserve([pactId]),
      vault.read.paidOut([pactId]), vault.read.deposited([pactId]),
      usdc.read.balanceOf([vault.address])]);
    return { pool, reserve, paidOut, deposited, tokenBalance, credited: await credited(pactId, wallets) };
  }

  async function kind(pactId) {
    return Number(await registry.read.pactSettlementKind([pactId]));
  }

  async function fund(accounts_, amount = STAKE) {
    await Promise.all(accounts_.map((account) => connection.networkHelpers.setBalance(account.address, 10n ** 18n)));
    for (const account of accounts_) {
      await send(client, usdc.write.mint([account.address, amount]));
      await send(client, usdc.write.approve([vault.address, amount], { account }));
    }
  }

  return { ...connection, client, creator, bob, carol, dave, erin, outsider, walkingVerifier,
    workingVerifier, inviteSigner, usdc, vault, registry, settlement, workingSettlement, chainId,
    now, generationId, inviteDomain, readPact, createPact, createRollingPact, createWorking,
    permitFor, join, activate, leave, exit, cancel, rotate, block, unblock, ticketFor, settle, refund,
    claim, claimVault, credited, accounts, kind, fund, approveRollover, rejectRollover, releaseRollover,
    activateWithRollover, rolloverOf };
}

describe('Pact Registry V6 system', () => {
  it('compiles every V6 contract within EIP-170 and exposes the required surfaces', () => {
    const moduleSize = assertPactSettlementV6Deployable(compiled);
    const sizes = settlementV6RuntimeSizes(compiled);
    assert.ok(moduleSize > 0);
    for (const [name, size] of Object.entries(sizes)) {
      assert.ok(size > 0 && size <= 24_576, `${name} runtime size`);
      console.log(`Pact V6 runtime size: ${name}=${size} bytes`);
    }
    assert.equal(compiled.sourceSha256.length, 64);

    // Invite-only joins and vault-only accounting are structural, not just behavioral.
    const registryFunctions = new Set(compiled.registry.abi
      .filter((entry) => entry.type === 'function').map((entry) => entry.name));
    assert.equal(registryFunctions.has('joinPactV6'), false);
    assert.equal(registryFunctions.has('joinWalkingPactV6'), true);
    assert.equal(registryFunctions.has('exitWalkingPactV6'), true);
    assert.equal(registryFunctions.has('activateWithRolloverV6'), true);
    const moduleFunctions = new Set(compiled.module.abi
      .filter((entry) => entry.type === 'function').map((entry) => entry.name));
    assert.equal(moduleFunctions.has('claimable'), false);
    assert.equal(moduleFunctions.has('claimed'), false);
    assert.equal(moduleFunctions.has('refundTimedOutV6'), true);
    const vaultFunctions = new Set(compiled.vault.abi
      .filter((entry) => entry.type === 'function').map((entry) => entry.name));
    for (const name of ['unallocatedPool', 'rolloverReserve', 'claimable', 'paidOut', 'claim', 'claimTo',
      'lockRollover', 'moveRolloverReserve', 'releaseRolloverReserve']) {
      assert.equal(vaultFunctions.has(name), true, `vault.${name}`);
    }
  });

  it('pins the creator, the immutable fixed schedule, penalty and the invite default at creation', async () => {
    const f = await fixture({ capacity: 3 });
    const pact = await f.createPact({ exitPenaltyBps: 2_500 });
    assert.equal(pact.creator.toLowerCase(), f.creator.account.address.toLowerCase());
    assert.equal(pact.termsHash, TERMS);
    assert.equal(pact.stakeAmount, STAKE);
    assert.equal(pact.domain, 0);
    assert.equal(pact.startMode, 0);
    assert.equal(pact.status, 1);
    assert.equal(pact.capacity, 3);
    assert.equal(pact.exitPenaltyBps, 2_500);
    assert.equal(pact.evidenceGrace, DAY);
    assert.equal(pact.startsAt, pact.activationDeadline);
    assert.equal(pact.endAt, pact.startsAt + pact.duration);
    assert.equal(pact.evidenceClosesAt, pact.endAt + DAY);
    assert.equal(pact.reviewClosesAt, pact.evidenceClosesAt + REVIEW_WINDOW);
    assert.equal(pact.settlementClosesAt, pact.reviewClosesAt + SETTLEMENT_WINDOW);
    assert.equal(await f.kind(pact.pactId), 0);

    assert.equal(await f.registry.read.isActiveParticipant([pact.pactId, f.creator.account.address]), true);
    assert.equal((await f.registry.read.settlementParticipantAt([pact.pactId, 0n])).toLowerCase(),
      f.creator.account.address.toLowerCase());
    assert.equal(await f.registry.read.activeParticipantCount([pact.pactId]), 1n);
    assert.equal(await f.registry.read.poolOf([pact.pactId]), STAKE);
    assert.equal(await f.vault.read.unallocatedPool([pact.pactId]), STAKE);
    assert.equal(await f.usdc.read.balanceOf([f.vault.address]), STAKE);
    assert.equal(await f.vault.read.rolloverReserve([pact.pactId]), 0n);
    assert.equal(await f.vault.read.paidOut([pact.pactId]), 0n);
    assert.equal(await f.vault.read.deposited([pact.pactId]), STAKE);
    assert.equal(await f.vault.read.principalOf([pact.pactId, f.creator.account.address]), STAKE);
    assert.notEqual(await f.registry.read.generationId(), ZERO_HASH);
    assert.equal(await f.registry.read.defaultInviteSigner(), f.inviteSigner.address);
    assert.equal(await f.registry.read.inviteEpoch([pact.pactId]), 1n);
    assert.equal((await f.registry.read.inviteSigner([pact.pactId])).toLowerCase(),
      f.inviteSigner.address.toLowerCase());
    const terms = await f.registry.read.pactSettlementTerms([pact.pactId]);
    assert.equal(terms[0], TERMS);
    assert.equal(BigInt(terms[1]), pact.endAt);
    assert.equal(BigInt(terms[2]), pact.evidenceClosesAt);
    assert.equal(BigInt(terms[3]), pact.reviewClosesAt);
    assert.equal(BigInt(terms[4]), pact.settlementClosesAt);
    assert.equal(terms[5], STAKE);
    assert.equal(terms[6], 1n);
  });

  it('rejects unusable creation parameters before any stake moves', async () => {
    const f = await fixture();
    const time = await f.now();
    const base = [STAKE, time + HOUR, time + 2n * HOUR, DAY, 3, TERMS, 0];
    const attempt = async (index, value) => {
      const args = [...base];
      args[index] = value;
      await expectError(f.registry.write.createWalkingPactV6(args), 'InvalidConfiguration');
    };
    await attempt(0, 0n);
    await attempt(0, 999_999n);
    await attempt(0, 250_000_001n);
    await attempt(4, 1);
    await attempt(4, 21);
    await attempt(5, ZERO_HASH);
    await attempt(1, time);
    await attempt(1, time + 31n * DAY);
    await attempt(2, time + HOUR - 1n);
    await attempt(2, time + HOUR + 7n * DAY + 1n);
    await attempt(3, 0n);
    await attempt(3, 367n * DAY);
    await attempt(6, 10_001);

    // uint40 overflow / impossible combinations are refused before the token call.
    const overflow = [STAKE, (2n ** 40n) - 1n, (2n ** 40n) - 1n, DAY, 3, TERMS, 0];
    await expectError(f.registry.write.createWalkingPactV6(overflow), 'InvalidConfiguration');

    await expectError(f.registry.write.createRollingWalkingPactV6(
      [STAKE, time + 2n * HOUR, time + HOUR, DAY, 3, TERMS, 0]), 'InvalidConfiguration');
    await expectError(f.registry.write.createRollingWalkingPactV6(
      [STAKE, time + HOUR, time + HOUR + 7n * DAY + 1n, DAY, 3, TERMS, 0]), 'InvalidConfiguration');
    await expectError(f.registry.write.createWorkingPactV6(
      [STAKE, time + HOUR, time + 2n * HOUR, DAY, 3, TERMS, DAY + 1n, 0]), 'InvalidConfiguration');
    await expectError(f.registry.write.createWorkingPactV6(
      [STAKE, time + HOUR, time + 2n * HOUR, DAY, 3, TERMS, (2n ** 40n) - 1n, 0]), 'InvalidConfiguration');
    await expectError(f.registry.write.createWorkingPactV6(
      [STAKE, time + HOUR, time + 2n * HOUR, DAY, 3, TERMS, 0n, 10_001]), 'InvalidConfiguration');

    assert.equal(await f.registry.read.nextPactId(), 1n);
    assert.equal(await f.usdc.read.balanceOf([f.vault.address]), 0n);
  });

  it('fixes the working evidence grace to the accepted 0..24h range and walking to 24h', async () => {
    const f = await fixture();
    const zeroGrace = await f.createWorking({ evidenceGrace: 0n });
    assert.equal(zeroGrace.evidenceGrace, 0n);
    assert.equal(zeroGrace.evidenceClosesAt, zeroGrace.endAt);
    const fullGrace = await f.createWorking({ evidenceGrace: DAY });
    assert.equal(fullGrace.evidenceGrace, DAY);
    assert.equal(fullGrace.evidenceClosesAt, fullGrace.endAt + DAY);

    const walking = await f.createPact();
    assert.equal(walking.evidenceGrace, DAY);
    assert.equal(walking.evidenceClosesAt, walking.endAt + DAY);
  });
});

describe('Pact Registry V6 activation', () => {
  it('rejects activation with one participant or from anyone but the creator', async () => {
    const f = await fixture();
    const { pactId } = await f.createPact();
    await expectError(f.activate(pactId, f.creator), 'NotEnoughParticipants');
    await f.join(pactId, f.bob);
    await expectError(f.activate(pactId, f.bob), 'NotCreator');
    await f.activate(pactId, f.creator);
    assert.equal((await f.readPact(pactId)).status, 2);
    await expectError(f.activate(pactId, f.creator), 'InvalidStatus');
  });

  it('lets a keeper activate once the join deadline passes, but not before', async () => {
    const f = await fixture({ capacity: 4 });
    const created = await f.createPact({ joinWindow: HOUR, startsIn: 3n * HOUR });
    await f.join(created.pactId, f.bob);
    // Two participants, capacity 4, joinDeadline not reached: recruitment is still open, so a
    // non-creator (a keeper with no special role) is still refused.
    await expectError(f.activate(created.pactId, f.outsider), 'NotCreator');
    await expectError(f.activate(created.pactId, f.bob), 'NotCreator');

    await f.networkHelpers.time.increaseTo(created.joinDeadline);
    // Recruitment is now closed (no one else can join); anyone may activate.
    const receipt = await f.activate(created.pactId, f.outsider);
    const activated = event(compiled.registry.abi, receipt, 'PactActivatedV6');
    assert.equal(activated.caller.toLowerCase(), f.outsider.account.address.toLowerCase());
    assert.equal((await f.readPact(created.pactId)).status, 2);
  });

  it('lets a keeper activate as soon as the roster reaches capacity, before the join deadline', async () => {
    const f = await fixture({ capacity: 2 });
    const created = await f.createPact({ joinWindow: 6n * HOUR, startsIn: 12n * HOUR });
    await f.join(created.pactId, f.bob);
    assert.equal(await f.registry.read.activeParticipantCount([created.pactId]), 2n);
    // The join deadline is far away, but the roster is already at capacity: recruitment cannot
    // admit anyone else, so a non-creator keeper may activate immediately.
    const receipt = await f.activate(created.pactId, f.outsider);
    assert.equal(event(compiled.registry.abi, receipt, 'PactActivatedV6').caller.toLowerCase(),
      f.outsider.account.address.toLowerCase());
    assert.equal((await f.readPact(created.pactId)).status, 2);
  });

  it('still blocks a keeper activation once the activation deadline is missed', async () => {
    const f = await fixture({ capacity: 3 });
    const created = await f.createPact({ joinWindow: HOUR, startsIn: 2n * HOUR });
    await f.join(created.pactId, f.bob);
    await f.networkHelpers.time.increaseTo(created.activationDeadline);
    await expectError(f.activate(created.pactId, f.outsider), 'DeadlinePassed');
    await expectError(f.activate(created.pactId, f.creator), 'DeadlinePassed');
  });

  it('keeps the fixed endAt when activated early and closes recruitment', async () => {
    const f = await fixture();
    const created = await f.createPact({ joinWindow: HOUR, startsIn: 3n * HOUR });
    await f.join(created.pactId, f.bob);
    await f.activate(created.pactId, f.creator);
    const activated = await f.readPact(created.pactId);
    assert.equal(activated.endAt, created.endAt);
    assert.equal(activated.startsAt, created.startsAt);
    assert.equal(activated.reviewClosesAt, created.reviewClosesAt);
    assert.equal(activated.settlementClosesAt, created.settlementClosesAt);
    await expectError(f.join(created.pactId, f.carol), 'InvalidStatus');
    await expectError(f.leave(created.pactId, f.bob), 'InvalidStatus');
  });

  it('derives startsAt, endAt and every window at manual activation', async () => {
    const f = await fixture();
    const created = await f.createRollingPact({ joinWindow: HOUR, activationDelay: 3n * HOUR });
    assert.equal(created.startsAt, 0n);
    assert.equal(created.endAt, 0n);
    assert.equal(created.evidenceClosesAt, 0n);
    assert.equal(created.reviewClosesAt, 0n);
    assert.equal(created.settlementClosesAt, 0n);
    await f.join(created.pactId, f.bob);
    await f.networkHelpers.time.increaseTo(created.activationDeadline - 2n * HOUR);
    const receipt = await f.activate(created.pactId, f.creator);
    const activationTime = (await f.client.getBlock({ blockNumber: receipt.blockNumber })).timestamp;
    const activated = event(compiled.registry.abi, receipt, 'PactActivatedV6');
    const pact = await f.readPact(created.pactId);
    assert.equal(pact.startsAt, activationTime);
    assert.equal(pact.endAt, activationTime + created.duration);
    assert.equal(pact.evidenceClosesAt, pact.endAt + DAY);
    assert.equal(pact.reviewClosesAt, pact.evidenceClosesAt + REVIEW_WINDOW);
    assert.equal(pact.settlementClosesAt, pact.reviewClosesAt + SETTLEMENT_WINDOW);
    assert.equal(BigInt(activated.startsAt), pact.startsAt);
    assert.equal(BigInt(activated.endAt), pact.endAt);
    assert.equal(BigInt(activated.settlementClosesAt), pact.settlementClosesAt);
  });

  it('opens a permissionless full-refund recovery when the activation deadline is missed', async () => {
    const f = await fixture({ capacity: 3 });
    const created = await f.createPact({ joinWindow: HOUR, startsIn: 2n * HOUR });
    await f.join(created.pactId, f.bob);
    await f.join(created.pactId, f.carol);
    assert.equal((await f.readPact(created.pactId)).status, 1);

    await f.networkHelpers.time.increaseTo(created.startsAt);
    await expectError(f.activate(created.pactId, f.creator), 'DeadlinePassed');
    const receipt = await f.cancel(created.pactId, f.outsider);
    const cancelled = event(compiled.registry.abi, receipt, 'WalkingPactCancelledV6');
    assert.equal(cancelled.caller.toLowerCase(), f.outsider.account.address.toLowerCase());
    assert.equal(cancelled.participantCount, 3n);
    assert.equal(cancelled.refundedTotal, STAKE * 3n);
    const pact = await f.readPact(created.pactId);
    assert.equal(pact.status, 5);
    assert.equal(await f.kind(created.pactId), 3);
    assert.equal(await f.registry.read.poolOf([created.pactId]), 0n);
    // Cancellation is a pull-refund: custody stays in the vault and every participant owns a
    // credit until they claim it themselves.
    assert.equal(await f.usdc.read.balanceOf([f.vault.address]), STAKE * 3n);
    assert.equal(await f.credited(created.pactId, [f.creator, f.bob, f.carol]), STAKE * 3n);
    for (const wallet of [f.creator, f.bob, f.carol]) {
      await f.claim(created.pactId, wallet);
      assert.equal(await f.usdc.read.balanceOf([wallet.account.address]), STAKE * 50n);
    }
    assert.equal(await f.usdc.read.balanceOf([f.vault.address]), 0n);
    assert.equal(await f.vault.read.paidOut([created.pactId]), STAKE * 3n);

    const allocations = [allocation(f.creator.account.address, STAKE), allocation(f.bob.account.address, STAKE)];
    await f.networkHelpers.time.increaseTo(created.settlementClosesAt + 1n);
    const ticket = await f.ticketFor(created.pactId, allocations);
    await expectError(f.settle(ticket, allocations, f.creator), 'InvalidStatus');
    await expectError(f.refund(created.pactId, f.outsider), 'InvalidStatus');
    await expectError(f.settlement.write.refundTimedOutV6([created.pactId], { account: f.outsider.account }),
      'NotRegistry');
  });

  it('lets only the creator abort before the activation deadline and blocks late aborts', async () => {
    const f = await fixture({ capacity: 3 });
    const early = await f.createPact({ joinWindow: HOUR, startsIn: 2n * HOUR });
    await f.join(early.pactId, f.bob);
    await f.join(early.pactId, f.carol);
    await expectError(f.cancel(early.pactId, f.bob), 'NotCreator');
    await expectError(f.cancel(early.pactId, f.outsider), 'NotCreator');
    const receipt = await f.cancel(early.pactId, f.creator);
    assert.equal(event(compiled.registry.abi, receipt, 'WalkingPactCancelledV6').participantCount, 3n);
    await expectError(f.cancel(early.pactId, f.creator), 'InvalidStatus');
    await expectError(f.join(early.pactId, f.dave), 'InvalidStatus');

    const settled = await f.createPact();
    await f.join(settled.pactId, f.bob);
    await f.activate(settled.pactId, f.creator);
    await f.networkHelpers.time.increaseTo(settled.reviewClosesAt);
    const allocations = [allocation(f.creator.account.address, STAKE), allocation(f.bob.account.address, STAKE)];
    const ticket = await f.ticketFor(settled.pactId, allocations);
    await f.settle(ticket, allocations, f.creator);
    await expectError(f.cancel(settled.pactId, f.creator), 'InvalidStatus');

    const refunded = await f.createPact();
    await f.join(refunded.pactId, f.bob);
    await f.activate(refunded.pactId, f.creator);
    await f.networkHelpers.time.increaseTo(refunded.settlementClosesAt);
    await f.refund(refunded.pactId, f.outsider);
    await expectError(f.cancel(refunded.pactId, f.creator), 'InvalidStatus');
  });

  it('opens the same missed-activation recovery for rolling pacts', async () => {
    const f = await fixture();
    const created = await f.createRollingPact({ joinWindow: HOUR, activationDelay: 2n * HOUR });
    await f.join(created.pactId, f.bob);
    const bobBefore = await f.usdc.read.balanceOf([f.bob.account.address]);
    await f.networkHelpers.time.increaseTo(created.activationDeadline);
    await expectError(f.activate(created.pactId, f.creator), 'DeadlinePassed');
    await f.cancel(created.pactId, f.outsider);
    assert.equal(await f.usdc.read.balanceOf([f.bob.account.address]), bobBefore);
    assert.equal(await f.vault.read.claimable([created.pactId, f.bob.account.address]), STAKE);
    await f.claim(created.pactId, f.bob);
    assert.equal(await f.usdc.read.balanceOf([f.bob.account.address]), bobBefore + STAKE);
    assert.equal((await f.readPact(created.pactId)).status, 5);
  });
});

describe('Pact Registry V6 invite-only participation', () => {
  it('requires a permit bound to the recipient, terms, epoch, signer and an unused nonce', async () => {
    const f = await fixture();
    const { pactId } = await f.createPact();
    const bobTicket = await f.permitFor(pactId, f.bob);
    assert.equal(await f.registry.read.invitePermitDigest([bobTicket.permit]), bobTicket.digest);
    assert.equal(await f.registry.read.domainSeparator(), hashDomain({ domain: {
      name: 'PactRegistryV6', version: '1', chainId: f.chainId,
      verifyingContract: f.registry.address }, types: { EIP712Domain: [
      { name: 'name', type: 'string' }, { name: 'version', type: 'string' },
      { name: 'chainId', type: 'uint256' }, { name: 'verifyingContract', type: 'address' }] } }));

    await expectError(f.join(pactId, f.carol, { ticket: bobTicket }), 'InvalidInvitePermit');
    const impostor = privateKeyToAccount(generatePrivateKey());
    await expectError(f.join(pactId, f.bob, { signer: impostor }), 'InvalidInvitePermit');
    await expectError(f.join(pactId, f.bob, { permitOverrides: { termsHash: `0x${'44'.repeat(32)}` } }),
      'InvalidInvitePermit');
    await expectError(f.join(pactId, f.bob, { permitOverrides: { inviteEpoch: 2n } }), 'InvalidInvitePermit');

    const receipt = await f.join(pactId, f.bob, { ticket: bobTicket });
    assert.equal(event(compiled.registry.abi, receipt, 'ParticipantJoinedV6').position, 1n);
    await expectError(f.join(pactId, f.bob, { ticket: bobTicket }), 'AlreadyParticipant');
    await expectError(f.join(pactId, f.carol, { permitOverrides: { recipient: f.carol.account.address,
      nonce: bobTicket.permit.nonce } }), 'InvitePermitUsed');
    await f.join(pactId, f.carol);
    assert.equal(await f.registry.read.activeParticipantCount([pactId]), 3n);
  });

  it('bounds the permit deadline by the short TTL, the current time and the recruitment deadline', async () => {
    const f = await fixture();
    const { pactId, joinDeadline } = await f.createPact();
    const time = await f.now();
    const ttl = await f.registry.read.MAX_INVITE_PERMIT_TTL();
    // The exact +1 second is racy because the join transaction can be mined one second after
    // the deadline was computed; the TTL gate itself is proven with a clearly-over-TTL value.
    await expectError(f.join(pactId, f.bob, {
      permitOverrides: { deadline: time + BigInt(ttl) + 60n } }), 'InvalidInvitePermit');
    await expectError(f.join(pactId, f.bob, { permitOverrides: { deadline: joinDeadline + 1n } }),
      'InvalidInvitePermit');
    await expectError(f.join(pactId, f.bob, { permitOverrides: { deadline: time - 1n } }),
      'InvalidInvitePermit');
    const exactTtl = await f.permitFor(pactId, f.bob, { deadline: time + BigInt(ttl) });
    await f.join(pactId, f.bob, { ticket: exactTtl });
  });

  it('invalidates every outstanding permit when the creator rotates the signer', async () => {
    const f = await fixture();
    const { pactId } = await f.createPact();
    const oldTicket = await f.permitFor(pactId, f.bob);
    const nextSigner = privateKeyToAccount(generatePrivateKey());
    await expectError(f.rotate(pactId, nextSigner, f.bob), 'NotCreator');
    const receipt = await f.rotate(pactId, nextSigner, f.creator);
    const rotated = event(compiled.registry.abi, receipt, 'InviteSignerRotatedV6');
    assert.equal(rotated.signer.toLowerCase(), nextSigner.address.toLowerCase());
    assert.equal(rotated.epoch, 2n);
    assert.equal(await f.registry.read.inviteEpoch([pactId]), 2n);

    await expectError(f.join(pactId, f.bob, { ticket: oldTicket }), 'InvalidInvitePermit');
    const staleSignerTicket = await f.permitFor(pactId, f.carol, {}, f.inviteSigner);
    await expectError(f.join(pactId, f.carol, { ticket: staleSignerTicket }), 'InvalidInvitePermit');
    const freshTicket = await f.permitFor(pactId, f.carol, {}, nextSigner);
    await f.join(pactId, f.carol, { ticket: freshTicket });
    await f.networkHelpers.time.increaseTo((await f.now()) + HOUR + 1n);
    await expectError(f.rotate(pactId, f.inviteSigner, f.creator), 'DeadlinePassed');
  });

  it('rejects a blocked recipient on-chain until the creator unblocks it', async () => {
    const f = await fixture();
    const { pactId } = await f.createPact();
    await expectError(f.block(pactId, f.dave, f.bob), 'NotCreator');
    const blockReceipt = await f.block(pactId, f.dave, f.creator);
    assert.equal(event(compiled.registry.abi, blockReceipt, 'InviteRecipientBlockedV6').blocked, true);
    await expectError(f.block(pactId, zeroAddress, f.creator), 'InvalidConfiguration');
    const ticket = await f.permitFor(pactId, f.dave);
    await expectError(f.join(pactId, f.dave, { ticket }), 'InviteParticipantBlocked');
    await f.unblock(pactId, f.dave, f.creator);
    await f.join(pactId, f.dave, { ticket });
    assert.equal(await f.registry.read.isActiveParticipant([pactId, f.dave.account.address]), true);
  });

  it('routes joins through the domain entry point only', async () => {
    const f = await fixture();
    const walking = await f.createPact();
    const working = await f.createWorking();
    await expectError(f.join(working.pactId, f.bob, { domain: 'walking' }), 'WrongDomain');
    await expectError(f.join(walking.pactId, f.bob, { domain: 'working' }), 'WrongDomain');
    await f.join(working.pactId, f.bob, { domain: 'working' });
    assert.equal(await f.registry.read.activeParticipantCount([working.pactId]), 2n);
  });
});

describe('Pact Registry V6 domain separation', () => {
  it('settles a working Pact through the working module and pays its claims', async () => {
    const f = await fixture();
    const created = await f.createWorking({ evidenceGrace: HOUR });
    await f.join(created.pactId, f.bob, { domain: 'working' });
    await f.activate(created.pactId, f.creator);
    assert.equal((await f.readPact(created.pactId)).domain, 1);

    const allocations = [allocation(f.creator.account.address, 1_500_000n),
      allocation(f.bob.account.address, 500_000n)];
    const ticket = await f.ticketFor(created.pactId, allocations, { domain: 'working' });
    await f.networkHelpers.time.increaseTo(created.reviewClosesAt);
    const receipt = await f.settle(ticket, allocations, f.creator, 'working');
    assert.equal(event(compiled.registry.abi, receipt, 'WorkingPactSettledV6').outcome, 0);
    assert.equal(await f.kind(created.pactId), 1);
    await f.claim(created.pactId, f.creator, 'working');
    await f.claim(created.pactId, f.bob, 'working');
    assert.equal(await f.usdc.read.balanceOf([f.vault.address]), 0n);
    assert.equal(await f.registry.read.poolOf([created.pactId]), 0n);
  });

  it('rejects cross-domain entry points and cross-domain verifier signatures', async () => {
    const f = await fixture();
    const walking = await f.createPact();
    const working = await f.createWorking();
    await f.join(walking.pactId, f.bob);
    await f.join(working.pactId, f.bob, { domain: 'working' });
    await f.activate(walking.pactId, f.creator);
    await f.activate(working.pactId, f.creator);

    const allocations = [allocation(f.creator.account.address, STAKE), allocation(f.bob.account.address, STAKE)];
    await f.networkHelpers.time.increaseTo(walking.reviewClosesAt);
    await expectError(f.settle(await f.ticketFor(walking.pactId, allocations), allocations, f.creator,
      'working'), 'WrongDomain');
    await expectError(f.refund(walking.pactId, f.outsider, 'working'), 'WrongDomain');
    await expectError(f.exit(walking.pactId, f.bob, 'working'), 'WrongDomain');

    // The working verifier key can never authorize a walking settlement, and vice versa.
    await expectError(f.settle(await f.ticketFor(walking.pactId, allocations, { signer: f.workingVerifier }),
      allocations, f.creator, 'walking'), 'InvalidVerifierSignature');
    await expectError(f.settle(await f.ticketFor(working.pactId, allocations, { signer: f.walkingVerifier }),
      allocations, f.creator, 'working'), 'InvalidVerifierSignature');
  });

  it('refuses the working domain when no working module is wired', async () => {
    const f = await fixture();
    const startNonce = BigInt(await f.client.getTransactionCount({ address: f.creator.account.address }));
    const predictedRegistry = getContractAddress({ from: f.creator.account.address, nonce: startNonce + 1n });
    const vault = await deploy(f.client, f.creator, compiled.vault,
      [f.usdc.address, predictedRegistry, f.settlement.address, zeroAddress]);
    const registry = await deploy(f.client, f.creator, compiled.registry,
      [f.usdc.address, vault.address, f.settlement.address, zeroAddress, f.inviteSigner.address]);
    assert.equal(await registry.read.workingModule(), zeroAddress);

    const time = await f.now();
    const args = [STAKE, time + HOUR, time + 2n * HOUR, DAY, 3, TERMS, 0n, 0];
    await expectError(registry.write.createWorkingPactV6(args), 'ModuleNotConfigured');
    await expectError(registry.write.createWorkingPactV6([...args.slice(0, 6), DAY, 0]), 'ModuleNotConfigured');
    await expectError(registry.write.pactSettlementKind([1n]), 'PactNotFound');
    await expectError(registry.write.refundWorkingPactV6([1n]), 'PactNotFound');
  });
});

describe('Pact Registry V6 lifecycle, settlement and refund', () => {
  it('settles through the module, conserves the exact pool and drains custody on claims', async () => {
    const f = await fixture({ capacity: 3 });
    const created = await f.createPact();
    await f.join(created.pactId, f.bob);
    await f.join(created.pactId, f.carol);
    await expectError(f.join(created.pactId, f.dave), 'CapacityReached');
    await f.activate(created.pactId, f.creator);

    const terms = await f.registry.read.pactSettlementTerms([created.pactId]);
    assert.equal(terms[0], TERMS);
    assert.equal(BigInt(terms[1]), created.endAt);
    assert.equal(terms[5], STAKE * 3n);
    assert.equal(terms[6], 3n);

    const allocations = [
      allocation(f.creator.account.address, 1_500_000n),
      allocation(f.bob.account.address, 1_000_000n),
      allocation(f.carol.account.address, 500_000n),
    ];
    const ticket = await f.ticketFor(created.pactId, allocations);
    assert.equal(await f.settlement.read.settlementDigest([ticket.authorization]), ticket.digest);
    // Before the review window even a non-participant hits the same time gate as everyone
    // else: settlement is permissionless, not participant-gated.
    await expectError(f.settle(ticket, allocations, f.outsider), 'DeadlineNotReached');
    await expectError(f.settle(ticket, allocations, f.creator), 'DeadlineNotReached');
    await expectError(f.settlement.write.refundTimedOutV6([created.pactId], { account: f.outsider.account }),
      'NotRegistry');
    await expectError(f.settlement.write.settleV6([ticket.authorization, allocations, ticket.signature],
      { account: f.outsider.account }), 'NotRegistry');

    await f.networkHelpers.time.increaseTo(created.reviewClosesAt);
    // A non-participant keeper submits the verifier-signed settlement; the allocation is
    // determined entirely by the signature, never by who calls.
    const receipt = await f.settle(ticket, allocations, f.outsider);
    assert.equal(await f.kind(created.pactId), 1);
    const settled = event(compiled.registry.abi, receipt, 'WalkingPactSettledV6');
    assert.equal(settled.pactId, created.pactId);
    assert.equal(settled.allocationsHash, ticket.authorization.allocationsHash);
    assert.equal((await f.readPact(created.pactId)).status, 3);
    await expectError(f.settle(ticket, allocations, f.creator), 'InvalidStatus');
    await expectError(f.refund(created.pactId, f.outsider), 'InvalidStatus');
    await expectError(f.exit(created.pactId, f.bob), 'InvalidStatus');

    // Settlement materializes credits in the vault and empties the unallocated pool: an
    // amount is never in the pool and in a claim at the same time.
    assert.equal(await f.registry.read.poolOf([created.pactId]), 0n);
    assert.equal(await f.vault.read.unallocatedPool([created.pactId]), 0n);
    assert.equal(await f.vault.read.claimable([created.pactId, f.creator.account.address]), 1_500_000n);
    assert.equal(await f.vault.read.claimable([created.pactId, f.bob.account.address]), 1_000_000n);
    assert.equal(await f.vault.read.claimable([created.pactId, f.carol.account.address]), 500_000n);

    await f.claim(created.pactId, f.creator);
    await f.claim(created.pactId, f.bob);
    await f.claim(created.pactId, f.carol);
    assert.equal(await f.usdc.read.balanceOf([f.vault.address]), 0n);
    assert.equal(await f.vault.read.paidOut([created.pactId]), STAKE * 3n);
    const before = STAKE * 50n - STAKE;
    assert.equal(await f.usdc.read.balanceOf([f.creator.account.address]), before + 1_500_000n);
    assert.equal(await f.usdc.read.balanceOf([f.bob.account.address]), before + 1_000_000n);
    assert.equal(await f.usdc.read.balanceOf([f.carol.account.address]), before + 500_000n);
    await expectError(f.claim(created.pactId, f.creator), 'NothingToClaim');
  });

  it('lets a non-participant keeper settle with a valid signature but rejects a tampered one', async () => {
    const f = await fixture({ capacity: 3 });
    const created = await f.createPact();
    await f.join(created.pactId, f.bob);
    await f.join(created.pactId, f.carol);
    await f.activate(created.pactId, f.creator);
    const allocations = [allocation(f.creator.account.address, STAKE),
      allocation(f.bob.account.address, STAKE), allocation(f.carol.account.address, STAKE)];
    await f.networkHelpers.time.increaseTo(created.reviewClosesAt);

    const valid = await f.ticketFor(created.pactId, allocations);
    // The verifier signature, not the caller, is what authorizes the outcome: a keeper who is
    // not a participant (and never joined) cannot forge it, so a tampered signature still fails.
    await expectError(f.settle({ ...valid, signature: `${valid.signature.slice(0, -2)}00` },
      allocations, f.outsider), 'InvalidVerifierSignature');
    // The untampered, validly-signed ticket succeeds from the same non-participant keeper.
    const receipt = await f.settle(valid, allocations, f.outsider);
    assert.equal(await f.kind(created.pactId), 1);
    assert.equal(event(compiled.registry.abi, receipt, 'WalkingPactSettledV6').caller.toLowerCase(),
      f.outsider.account.address.toLowerCase());
    assert.equal(await f.vault.read.claimable([created.pactId, f.bob.account.address]), STAKE);
  });

  it('applies the half-open settlement and refund boundaries at -1 / exact / +1', async () => {
    const f = await fixture();
    const allocations = () => [allocation(f.creator.account.address, STAKE),
      allocation(f.bob.account.address, STAKE)];

    const beforeReview = await f.createPact();
    await f.join(beforeReview.pactId, f.bob);
    await f.activate(beforeReview.pactId, f.creator);
    const beforeReviewTicket = await f.ticketFor(beforeReview.pactId, allocations(beforeReview));
    await f.networkHelpers.time.setNextBlockTimestamp(beforeReview.reviewClosesAt - 1n);
    await expectError(f.settle(beforeReviewTicket, allocations(beforeReview), f.creator), 'DeadlineNotReached');
    await f.networkHelpers.time.setNextBlockTimestamp(beforeReview.reviewClosesAt);
    await f.settle(beforeReviewTicket, allocations(beforeReview), f.creator);
    assert.equal(await f.kind(beforeReview.pactId), 1);

    const atSettlementClose = await f.createPact();
    await f.join(atSettlementClose.pactId, f.bob);
    await f.activate(atSettlementClose.pactId, f.creator);
    const atCloseTicket = await f.ticketFor(atSettlementClose.pactId, allocations(atSettlementClose));
    await f.networkHelpers.time.setNextBlockTimestamp(atSettlementClose.settlementClosesAt - 1n);
    await expectError(f.refund(atSettlementClose.pactId, f.outsider), 'DeadlineNotReached');
    await f.networkHelpers.time.setNextBlockTimestamp(atSettlementClose.settlementClosesAt);
    await expectError(f.settle(atCloseTicket, allocations(atSettlementClose), f.creator), 'DeadlinePassed');
    // The next block is `settlementClosesAt + 1`: the outsider refund is permissionless.
    const receipt = await f.refund(atSettlementClose.pactId, f.outsider);
    const eventArgs = event(compiled.registry.abi, receipt, 'WalkingPactRefundedV6');
    assert.equal(eventArgs.caller.toLowerCase(), f.outsider.account.address.toLowerCase());
    assert.equal(eventArgs.participantCount, 2n);
    assert.equal(eventArgs.distributable, STAKE * 2n);
    assert.equal(await f.kind(atSettlementClose.pactId), 2);
    assert.equal((await f.readPact(atSettlementClose.pactId)).status, 4);
    await expectError(f.settlement.write.refundTimedOutV6([atSettlementClose.pactId],
      { account: f.outsider.account }), 'NotRegistry');
    const claimReceipt = await f.claim(atSettlementClose.pactId, f.bob);
    assert.equal(event(compiled.module.abi, claimReceipt, 'ClaimV6').refundPath, true);
    await f.claim(atSettlementClose.pactId, f.creator);
    assert.equal(await f.vault.read.paidOut([atSettlementClose.pactId]), STAKE * 2n);

    // A fresh Pact lets the exact `settlementClosesAt` instant be mined for the refund.
    const exactClose = await f.createPact();
    await f.join(exactClose.pactId, f.bob);
    await f.activate(exactClose.pactId, f.creator);
    await f.networkHelpers.time.setNextBlockTimestamp(exactClose.settlementClosesAt);
    await f.refund(exactClose.pactId, f.outsider);
    assert.equal(await f.kind(exactClose.pactId), 2);
  });

  it('leaves settlement, claims and timeout refunds of other Pacts untouched', async () => {
    const f = await fixture({ capacity: 3 });
    const cancelled = await f.createPact();
    await f.join(cancelled.pactId, f.bob);
    await f.cancel(cancelled.pactId, f.creator);

    const settled = await f.createPact();
    await f.join(settled.pactId, f.bob);
    await f.join(settled.pactId, f.carol);
    await f.activate(settled.pactId, f.creator);
    const settledAllocations = [
      allocation(f.creator.account.address, 2_000_000n),
      allocation(f.bob.account.address, 500_000n),
      allocation(f.carol.account.address, 500_000n),
    ];
    await f.networkHelpers.time.increaseTo(settled.reviewClosesAt);
    const ticket = await f.ticketFor(settled.pactId, settledAllocations);
    await f.settle(ticket, settledAllocations, f.carol);
    await f.claim(settled.pactId, f.creator);
    await f.claim(settled.pactId, f.bob);
    await f.claim(settled.pactId, f.carol);

    const refunded = await f.createPact();
    await f.join(refunded.pactId, f.bob);
    await f.activate(refunded.pactId, f.creator);
    await f.networkHelpers.time.increaseTo(refunded.settlementClosesAt);
    await f.refund(refunded.pactId, f.outsider);
    await f.claim(refunded.pactId, f.bob);
    await f.claim(refunded.pactId, f.creator);
    await f.claim(cancelled.pactId, f.creator);
    await f.claim(cancelled.pactId, f.bob);

    assert.equal(await f.usdc.read.balanceOf([f.vault.address]), 0n);
    for (const pactId of [cancelled.pactId, settled.pactId, refunded.pactId]) {
      assert.equal(await f.registry.read.poolOf([pactId]), 0n);
      assert.equal(await f.vault.read.rolloverReserve([pactId]), 0n);
      assert.equal(await f.credited(pactId, [f.creator, f.bob, f.carol]), 0n);
    }
  });
});

describe('Pact Registry V6 vault single accounting source', () => {
  it('conserves pool, reserve, claims and paidOut and keeps Pact funds isolated', async () => {
    const f = await fixture({ capacity: 3 });
    const first = await f.createPact();
    await f.join(first.pactId, f.bob);
    const second = await f.createPact();
    await f.join(second.pactId, f.bob);
    await f.activate(second.pactId, f.creator);
    assert.deepEqual(await f.accounts(first.pactId, [f.creator, f.bob]), {
      pool: STAKE * 2n, reserve: 0n, paidOut: 0n, deposited: STAKE * 2n,
      tokenBalance: STAKE * 4n, credited: 0n,
    });

    await f.activate(first.pactId, f.creator);
    await f.networkHelpers.time.increaseTo(first.reviewClosesAt);
    const allocations = [allocation(f.creator.account.address, 1_200_000n),
      allocation(f.bob.account.address, 800_000n)];
    await f.settle(await f.ticketFor(first.pactId, allocations), allocations, f.creator);
    await f.claim(first.pactId, f.creator);

    // Every ledger step keeps the identity; the second Pact is untouched by the first one's
    // settlement and payout.
    const [firstAccounts, secondAccounts] = [await f.accounts(first.pactId, [f.creator, f.bob]),
      await f.accounts(second.pactId, [f.creator, f.bob])];
    assert.equal(firstAccounts.pool, 0n);
    assert.equal(firstAccounts.paidOut, 1_200_000n);
    assert.equal(firstAccounts.credited, 800_000n);
    assert.equal(firstAccounts.tokenBalance + firstAccounts.paidOut,
      firstAccounts.deposited + secondAccounts.deposited);
    assert.equal(firstAccounts.tokenBalance, firstAccounts.credited + secondAccounts.pool);
    assert.deepEqual(secondAccounts, {
      pool: STAKE * 2n, reserve: 0n, paidOut: 0n, deposited: STAKE * 2n,
      tokenBalance: STAKE * 4n - 1_200_000n, credited: 0n,
    });

    // A permissionless timeout refund only splits the refunded Pact's remaining pool.
    await f.networkHelpers.time.increaseTo(second.settlementClosesAt);
    await f.refund(second.pactId, f.outsider);
    assert.equal(await f.credited(second.pactId, [f.creator, f.bob]), STAKE * 2n);
    assert.equal(await f.vault.read.paidOut([first.pactId]), 1_200_000n);
  });

  it('credits cancellation without pushing transfers to a failing recipient', async () => {
    const f = await fixture({ capacity: 3 });
    const created = await f.createPact();
    await f.join(created.pactId, f.bob);
    await f.join(created.pactId, f.carol);
    const receipt = await f.cancel(created.pactId, f.creator);
    assert.equal(event(compiled.registry.abi, receipt, 'WalkingPactCancelledV6').refundedTotal, STAKE * 3n);
    assert.equal(await f.usdc.read.balanceOf([f.vault.address]), STAKE * 3n);

    // The token starts rejecting transfers after the cancellation was already final: one
    // failing claim must not block the credits of the others.
    await send(f.client, f.usdc.write.setTransfersSucceed([false]));
    await expectError(f.claim(created.pactId, f.bob), 'TokenTransferFailed');
    assert.equal(await f.vault.read.claimable([created.pactId, f.bob.account.address]), STAKE);
    assert.equal(await f.usdc.read.balanceOf([f.vault.address]), STAKE * 3n);
    await send(f.client, f.usdc.write.setTransfersSucceed([true]));
    await f.claim(created.pactId, f.creator);
    await f.claim(created.pactId, f.carol);
    await f.claim(created.pactId, f.bob);
    assert.equal(await f.usdc.read.balanceOf([f.vault.address]), 0n);
    assert.equal(await f.vault.read.paidOut([created.pactId]), STAKE * 3n);
  });

  it('serializes parallel claims of different credits and never pays a credit twice', async () => {
    const f = await fixture({ capacity: 3 });
    const created = await f.createPact();
    await f.join(created.pactId, f.bob);
    await f.join(created.pactId, f.carol);
    await f.activate(created.pactId, f.creator);
    const allocations = [allocation(f.creator.account.address, STAKE),
      allocation(f.bob.account.address, STAKE), allocation(f.carol.account.address, STAKE)];
    await f.networkHelpers.time.increaseTo(created.reviewClosesAt);
    await f.settle(await f.ticketFor(created.pactId, allocations), allocations, f.creator);

    await Promise.all([f.claim(created.pactId, f.bob), f.claim(created.pactId, f.carol)]);
    assert.equal(await f.vault.read.claimable([created.pactId, f.bob.account.address]), 0n);
    assert.equal(await f.vault.read.claimable([created.pactId, f.carol.account.address]), 0n);
    await expectError(f.claim(created.pactId, f.bob), 'NothingToClaim');
    // The deployment adapter may target the vault directly; the credit is the same.
    const vaultReceipt = await f.claimVault(created.pactId, f.creator);
    assert.equal(event(compiled.vault.abi, vaultReceipt, 'ClaimedV6').amount, STAKE);
    assert.equal(await f.vault.read.paidOut([created.pactId]), STAKE * 3n);
  });

  it('lets a keeper pay out claimTo only to the credited recipient, never to itself', async () => {
    const f = await fixture({ capacity: 3 });
    const created = await f.createPact();
    await f.join(created.pactId, f.bob);
    await f.join(created.pactId, f.carol);
    await f.activate(created.pactId, f.creator);
    const allocations = [allocation(f.creator.account.address, STAKE),
      allocation(f.bob.account.address, STAKE), allocation(f.carol.account.address, STAKE)];
    await f.networkHelpers.time.increaseTo(created.reviewClosesAt);
    await f.settle(await f.ticketFor(created.pactId, allocations), allocations, f.creator);

    // A zero credit reverts exactly like `claim`, before any state changes.
    await expectError(f.vault.write.claimTo(
      [created.pactId, f.dave.account.address], { account: f.outsider.account }), 'NothingToClaim');

    const bobBefore = await f.usdc.read.balanceOf([f.bob.account.address]);
    const outsiderBefore = await f.usdc.read.balanceOf([f.outsider.account.address]);
    // The keeper (`outsider`) submits the transaction, but only bob's credit moves and only to
    // bob's address; the caller's own balance is untouched.
    const receipt = await send(f.client, f.vault.write.claimTo(
      [created.pactId, f.bob.account.address], { account: f.outsider.account }));
    assert.equal(await f.usdc.read.balanceOf([f.bob.account.address]), bobBefore + STAKE);
    assert.equal(await f.usdc.read.balanceOf([f.outsider.account.address]), outsiderBefore);
    assert.equal(await f.vault.read.claimable([created.pactId, f.bob.account.address]), 0n);
    const claimed = event(compiled.vault.abi, receipt, 'ClaimedV6');
    assert.equal(claimed.recipient.toLowerCase(), f.bob.account.address.toLowerCase());
    assert.equal(claimed.amount, STAKE);
    const claimedFor = event(compiled.vault.abi, receipt, 'ClaimedForV6');
    assert.equal(claimedFor.caller.toLowerCase(), f.outsider.account.address.toLowerCase());
    assert.equal(claimedFor.recipient.toLowerCase(), f.bob.account.address.toLowerCase());
    assert.equal(claimedFor.amount, STAKE);

    // It cannot be called twice: the credit is already zeroed.
    await expectError(f.vault.write.claimTo(
      [created.pactId, f.bob.account.address], { account: f.outsider.account }), 'NothingToClaim');
    await expectError(f.claim(created.pactId, f.bob), 'NothingToClaim');

    // Self-service claim and claimTo consume the exact same credit; carol can still claim
    // herself after a keeper pays out someone else's.
    await f.claim(created.pactId, f.carol);
    assert.equal(await f.vault.read.paidOut([created.pactId]), STAKE * 2n);
  });
});

describe('Pact Registry V6 post-start exit', () => {
  it('credits the full stake during recruitment and rejects exit from the creator or past endAt', async () => {
    const f = await fixture({ capacity: 3 });
    const created = await f.createPact({ exitPenaltyBps: 5_000 });
    await f.join(created.pactId, f.bob);
    await f.join(created.pactId, f.carol);

    const leaveReceipt = await f.leave(created.pactId, f.carol);
    const left = event(compiled.registry.abi, leaveReceipt, 'ParticipantLeftV6');
    assert.equal(left.participant.toLowerCase(), f.carol.account.address.toLowerCase());
    assert.equal(left.refund, STAKE);
    assert.equal(await f.vault.read.claimable([created.pactId, f.carol.account.address]), STAKE);
    assert.equal(await f.registry.read.poolOf([created.pactId]), STAKE * 2n);
    await f.claim(created.pactId, f.carol);
    assert.equal(await f.usdc.read.balanceOf([f.vault.address]), STAKE * 2n);

    await f.activate(created.pactId, f.creator);
    await expectError(f.exit(created.pactId, f.creator), 'NotParticipant');
    await expectError(f.exit(created.pactId, f.outsider), 'NotParticipant');
    await expectError(f.exit(created.pactId, f.carol), 'NotParticipant');
    await f.networkHelpers.time.increaseTo(created.endAt);
    await expectError(f.exit(created.pactId, f.bob), 'DeadlinePassed');
  });

  it('applies 0, 2500 and 10000 bps penalties and keeps the penalty inside the pool', async () => {
    const f = await fixture({ capacity: 3 });
    const cases = [{ bps: 0, refund: STAKE, penalty: 0n }, { bps: 2_500, refund: 750_000n, penalty: 250_000n },
      { bps: 10_000, refund: 0n, penalty: STAKE }];
    for (const { bps, refund, penalty } of cases) {
      const created = await f.createPact({ exitPenaltyBps: bps });
      await f.join(created.pactId, f.bob);
      await f.activate(created.pactId, f.creator);
      const receipt = await f.exit(created.pactId, f.bob);
      const exited = event(compiled.registry.abi, receipt, 'ParticipantExitedV6');
      assert.equal(exited.principal, STAKE);
      assert.equal(exited.penalty, penalty);
      assert.equal(exited.refund, refund);
      assert.equal(await f.vault.read.claimable([created.pactId, f.bob.account.address]), refund);
      assert.equal(await f.registry.read.poolOf([created.pactId]), STAKE + penalty);
      assert.equal(await f.registry.read.isActiveParticipant([created.pactId, f.bob.account.address]), false);
      assert.equal(await f.registry.read.activeParticipantCount([created.pactId]), 1n);
      await f.networkHelpers.time.increaseTo(created.reviewClosesAt);
      const allocations=[allocation(f.creator.account.address,STAKE+penalty)];
      await f.settle(await f.ticketFor(created.pactId,allocations),allocations,f.creator);
      await f.claim(created.pactId,f.creator);
      if(refund) await f.claim(created.pactId,f.bob);
      else await expectError(f.claim(created.pactId,f.bob),'NothingToClaim');
      assert.equal(await f.vault.read.paidOut([created.pactId]),STAKE*2n);

      if (refund > 0n) await expectError(f.claim(created.pactId, f.bob),'NothingToClaim');
      assert.equal(await f.vault.read.principalOf([created.pactId, f.bob.account.address]), 0n);
    }
  });

  it('excludes an exited member from settlement while their credit survives it', async () => {
    const f = await fixture({ capacity: 3 });
    const created = await f.createPact({ exitPenaltyBps: 2_000 });
    await f.join(created.pactId, f.bob);
    await f.join(created.pactId, f.carol);
    await f.activate(created.pactId, f.creator);
    await f.exit(created.pactId, f.carol);
    assert.equal(await f.vault.read.claimable([created.pactId, f.carol.account.address]), 800_000n);
    assert.equal(await f.registry.read.poolOf([created.pactId]), STAKE * 2n + 200_000n);

    const stale = [allocation(f.creator.account.address, 1_200_000n),
      allocation(f.carol.account.address, 1_000_000n)];
    await f.networkHelpers.time.increaseTo(created.reviewClosesAt);
    await expectError(f.settle(await f.ticketFor(created.pactId, stale), stale, f.creator),
      'InvalidParticipant');

    // The remaining pool is exactly the two remaining stakes plus the retained penalty; the
    // already-created exit credit can never be consumed by the settlement.
    const allocations = [allocation(f.creator.account.address, STAKE + 200_000n),
      allocation(f.bob.account.address, STAKE)];
    await f.settle(await f.ticketFor(created.pactId, allocations), allocations, f.creator);
    assert.equal(await f.vault.read.claimable([created.pactId, f.carol.account.address]), 800_000n);
    assert.equal(await f.vault.read.claimable([created.pactId, f.creator.account.address]), STAKE + 200_000n);
    await f.claim(created.pactId, f.carol);
    await f.claim(created.pactId, f.creator);
    await f.claim(created.pactId, f.bob);
    assert.equal(await f.usdc.read.balanceOf([f.vault.address]), 0n);
  });
});

describe('Pact Registry V6 rollover', () => {
  it('allocates refund and rollover dust by numeric address after swap-pop exit',async()=>{
    for(const terminal of ['refund','rollover']) {
      const f=await fixture({capacity:4});
      const wallets=[f.creator,f.bob,f.carol,f.dave].sort((a,b)=>a.account.address.toLowerCase()>b.account.address.toLowerCase()?-1:1);
      const [creator,second,third,leaver]=wallets;
      const source=await f.createPact({wallet:creator,capacity:4,exitPenaltyBps:2500,rolloverAllowed:true});
      for(const member of [leaver,second,third]) await f.join(source.pactId,member);
      await f.activate(source.pactId,creator);await f.networkHelpers.time.increaseTo(source.startsAt);
      await f.exit(source.pactId,leaver);
      const pool=STAKE*3n+STAKE/4n, sorted=[third,second,creator];
      assert.equal(pool%3n,1n);
      assert.notEqual((await f.registry.read.settlementParticipantAt([source.pactId,0n])).toLowerCase(),sorted[0].account.address.toLowerCase());
      if(terminal==='rollover') {
        await f.networkHelpers.time.increaseTo(source.reviewClosesAt);
        await f.settle(await f.ticketFor(source.pactId,[],{overrides:{outcome:3}}),[],creator);
        for(const [i,member] of sorted.entries()) assert.equal(await f.vault.read.rolloverEntitlement([source.pactId,member.account.address]),pool/3n+(i===0?1n:0n));
        await f.rejectRollover(source.pactId,creator);await f.releaseRollover(source.pactId);
      } else {
        await f.networkHelpers.time.increaseTo(source.settlementClosesAt);await f.refund(source.pactId);
      }
      for(const [i,member] of sorted.entries()) {
        assert.equal(await f.vault.read.claimable([source.pactId,member.account.address]),pool/3n+(i===0?1n:0n));
        await f.claim(source.pactId,member);
      }
      await f.claim(source.pactId,leaver);
      assert.equal(await f.vault.read.paidOut([source.pactId]),STAKE*4n);
    }
  });

  it('requires an immutable rollover opt-in in both domains even with a valid verifier signature', async () => {
    for (const domain of ['walking', 'working']) {
      const f = await fixture();
      const created = domain === 'walking' ? await f.createPact() : await f.createWorking();
      assert.equal(await f.registry.read.rolloverAllowed([created.pactId]), false);
      await f.join(created.pactId, f.bob, { domain });
      await f.activate(created.pactId, f.creator);
      await f.networkHelpers.time.increaseTo(created.reviewClosesAt);
      const invalid = await f.ticketFor(created.pactId, [], { domain, overrides: { outcome: 3 } });
      await expectError(f.settle(invalid, [], f.creator, domain), 'RolloverUnavailable');
      assert.equal((await f.readPact(created.pactId)).status, 2);
      assert.equal(await f.vault.read.unallocatedPool([created.pactId]), STAKE * 2n);
      assert.equal(await f.vault.read.rolloverReserve([created.pactId]), 0n);
      const allocations = [allocation(f.creator.account.address, STAKE), allocation(f.bob.account.address, STAKE)];
      await f.settle(await f.ticketFor(created.pactId, allocations, { domain }), allocations, f.creator, domain);
      assert.equal((await f.readPact(created.pactId)).status, 3);
    }
  });

  it('keeps legacy creation fail-closed and records explicit Working and rolling Walking opt-in', async () => {
    const f = await fixture();
    const time = await f.now();
    await send(f.client, f.registry.write.createWalkingPactV6([
      STAKE, time + HOUR, time + 2n * HOUR, DAY, 2, TERMS, 0], { account: asAccount(f.creator) }));
    const legacyId = (await f.registry.read.nextPactId()) - 1n;
    assert.equal(await f.registry.read.rolloverAllowed([legacyId]), false);
    const rolling = await f.createRollingPact({ rolloverAllowed: true });
    assert.equal(await f.registry.read.rolloverAllowed([rolling.pactId]), true);
    const working = await f.createWorking({ rolloverAllowed: true });
    assert.equal(await f.registry.read.rolloverAllowed([working.pactId]), true);
    await f.join(working.pactId, f.bob, { domain: 'working' });
    await f.activate(working.pactId, f.creator);
    await f.networkHelpers.time.increaseTo(working.reviewClosesAt);
    await f.settle(await f.ticketFor(working.pactId, [], { domain: 'working', overrides: { outcome: 3 } }), [], f.creator, 'working');
    assert.equal(await f.vault.read.rolloverReserve([working.pactId]), STAKE * 2n);
  });

  async function lockedRolloverFixture() {
    const f = await fixture({ capacity: 3 });
    const source = await f.createPact({ joinWindow: 2n * HOUR, startsIn: 4n * HOUR, rolloverAllowed: true });
    await f.join(source.pactId, f.bob);
    await f.join(source.pactId, f.carol);
    await f.activate(source.pactId, f.creator);
    await f.networkHelpers.time.increaseTo(source.reviewClosesAt);
    const ticket = await f.ticketFor(source.pactId, [], { overrides: { outcome: 3 } });
    const receipt = await f.settle(ticket, [], f.creator);
    assert.equal(event(compiled.registry.abi, receipt, 'RolloverLockedV6').amount, STAKE * 3n);
    return { f, source, settleReceipt: receipt };
  }

  async function joinDestination(f, destination, members) {
    for (const wallet of members) await f.join(destination.pactId, wallet, { termsHash: TERMS });
  }

  it('locks the reserve on a verified outcome-3 settlement and moves it with unanimous consent', async () => {
    const { f, source, settleReceipt } = await lockedRolloverFixture();
    const settleTime = (await f.client.getBlock({ blockNumber: settleReceipt.blockNumber })).timestamp;
    const locked = await f.rolloverOf(source.pactId);
    assert.equal(locked.state, 1);
    assert.equal(locked.reserve, STAKE * 3n);
    assert.equal(locked.deadline, settleTime + ROLLOVER_WINDOW);
    assert.equal(locked.rejected, false);
    assert.equal(await f.vault.read.unallocatedPool([source.pactId]), 0n);
    for (const wallet of [f.creator, f.bob, f.carol]) {
      assert.equal(await f.vault.read.rolloverEntitlement([source.pactId, wallet.account.address]), STAKE);
    }

    await expectError(f.activateWithRollover(source.pactId, source.pactId, f.creator), 'RolloverUnavailable');
    const destination = await f.createPact({ wallet: f.bob, joinWindow: 2n * HOUR, startsIn: 4n * HOUR });
    await joinDestination(f, destination, [f.creator, f.carol]);
    for (const wallet of [f.creator, f.bob, f.carol]) {
      const receipt = await f.approveRollover(source.pactId, destination.pactId, wallet);
      assert.equal(event(compiled.registry.abi, receipt, 'RolloverApprovalChangedV6').approved, true);
    }
    const destLicenseReceipt = await f.activateWithRollover(source.pactId, destination.pactId, f.bob);
    assert.equal(event(compiled.registry.abi, destLicenseReceipt, 'RolloverConsumedV6').amount, STAKE * 3n);
    assert.equal((await f.readPact(destination.pactId)).status, 2);
    assert.equal(await f.rolloverOf(source.pactId).then(({ state }) => state), 2);
    assert.equal(await f.vault.read.rolloverReserve([source.pactId]), 0n);
    assert.equal(await f.registry.read.poolOf([destination.pactId]), STAKE * 6n);
    for (const wallet of [f.creator, f.bob, f.carol]) {
      assert.equal(await f.vault.read.rolloverPrincipal([destination.pactId, wallet.account.address]), STAKE);
      assert.equal(await f.vault.read.principalOf([destination.pactId, wallet.account.address]), STAKE * 2n);
    }
    // The credited rollover is real principal: an exit from the destination charges the
    // penalty on cash + rollover and leaves the penalty in the destination pool.
    const destinationExit = await f.exit(destination.pactId, f.carol);
    const exited = event(compiled.registry.abi, destinationExit, 'ParticipantExitedV6');
    assert.equal(exited.principal, STAKE * 2n);
    assert.equal(exited.penalty, 0n);
    assert.equal(exited.refund, STAKE * 2n);
    assert.equal(await f.vault.read.claimable([destination.pactId, f.carol.account.address]), STAKE * 2n);
    assert.equal(await f.registry.read.poolOf([destination.pactId]), STAKE * 4n);
    await expectError(f.activateWithRollover(source.pactId, destination.pactId, f.bob), 'RolloverUnavailable');
    await expectError(f.releaseRollover(source.pactId), 'RolloverUnavailable');
  });

  it('rejects different membership, a missing approval and a revoked approval', async () => {
    const { f, source } = await lockedRolloverFixture();
    const different = await f.createPact({ wallet: f.bob, joinWindow: 2n * HOUR, startsIn: 4n * HOUR });
    await f.join(different.pactId, f.creator);
    for (const wallet of [f.creator, f.bob]) await f.approveRollover(source.pactId, different.pactId, wallet);
    await expectError(f.activateWithRollover(source.pactId, different.pactId, f.bob), 'RolloverUnavailable');

    const destination = await f.createPact({ wallet: f.bob, joinWindow: 2n * HOUR, startsIn: 4n * HOUR });
    await joinDestination(f, destination, [f.creator, f.carol]);
    await f.approveRollover(source.pactId, destination.pactId, f.creator);
    await f.approveRollover(source.pactId, destination.pactId, f.bob);
    await expectError(f.activateWithRollover(source.pactId, destination.pactId, f.bob), 'RolloverUnavailable');
    await f.approveRollover(source.pactId, destination.pactId, f.carol);
    await f.approveRollover(source.pactId, destination.pactId, f.bob, false);
    await expectError(f.activateWithRollover(source.pactId, destination.pactId, f.bob), 'RolloverUnavailable');
    await expectError(f.activateWithRollover(source.pactId, destination.pactId, f.creator), 'NotCreator');
    await f.approveRollover(source.pactId, destination.pactId, f.bob);
    await expectError(f.approveRollover(source.pactId, destination.pactId, f.dave), 'NotParticipant');
    await f.activateWithRollover(source.pactId, destination.pactId, f.bob);
    assert.equal(await f.rolloverOf(source.pactId).then(({ state }) => state), 2);
  });

  it('refunds the reserve after rejection or expiry and never moves the same reserve twice', async () => {
    const rejected = await lockedRolloverFixture();
    await expectError(rejected.f.approveRollover(rejected.source.pactId, rejected.source.pactId,
      rejected.f.creator), 'RolloverUnavailable');
    const destination = await rejected.f.createPact({ wallet: rejected.f.bob, joinWindow: 2n * HOUR,
      startsIn: 4n * HOUR });
    await rejected.f.join(destination.pactId, rejected.f.creator);
    await rejected.f.approveRollover(rejected.source.pactId, destination.pactId, rejected.f.creator);
    await rejected.f.rejectRollover(rejected.source.pactId, rejected.f.bob);
    assert.equal(await rejected.f.rolloverOf(rejected.source.pactId).then(({ rejected: value }) => value), true);
    const releaseReceipt = await rejected.f.releaseRollover(rejected.source.pactId, rejected.f.outsider);
    assert.equal(event(compiled.registry.abi, releaseReceipt, 'RolloverReleasedV6').amount, STAKE * 3n);
    assert.equal(await rejected.f.rolloverOf(rejected.source.pactId).then(({ state }) => state), 3);
    assert.equal(await rejected.f.vault.read.rolloverReserve([rejected.source.pactId]), 0n);
    assert.equal(await rejected.f.vault.read.claimable([rejected.source.pactId,
      rejected.f.carol.account.address]), STAKE);
    await rejected.f.claim(rejected.source.pactId, rejected.f.carol);
    assert.equal(await rejected.f.vault.read.claimable([rejected.source.pactId,
      rejected.f.carol.account.address]), 0n);
    await expectError(rejected.f.releaseRollover(rejected.source.pactId), 'RolloverUnavailable');
    await expectError(rejected.f.activateWithRollover(rejected.source.pactId, destination.pactId,
      rejected.f.bob), 'RolloverUnavailable');

    const expired = await lockedRolloverFixture();
    const lateDestination = await expired.f.createPact({ wallet: expired.f.bob, joinWindow: 2n * HOUR,
      startsIn: 4n * HOUR });
    const expiredDeadline = (await expired.f.rolloverOf(expired.source.pactId)).deadline;
    await expired.f.networkHelpers.time.increaseTo(expiredDeadline + 1n);
    await expectError(expired.f.approveRollover(expired.source.pactId, lateDestination.pactId,
      expired.f.creator), 'RolloverUnavailable');
    const receipt = await expired.f.releaseRollover(expired.source.pactId, expired.f.outsider);
    assert.equal(event(compiled.registry.abi, receipt, 'RolloverReleasedV6').amount, STAKE * 3n);
    assert.equal(await expired.f.vault.read.claimable([expired.source.pactId,
      expired.f.creator.account.address]), STAKE);
    for (const wallet of [expired.f.creator, expired.f.bob, expired.f.carol]) {
      await expired.f.claim(expired.source.pactId, wallet);
    }
    assert.equal(await expired.f.credited(expired.source.pactId,
      [expired.f.creator, expired.f.bob, expired.f.carol]), 0n);
    assert.equal(await expired.f.vault.read.paidOut([expired.source.pactId]), STAKE * 3n);
    // The only custody left is the untouched late destination deposit.
    assert.equal(await expired.f.usdc.read.balanceOf([expired.f.vault.address]), STAKE);
  });
});

describe('Pact Registry V6 capacity, churn and custody security', () => {
  it('bounds the roster with swap-pop and blocks leavers from rejoining', async () => {
    const f = await fixture({ capacity: 3 });
    const { pactId } = await f.createPact();
    await f.join(pactId, f.bob);
    await f.join(pactId, f.carol);
    await expectError(f.join(pactId, f.dave), 'CapacityReached');

    const leaveReceipt = await f.leave(pactId, f.carol);
    const left = event(compiled.registry.abi, leaveReceipt, 'ParticipantLeftV6');
    assert.equal(left.participant.toLowerCase(), f.carol.account.address.toLowerCase());
    assert.equal(left.refund, STAKE);
    assert.equal(await f.usdc.read.balanceOf([f.vault.address]), STAKE * 3n);
    assert.equal(await f.registry.read.activeParticipantCount([pactId]), 2n);
    assert.equal(await f.registry.read.poolOf([pactId]), STAKE * 2n);

    await f.join(pactId, f.dave);
    assert.equal((await f.registry.read.settlementParticipantAt([pactId, 2n])).toLowerCase(),
      f.dave.account.address.toLowerCase());

    const swapReceipt = await f.leave(pactId, f.bob);
    const swap = event(compiled.registry.abi, swapReceipt, 'ParticipantSwapV6');
    assert.equal(swap.movedParticipant.toLowerCase(), f.dave.account.address.toLowerCase());
    assert.equal(swap.fromIndex, 2n);
    assert.equal(swap.toIndex, 1n);
    assert.equal((await f.registry.read.settlementParticipantAt([pactId, 0n])).toLowerCase(),
      f.creator.account.address.toLowerCase());
    assert.equal((await f.registry.read.settlementParticipantAt([pactId, 1n])).toLowerCase(),
      f.dave.account.address.toLowerCase());
    assert.equal(await f.registry.read.isActiveParticipant([pactId, f.bob.account.address]), false);
    // Both leavers own independent credits; the vault holds the same tokens it received.
    await f.claim(pactId, f.carol);
    await f.claim(pactId, f.bob);

    await expectError(f.join(pactId, f.carol), 'AlreadyParticipant');
    await expectError(f.join(pactId, f.bob), 'AlreadyParticipant');
    await expectError(f.leave(pactId, f.creator), 'NotParticipant');
    await expectError(f.leave(pactId, f.outsider), 'NotParticipant');

    await f.networkHelpers.time.increaseTo((await f.now()) + HOUR + 1n);
    await expectError(f.leave(pactId, f.dave), 'DeadlinePassed');
    await expectError(f.join(pactId, randomAccounts(1)[0], { signer: f.inviteSigner }), 'DeadlinePassed');
  });

  it('settles only the remaining roster after a recruiting-phase leave', async () => {
    const f = await fixture({ capacity: 3 });
    const created = await f.createPact();
    await f.join(created.pactId, f.bob);
    await f.join(created.pactId, f.carol);
    await f.leave(created.pactId, f.carol);
    await f.activate(created.pactId, f.creator);
    assert.equal(await f.registry.read.poolOf([created.pactId]), STAKE * 2n);

    const stale = [allocation(f.creator.account.address, STAKE),
      allocation(f.carol.account.address, STAKE)];
    const staleTicket = await f.ticketFor(created.pactId, stale);
    await f.networkHelpers.time.increaseTo(created.reviewClosesAt);
    await expectError(f.settle(staleTicket, stale, f.creator), 'InvalidParticipant');

    const allocations = [allocation(f.creator.account.address, STAKE),
      allocation(f.bob.account.address, STAKE)];
    const ticket = await f.ticketFor(created.pactId, allocations);
    await f.settle(ticket, allocations, f.creator);
    await f.claim(created.pactId, f.creator);
    await f.claim(created.pactId, f.bob);
    await f.claim(created.pactId, f.carol);
    assert.equal(await f.usdc.read.balanceOf([f.vault.address]), 0n);
    assert.equal(await f.vault.read.paidOut([created.pactId]), STAKE * 3n);
  });

  it('accepts exactly 20 active participants and rejects the 21st join', async () => {
    const f = await fixture({ capacity: 20 });
    const accounts = randomAccounts(20);
    await f.fund(accounts);
    const { pactId } = await f.createPact({ joinWindow: 2n * HOUR, startsIn: 3n * HOUR });
    for (let index = 0; index < 19; ++index) await f.join(pactId, accounts[index]);
    assert.equal(await f.registry.read.activeParticipantCount([pactId]), 20n);
    await expectError(f.join(pactId, accounts[19]), 'CapacityReached');
    assert.equal((await f.registry.read.settlementParticipantAt([pactId, 19n])).toLowerCase(),
      accounts[18].address.toLowerCase());
    assert.equal(await f.registry.read.poolOf([pactId]), STAKE * 20n);
  });

  it('rejects unauthorized settlement, custody mutation and over-pool credits', async () => {
    const f = await fixture({ capacity: 3 });
    const created = await f.createPact();
    await f.join(created.pactId, f.bob);
    const allocations = [allocation(f.creator.account.address, STAKE), allocation(f.bob.account.address, STAKE)];
    const ticket = await f.ticketFor(created.pactId, allocations);
    await f.networkHelpers.time.increaseTo(created.reviewClosesAt);

    await expectError(f.settlement.write.settleV6([ticket.authorization, allocations, ticket.signature],
      { account: f.outsider.account }), 'NotRegistry');
    await expectError(f.workingSettlement.write.settleV6([ticket.authorization, allocations, ticket.signature],
      { account: f.outsider.account }), 'NotRegistry');
    await expectError(f.vault.write.deposit([created.pactId, f.outsider.account.address, STAKE],
      { account: f.outsider.account }), 'OnlyRegistry');
    await expectError(f.vault.write.release([created.pactId, f.bob.account.address],
      { account: f.outsider.account }), 'OnlyRegistry');
    await expectError(f.vault.write.exit([created.pactId, f.bob.account.address, 1n],
      { account: f.outsider.account }), 'OnlyRegistry');
    await expectError(f.vault.write.lockRollover([created.pactId, created.reviewClosesAt,
      [f.bob.account.address]], { account: f.outsider.account }), 'OnlyRegistry');
    await expectError(f.vault.write.moveRolloverReserve([created.pactId, created.pactId + 1n],
      { account: f.outsider.account }), 'OnlyRegistry');
    await expectError(f.vault.write.releaseRolloverReserve([created.pactId],
      { account: f.outsider.account }), 'OnlyRegistry');
    await expectError(f.vault.write.payout([created.pactId, f.bob.account.address, 1n],
      { account: f.outsider.account }), 'OnlyModule');
    await expectError(f.vault.write.refundPayout([created.pactId, f.bob.account.address, 1n],
      { account: f.outsider.account }), 'OnlyModule');
    await expectError(f.vault.write.claimFor([created.pactId, f.bob.account.address],
      { account: f.outsider.account }), 'OnlyModule');
    // A stranger can only ever pull its own balance.
    await expectError(f.vault.write.claim([created.pactId], { account: f.outsider.account }),
      'NothingToClaim');
    // `claimTo` is deliberately permissionless (any keeper may submit it) but still only ever
    // pays the named recipient's own credit; a stranger naming itself with no credit fails the
    // same way `claim` does, never `OnlyModule`/`OnlyRegistry`.
    await expectError(f.vault.write.claimTo([created.pactId, f.outsider.account.address],
      { account: f.outsider.account }), 'NothingToClaim');

    const actors = await deploy(f.client, f.creator, localArtifacts.MockVaultActorsV6);
    const detached = await deploy(f.client, f.creator, compiled.vault,
      [f.usdc.address, actors.address, actors.address, zeroAddress]);
    await send(f.client, f.usdc.write.approve([detached.address, STAKE], { account: f.creator.account }));
    await send(f.client, actors.write.callDeposit([detached.address, 1n, f.creator.account.address, STAKE]));
    assert.equal(await detached.read.pool([1n]), STAKE);
    await expectError(actors.write.callPayout([detached.address, 1n, f.bob.account.address, STAKE + 1n]),
      'InvalidSettlement');
    await send(f.client, actors.write.callPayout([detached.address, 1n, f.bob.account.address, STAKE]));
    assert.equal(await detached.read.pool([1n]), 0n);
    assert.equal(await detached.read.claimable([1n, f.bob.account.address]), STAKE);
    await expectError(actors.write.callRefundPayout([detached.address, 1n, f.bob.account.address, 1n]),
      'InvalidSettlement');
    await expectError(actors.write.callRelease([detached.address, 1n, f.creator.account.address]),
      'InvalidSettlement');
    await expectError(actors.write.callExit([detached.address, 1n, f.creator.account.address, STAKE]),
      'InvalidSettlement');

    // The vault authorizes either configured module. With the walking slot zeroed and the
    // working slot set to the actor, the actor credits claimable bounded by the Pact pool.
    const workingDetached = await deploy(f.client, f.creator, compiled.vault,
      [f.usdc.address, actors.address, f.usdc.address, actors.address]);
    await send(f.client, f.usdc.write.approve([workingDetached.address, STAKE], { account: f.creator.account }));
    await send(f.client, actors.write.callDeposit([workingDetached.address, 1n, f.creator.account.address, STAKE]));
    await expectError(actors.write.callPayout([workingDetached.address, 1n, f.bob.account.address, STAKE + 1n]),
      'InvalidSettlement');
    await send(f.client, actors.write.callPayout([workingDetached.address, 1n, f.bob.account.address, STAKE]));
    assert.equal(await workingDetached.read.pool([1n]), 0n);
    assert.equal(await workingDetached.read.claimable([1n, f.bob.account.address]), STAKE);
  });

  it('rejects fee-on-transfer stakes atomically and supports no-return tokens end to end', async () => {
    const feeFixture = await fixture({ tokenName: 'FeeOnTransferERC20', capacity: 3 });
    const created = await feeFixture.createPact();
    await send(feeFixture.client, feeFixture.usdc.write.setFeeBps([100n]));
    await expectError(feeFixture.join(created.pactId, feeFixture.bob), 'TokenAmountMismatch');
    assert.equal(await feeFixture.registry.read.isActiveParticipant([created.pactId, feeFixture.bob.account.address]), false);
    assert.equal(await feeFixture.registry.read.activeParticipantCount([created.pactId]), 1n);
    assert.equal(await feeFixture.registry.read.poolOf([created.pactId]), STAKE);
    assert.equal(await feeFixture.usdc.read.balanceOf([feeFixture.vault.address]), STAKE);

    // A fee appearing between settlement and claim can never mint value: the credit survives
    // the failed transfer and is paid exactly once the token behaves again.
    await send(feeFixture.client, feeFixture.usdc.write.setFeeBps([0n]));
    await feeFixture.join(created.pactId, feeFixture.bob);
    await feeFixture.activate(created.pactId, feeFixture.creator);
    await feeFixture.networkHelpers.time.increaseTo(created.reviewClosesAt);
    const feeAllocations = [allocation(feeFixture.creator.account.address, STAKE),
      allocation(feeFixture.bob.account.address, STAKE)];
    await feeFixture.settle(await feeFixture.ticketFor(created.pactId, feeAllocations), feeAllocations,
      feeFixture.creator);
    await send(feeFixture.client, feeFixture.usdc.write.setFeeBps([100n]));
    await expectError(feeFixture.claim(created.pactId, feeFixture.bob), 'TokenAmountMismatch');
    assert.equal(await feeFixture.vault.read.claimable([created.pactId, feeFixture.bob.account.address]), STAKE);
    await send(feeFixture.client, feeFixture.usdc.write.setFeeBps([0n]));
    await feeFixture.claim(created.pactId, feeFixture.bob);
    assert.equal(await feeFixture.vault.read.paidOut([created.pactId]), STAKE);

    const f = await fixture({ tokenName: 'NoReturnERC20', capacity: 3 });
    const noReturn = await f.createPact();
    await f.join(noReturn.pactId, f.bob);
    await f.join(noReturn.pactId, f.carol);
    await f.activate(noReturn.pactId, f.creator);
    const allocations = [
      allocation(f.creator.account.address, STAKE),
      allocation(f.bob.account.address, STAKE),
      allocation(f.carol.account.address, STAKE),
    ];
    await f.networkHelpers.time.increaseTo(noReturn.reviewClosesAt);
    const ticket = await f.ticketFor(noReturn.pactId, allocations);
    await f.settle(ticket, allocations, f.creator);
    await f.claim(noReturn.pactId, f.creator);
    await f.claim(noReturn.pactId, f.bob);
    await f.claim(noReturn.pactId, f.carol);
    assert.equal(await f.usdc.read.balanceOf([f.vault.address]), 0n);
    assert.equal(await f.registry.read.poolOf([noReturn.pactId]), 0n);
  });

  it('keeps the claim lock closed when the stake token re-enters through the real vault', async () => {
    const f = await fixture({ tokenName: 'ReentrantERC20', capacity: 3 });
    const created = await f.createPact();
    await f.join(created.pactId, f.bob);
    await f.join(created.pactId, f.carol);
    await f.activate(created.pactId, f.creator);
    await send(f.client, f.usdc.write.configureReentry([f.settlement.address, created.pactId, true, true]));

    const allocations = [
      allocation(f.creator.account.address, STAKE),
      allocation(f.bob.account.address, STAKE),
      allocation(f.carol.account.address, STAKE),
    ];
    await f.networkHelpers.time.increaseTo(created.reviewClosesAt);
    const ticket = await f.ticketFor(created.pactId, allocations);
    await f.settle(ticket, allocations, f.creator);
    await f.claim(created.pactId, f.creator);

    assert.equal(await f.usdc.read.reentryAttempted(), true);
    assert.equal(await f.usdc.read.reentrySucceeded(), false);
    assert.equal(await f.usdc.read.lastReentryError(), toFunctionSelector('ReentrantCall()'));
    assert.equal(await f.vault.read.claimable([created.pactId, f.creator.account.address]), 0n);
    assert.equal(await f.vault.read.claimable([created.pactId, f.bob.account.address]), STAKE);
    assert.equal(await f.vault.read.paidOut([created.pactId]), STAKE);
  });
});

describe('Pact Registry V6 gas envelope at the 20 participant cap', () => {
  it('measures create, join, settle, refund and claim gas for a full 20 member Pact', async () => {
    const f = await fixture({ capacity: 20 });
    const accounts = randomAccounts(19);
    await f.fund(accounts, STAKE * 2n);

    const first = await f.createPact({ joinWindow: 2n * HOUR, startsIn: 3n * HOUR });
    const createGas = first.receipt.gasUsed;
    let firstJoinGas = 0n;
    let lastJoinGas = 0n;
    for (let index = 0; index < accounts.length; ++index) {
      const receipt = await f.join(first.pactId, accounts[index]);
      if (index === 0) firstJoinGas = receipt.gasUsed;
      lastJoinGas = receipt.gasUsed;
    }
    assert.equal(await f.registry.read.activeParticipantCount([first.pactId]), 20n);
    await f.activate(first.pactId, f.creator);

    const allocations = [allocation(f.creator.account.address, STAKE),
      ...accounts.map((account) => allocation(account.address, STAKE))];
    await f.networkHelpers.time.increaseTo(first.reviewClosesAt);
    const ticket = await f.ticketFor(first.pactId, allocations);
    const settleReceipt = await f.settle(ticket, allocations, f.creator);
    const claimReceipt = await f.claim(first.pactId, f.creator);

    const second = await f.createPact({ joinWindow: 2n * HOUR, startsIn: 2n * HOUR, duration: HOUR });
    for (const account of accounts) await f.join(second.pactId, account);
    await f.activate(second.pactId, f.creator);
    await f.networkHelpers.time.increaseTo(second.settlementClosesAt);
    const refundReceipt = await f.refund(second.pactId, f.outsider);
    const refundClaimReceipt = await f.claim(second.pactId, accounts[0]);

    console.log('Pact Registry V6 gas @20 participants: ' +
      `create=${createGas} firstJoin=${firstJoinGas} lastJoin=${lastJoinGas} ` +
      `settle=${settleReceipt.gasUsed} refund=${refundReceipt.gasUsed} ` +
      `claim=${claimReceipt.gasUsed} refundClaim=${refundClaimReceipt.gasUsed}`);

    assert.ok(createGas < 700_000n, `create gas: ${createGas}`);
    assert.ok(lastJoinGas < 300_000n, `join gas: ${lastJoinGas}`);
    assert.ok(settleReceipt.gasUsed < 1_600_000n, `settle gas: ${settleReceipt.gasUsed}`);
    assert.ok(refundReceipt.gasUsed < 1_800_000n, `refund gas: ${refundReceipt.gasUsed}`);
    assert.ok(claimReceipt.gasUsed < 250_000n, `claim gas: ${claimReceipt.gasUsed}`);
    assert.ok(refundClaimReceipt.gasUsed < 250_000n, `refund claim gas: ${refundClaimReceipt.gasUsed}`);
    assert.equal(await f.credited(second.pactId, accounts.slice(1)), STAKE * 18n);
  });

  it('measures recruitment cancellation gas for a full 20 member Pact', async () => {
    const f = await fixture({ capacity: 20 });
    const accounts = randomAccounts(19);
    await f.fund(accounts);

    const { pactId } = await f.createPact({ joinWindow: 2n * HOUR, startsIn: 3n * HOUR });
    for (const account of accounts) await f.join(pactId, account);
    assert.equal(await f.registry.read.activeParticipantCount([pactId]), 20n);

    const receipt = await f.cancel(pactId, f.creator);
    console.log('Pact Registry V6 cancel gas @20 participants: ' + `cancel=${receipt.gasUsed}`);

    assert.equal(await f.registry.read.poolOf([pactId]), 0n);
    assert.equal(await f.usdc.read.balanceOf([f.vault.address]), STAKE * 20n);
    assert.equal(await f.credited(pactId, [f.creator, ...accounts]), STAKE * 20n);
    for (const wallet of [f.creator, ...accounts]) await f.claim(pactId, wallet);
    assert.equal(await f.usdc.read.balanceOf([f.vault.address]), 0n);
    assert.equal(await f.usdc.read.balanceOf([f.creator.account.address]), STAKE * 50n);
    for (const account of accounts) {
      assert.equal(await f.usdc.read.balanceOf([account.address]), STAKE);
    }
    assert.ok(receipt.gasUsed < 1_500_000n, `cancel gas: ${receipt.gasUsed}`);
  });
});


describe('Pact V6 seeded adversarial lifecycle sequences',()=>{
  for(const [seedIndex,seed] of [0x140071,0x140072,0x140073].entries()) {
    it(`checks every state transition and liability for seed ${seed.toString(16)}`,async()=>{
      const f=await fixture({capacity:4}), wallets=[f.creator,f.bob,f.carol,f.dave];
      await f.fund(wallets.map(w=>w.account),30n*STAKE);
      let state=seed,donated=0n;
      const next=(max)=>{state=(Math.imul(state,1664525)+1013904223)>>>0;return state%max;};
      const domain=seedIndex%2?'working':'walking', records=new Map();
      async function invariant() {
        let liabilities=0n;
        for(const [id,model] of records) {
          const facts=await f.accounts(id,wallets),kind=await f.kind(id);
          assert.equal(facts.deposited,model.external,'rollover is not an external deposit');
          assert.equal(model.external+model.in-model.out,facts.pool+facts.reserve+facts.credited+facts.paidOut,`conservation seed=${seed} pact=${id}`);
          liabilities+=facts.pool+facts.reserve+facts.credited;
          if(model.terminal) assert.equal(kind,model.terminal,'one terminal outcome');
          if(kind) model.terminal=kind;
          assert.ok(await f.registry.read.activeParticipantCount([id])<=4n,'bounded roster');
        }
        const balance=await f.usdc.read.balanceOf([f.vault.address]);
        assert.ok(balance>=liabilities,'global outstanding liabilities');
        assert.equal(balance,liabilities+donated,'unsolicited tokens stay outside stake/credit accounting');
      }
      async function step(action){const result=await action();await invariant();return result;}
      async function create(rolloverAllowed=false,exitPenaltyBps=0){
        const created=await (domain==='walking'?f.createPact:f.createWorking)({rolloverAllowed,exitPenaltyBps,capacity:4});
        records.set(created.pactId,{external:STAKE,in:0n,out:0n,terminal:0});await invariant();return created;
      }
      async function join(pact,wallet){await f.join(pact.pactId,wallet,{domain});records.get(pact.pactId).external+=STAKE;await invariant();}
      async function claimAll(pact){
        const ordered=[...wallets];
        for(let i=ordered.length-1;i>0;i--){const j=next(i+1);[ordered[i],ordered[j]]=[ordered[j],ordered[i]];}
        for(const wallet of ordered) {
          const credit=await f.vault.read.claimable([pact.pactId,wallet.account.address]);
          if(credit) await step(()=>f.claim(pact.pactId,wallet,domain));
          await step(()=>expectError(f.claim(pact.pactId,wallet,domain),'NothingToClaim'));
        }
      }
      // create -> join -> activate -> exit -> expired authorization -> finalize -> claims.
      const active=await create(false,[0,2500,10000][seedIndex]);
      await join(active,f.bob);await join(active,f.carol);
      await step(()=>expectError(f.join(active.pactId,f.bob,{domain}),'AlreadyParticipant'));
      await step(()=>f.activate(active.pactId,f.creator));
      await f.networkHelpers.time.increaseTo(active.startsAt);
      await step(()=>f.exit(active.pactId,f.bob,domain));
      await f.networkHelpers.time.increaseTo(active.reviewClosesAt);
      const pool=await f.vault.read.unallocatedPool([active.pactId]);
      const members=[f.creator,f.carol].sort((a,b)=>a.account.address.toLowerCase()<b.account.address.toLowerCase()?-1:1);
      const allocations=members.map((w,i)=>allocation(w.account.address,pool/2n+(BigInt(i)<pool%2n?1n:0n)));
      const expired=await f.ticketFor(active.pactId,allocations,{domain,overrides:{deadline:(await f.now())-1n}});
      await step(()=>expectError(f.settle(expired,allocations,f.creator,domain),'AuthorizationExpired'));
      const ticket=await f.ticketFor(active.pactId,allocations,{domain});
      await step(()=>f.settle(ticket,allocations,f.creator,domain));
      await step(()=>expectError(f.settle(ticket,allocations,f.creator,domain),'InvalidStatus'));
      // One blocked recipient does not stop other owners from claiming their own credit.
      await step(()=>send(f.client,f.usdc.write.setRecipientBlocked([f.creator.account.address,true])));
      await step(()=>expectError(f.claim(active.pactId,f.creator,domain),'TokenTransferFailed'));
      await step(()=>f.claim(active.pactId,f.carol,domain));
      await step(()=>send(f.client,f.usdc.write.setRecipientBlocked([f.creator.account.address,false])));
      await claimAll(active);
      // Extra tokens increase backing, never stake or a financial membership.
      donated=BigInt(1+next(97));await step(()=>send(f.client,f.usdc.write.mint([f.vault.address,donated])));
      // create -> join -> leave -> cancel -> independent pull claims.
      const cancelled=await create();await join(cancelled,f.bob);await join(cancelled,f.carol);
      await step(()=>f.leave(cancelled.pactId,f.bob,domain));
      await step(()=>expectError(f.join(cancelled.pactId,f.bob,{domain}),'AlreadyParticipant'));
      await step(()=>f.cancel(cancelled.pactId,f.creator,domain));
      await step(()=>expectError(f.activate(cancelled.pactId,f.creator),'InvalidStatus'));
      await claimAll(cancelled);
      // settle -> consent/revoke -> transfer OR reject/expire -> release -> claims.
      const source=await create(true,2500);
      for(const wallet of [f.bob,f.carol,f.dave]) await join(source,wallet);
      await step(()=>f.activate(source.pactId,f.creator));await f.networkHelpers.time.increaseTo(source.startsAt);
      await step(()=>f.exit(source.pactId,f.dave,domain));await f.networkHelpers.time.increaseTo(source.reviewClosesAt);
      await step(async()=>f.settle(await f.ticketFor(source.pactId,[],{domain,overrides:{outcome:3}}),[],f.creator,domain));
      const destination=await create();await join(destination,f.bob);await join(destination,f.carol);
      await step(()=>f.approveRollover(source.pactId,destination.pactId,f.creator));
      await step(()=>expectError(f.activateWithRollover(source.pactId,destination.pactId,f.creator),'RolloverUnavailable'));
      for(const wallet of [f.bob,f.carol]) await step(()=>f.approveRollover(source.pactId,destination.pactId,wallet));
      await step(()=>f.approveRollover(source.pactId,destination.pactId,f.bob,false));
      await step(()=>expectError(f.activateWithRollover(source.pactId,destination.pactId,f.creator),'RolloverUnavailable'));
      if(seedIndex===0) {
        await step(()=>f.approveRollover(source.pactId,destination.pactId,f.bob,true));
        const moved=await f.vault.read.rolloverReserve([source.pactId]);
        // Former member's existing credit races reserve transfer; neither spends the other.
        await Promise.all([f.claim(source.pactId,f.dave,domain),f.activateWithRollover(source.pactId,destination.pactId,f.creator)]);
        records.get(source.pactId).out+=moved;records.get(destination.pactId).in+=moved;await invariant();
        await step(()=>expectError(f.activateWithRollover(source.pactId,destination.pactId,f.creator),'RolloverUnavailable'));
        await step(()=>expectError(f.releaseRollover(source.pactId),'RolloverUnavailable'));
        await f.networkHelpers.time.increaseTo(destination.settlementClosesAt);
        await step(()=>f.refund(destination.pactId,f.outsider,domain));await claimAll(destination);await claimAll(source);
      } else {
        if(seedIndex===1) await step(()=>f.rejectRollover(source.pactId,f.carol));
        else await f.networkHelpers.time.increaseTo((await f.rolloverOf(source.pactId)).deadline+1n);
        await step(()=>expectError(f.activateWithRollover(source.pactId,destination.pactId,f.creator),'RolloverUnavailable'));
        await step(()=>f.releaseRollover(source.pactId));await claimAll(source);
        await step(()=>f.cancel(destination.pactId,f.creator,domain));await claimAll(destination);
      }
      await invariant();assert.equal(await f.usdc.read.balanceOf([f.vault.address]),donated);
    });
  }
});


describe('Pact V6 long seeded roster churn',()=>{
  it('keeps custody and settlement bounded after 80 replacement cycles at the 20-member cap',{timeout:120000},async()=>{
    const f=await fixture({capacity:20}), peers=randomAccounts(99);
    await f.fund(peers);
    const created=await f.createPact({capacity:20,joinWindow:2n*DAY,startsIn:3n*DAY});
    const active=[f.creator.account];let deposits=STAKE,paid=0n,credits=0n,seed=0x140074;
    const next=(max)=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed%max;};
    async function invariant(){
      const pool=await f.vault.read.unallocatedPool([created.pactId]);
      assert.equal(await f.vault.read.deposited([created.pactId]),deposits);
      assert.equal(await f.vault.read.paidOut([created.pactId]),paid);
      assert.equal(deposits,pool+credits+paid);
      assert.equal(await f.usdc.read.balanceOf([f.vault.address]),pool+credits);
      assert.equal(await f.registry.read.activeParticipantCount([created.pactId]),BigInt(active.length));
      assert.ok(active.length<=20);
    }
    for(const peer of peers.slice(0,19)){await f.join(created.pactId,peer);active.push(peer);deposits+=STAKE;await invariant();}
    for(let cycle=0;cycle<80;cycle++) {
      const index=1+next(active.length-1),leaver=active[index];
      await f.leave(created.pactId,leaver);active.splice(index,1);credits+=STAKE;await invariant();
      const peer=peers[19+cycle];await f.join(created.pactId,peer);active.push(peer);deposits+=STAKE;await invariant();
      await f.claim(created.pactId,leaver);credits-=STAKE;paid+=STAKE;await invariant();
      if(cycle%10===0){await expectError(f.join(created.pactId,leaver),'AlreadyParticipant');await expectError(f.claim(created.pactId,leaver),'NothingToClaim');await invariant();}
    }
    const roster=await Promise.all(active.map((_,i)=>f.registry.read.settlementParticipantAt([created.pactId,BigInt(i)])));
    assert.deepEqual(new Set(roster.map(a=>a.toLowerCase())),new Set(active.map(a=>a.address.toLowerCase())));
    await f.activate(created.pactId,f.creator);await invariant();
    await f.networkHelpers.time.increaseTo(created.reviewClosesAt);
    const allocations=active.map(a=>allocation(a.address,STAKE));
    const receipt=await f.settle(await f.ticketFor(created.pactId,allocations),allocations,f.creator);
    credits=STAKE*20n;await invariant();assert.ok(receipt.gasUsed<1500000n);
    for(const member of active){await f.claim(created.pactId,member);credits-=STAKE;paid+=STAKE;await invariant();}
    assert.equal(paid,deposits);assert.equal(await f.usdc.read.balanceOf([f.vault.address]),0n);
  });
});
