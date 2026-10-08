import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { describe, it } from 'node:test';
import hre from 'hardhat';
import solc from 'solc';
import {
  encodeAbiParameters,
  getContract,
  hashDomain,
  hashTypedData,
  keccak256,
  parseEventLogs,
  toFunctionSelector,
  zeroAddress,
} from 'viem';
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts';
import { compilePactSettlementV6Artifact, assertPactSettlementV6Deployable } from '../scripts/pact-settlement-v6-artifact.mjs';

// Local EVM only. The V6 module is deliberately not deployed anywhere yet.
const compiled = compilePactSettlementV6Artifact();
const artifact = compiled.module;

const HOUR = 3_600n;
const DAY = 86_400n;
const REVIEW_WINDOW = DAY;
const SETTLEMENT_WINDOW = 3n * DAY;
const CHALLENGE_WINDOW = HOUR;
const TERMS = `0x${'11'.repeat(32)}`;
const RESULTS = `0x${'22'.repeat(32)}`;
const EVIDENCE = `0x${'33'.repeat(32)}`;
const GENERATION = `0x${'aa'.repeat(32)}`;
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
const DOMAIN_TYPES = { EIP712Domain: [
  { name: 'name', type: 'string' }, { name: 'version', type: 'string' },
  { name: 'chainId', type: 'uint256' }, { name: 'verifyingContract', type: 'address' }] };

const MOCK_SOURCE_NAMES = ['contracts/test/MockPactSettlementV6.sol', 'contracts/test/MockERC1271VerifierV6.sol',
  'contracts/src/interfaces/IPactSettlementV6.sol',
  'contracts/src/interfaces/IPactSettlementRegistryV6.sol', 'contracts/src/interfaces/IPactSettlementModuleV6.sol',
  'contracts/src/interfaces/IPactSettlementSinkV6.sol', 'contracts/src/libraries/PactTimeoutV6.sol'];
const mockSources = Object.fromEntries(MOCK_SOURCE_NAMES.map((name) => [name,
  { content: readFileSync(new URL(`../${name}`, import.meta.url), 'utf8') }]));
const mockCompilation = JSON.parse(solc.compile(JSON.stringify({ language: 'Solidity', sources: mockSources,
  settings: { evmVersion: 'cancun', viaIR: true, optimizer: { enabled: true, runs: 1 },
    outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object'] } } } })));
assert.deepEqual((mockCompilation.errors ?? []).filter(({ severity }) => severity === 'error'), []);
const mockArtifacts = Object.fromEntries(Object.values(mockCompilation.contracts).flatMap((contracts) =>
  Object.entries(contracts).map(([name, contract]) => [name,
    { abi: contract.abi, bytecode: `0x${contract.evm.bytecode.object}` }])));

const allocation = (recipient, amount) => ({ recipient, amount });
const allocationsHashOf = (allocations) =>
  keccak256(encodeAbiParameters([ALLOCATION_TUPLE], [allocations]));
const randomNonce = () => `0x${randomBytes(32).toString('hex')}`;
const windowsOf = (endAt, evidenceGrace) => [endAt + evidenceGrace,
  endAt + evidenceGrace + REVIEW_WINDOW, endAt + evidenceGrace + REVIEW_WINDOW + SETTLEMENT_WINDOW];

// Deterministic 32-bit LCG (Numerical Recipes constants) so scenario counts, splits and
// timeout windows are reproducible across runs. `Math.random` is intentionally not used.
function createPrng(seed) {
  let state = seed >>> 0;
  const next = () => (state = (Math.imul(state, 1_664_525) + 1_013_904_223) >>> 0);
  return {
    int: (maxExclusive) => next() % maxExclusive,
    between: (minInclusive, maxInclusive) => minInclusive + (next() % (maxInclusive - minInclusive + 1)),
    big: (boundExclusive) => (BigInt(next()) * 4_294_967_296n + BigInt(next())) % boundExclusive,
  };
}

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

// Splits `distributable` into `count` strictly positive amounts. The final amount absorbs
// the remainder so the total is exact by construction.
function randomAmounts(prng, distributable, count) {
  const amounts = [];
  let remaining = distributable;
  for (let index = 0; index < count; ++index) {
    const slotsLeft = count - 1 - index;
    if (slotsLeft === 0) {
      amounts.push(remaining);
      break;
    }
    const amount = 1n + prng.big(remaining - BigInt(slotsLeft));
    amounts.push(amount);
    remaining -= amount;
  }
  return amounts;
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

function event(receipt, name) {
  const [parsed] = parseEventLogs({ abi: artifact.abi, eventName: name, logs: receipt.logs });
  assert.ok(parsed, `${name} event missing from receipt`);
  return parsed.args;
}

async function fixture({ reentrantSink = false, contractVerifierOwner } = {}) {
  const connection = await hre.network.create();
  const client = await connection.viem.getPublicClient();
  const [deployer, alice, bob, carol, outsider, guardian] = await connection.viem.getWalletClients();
  const verifier = privateKeyToAccount(generatePrivateKey());
  const registry = await deploy(client, deployer, mockArtifacts.MockPactSettlementRegistryV6);
  const sink = await deploy(client, deployer, reentrantSink
    ? mockArtifacts.MockReentrantPactSettlementSinkV6
    : mockArtifacts.MockPactSettlementSinkV6);
  // The module constructor proves the registry points at its sink; the mock exposes `vault()`.
  await send(client, registry.write.setVault([sink.address]));
  const contractVerifier = contractVerifierOwner
    ? await deploy(client, deployer, mockArtifacts.MockERC1271VerifierV6, [contractVerifierOwner.address]) : null;
  const verifierAddress = contractVerifier?.address;
  const receipt = await send(client, deployer.deployContract({ abi: artifact.abi, bytecode: artifact.bytecode,
    args: [registry.address, verifierAddress ?? verifier.address, sink.address, guardian.account.address,
      Number(CHALLENGE_WINDOW)] }));
  const settlement = getContract({ address: receipt.contractAddress, abi: artifact.abi,
    client: { public: client, wallet: deployer } });
  await send(client, sink.write.setModule([settlement.address]));
  await send(client, registry.write.setGenerationId([GENERATION]));
  const chainId = await client.getChainId();
  const now = async () => BigInt(await connection.networkHelpers.time.latest());

  /** Registry-only binding, done once per Pact exactly like the real registry does at creation. */
  async function bind(pactId) {
    if ((await settlement.read.pactVerifier([pactId])) === zeroAddress) {
      await send(client, registry.write.callBindPactV6([settlement.address, pactId]));
    }
  }

  async function configure(pactId, { participants, distributable, endAt, evidenceGrace = DAY,
    termsHash = TERMS, settlementKind = 1, bound = true } = {}) {
    if (bound) await bind(pactId);
    await send(client, registry.write.setParticipants([pactId, participants]));
    await send(client, registry.write.setTerms([pactId, termsHash, endAt, evidenceGrace, distributable]));
    await send(client, registry.write.setSettlementKind([pactId, settlementKind]));
  }

  async function signed(allocations, overrides = {}, options = {}) {
    const authorization = { pactId: 1n, termsHash: TERMS, resultsHash: RESULTS, evidenceHash: EVIDENCE,
      allocationsHash: allocationsHashOf(allocations), outcome: 0, nonce: randomNonce(),
      deadline: (await now()) + HOUR, registry: registry.address, generationId: GENERATION,
      ...overrides };
    const typed = { domain: { name: 'PactSettlementModuleV6', version: '1', chainId,
      verifyingContract: settlement.address, ...options.domain }, types: AUTHORIZATION_TYPES,
    primaryType: 'SettlementAuthorization', message: authorization };
    return { authorization, signature: await (options.signer ?? verifier).signTypedData(typed),
      digest: hashTypedData(typed) };
  }

  // Outcome 0/2 splits wait out the challenge window; by default the helper finalizes them so
  // credit-level tests keep working. `finalize: false` leaves them pending.
  async function settle(ticket, allocations, wallet = deployer, { finalize = true } = {}) {
    const receipt = await send(client, registry.write.callSettleV6([settlement.address, ticket.authorization,
      allocations, ticket.signature], { account: wallet.account }));
    if (finalize) await finalizePending(ticket.authorization.pactId, allocations);
    return receipt;
  }

  async function finalizePending(pactId, allocations, wallet = outsider) {
    const [, opensAt, state] = await settlement.read.pendingPayout([pactId]);
    if (Number(state) !== 1) return null;
    if (await now() < BigInt(opensAt)) await connection.networkHelpers.time.increaseTo(BigInt(opensAt));
    return send(client, settlement.write.finalizeSettlementV6([pactId, allocations], { account: wallet.account }));
  }

  async function refund(pactId = 1n, wallet = outsider) {
    return send(client, registry.write.callRefundTimedOutV6([settlement.address, pactId],
      { account: wallet.account }));
  }

  return { ...connection, client, deployer, alice, bob, carol, outsider, guardian, verifier, registry, sink,
    settlement, chainId, now, configure, bind, signed, settle, finalizePending, refund, contractVerifier };
}

describe('Pact Settlement V6 primitives', () => {
  it('shares atomic vectors with TS and Swift, including address-sorted five-unit refunds', async () => {
    const f=await fixture();
    const vectors=JSON.parse(readFileSync(new URL('./fixtures/v6-allocation-vectors.json',import.meta.url),'utf8'));
    for(const vector of vectors) {
      const allocations=vector.expected.map(a=>allocation(a.recipient,BigInt(a.amount)));
      assert.equal(await f.settlement.read.validateAllocations([allocations,BigInt(vector.pool)]),allocationsHashOf(allocations),vector.name);
    }
    for(const [index,vector] of vectors.slice(0,3).entries()) {
      const pactId=BigInt(index+1),allocations=vector.expected.map(a=>allocation(a.recipient,BigInt(a.amount)));
      await f.configure(pactId,{participants:vector.rights.map(r=>r.recipient),distributable:BigInt(vector.pool),endAt:(await f.now())+DAY,settlementKind:1});
      await f.settle(await f.signed(allocations,{pactId}),allocations);
      for(const expected of allocations) assert.equal(await f.sink.read.credited([pactId,expected.recipient]),expected.amount,vector.name);
    }
    const dust=vectors[2];
    await f.configure(4n,{participants:dust.rights.map(r=>r.recipient),distributable:5n,endAt:(await f.now())-6n*DAY,settlementKind:2});
    await f.refund(4n);
    for(const expected of dust.expected) assert.equal(await f.sink.read.credited([4n,expected.recipient]),BigInt(expected.amount));
  });

  it('compiles a deployable module within EIP-170 and exposes the settlement surface', async () => {
    const size = assertPactSettlementV6Deployable(compiled);
    assert.ok(size > 0);
    assert.ok(compiled.sourceSha256.length === 64);

    // The module owns authorization and nonces only; the vault is the single accounting source.
    const functionNames = new Set(artifact.abi.filter((entry) => entry.type === 'function')
      .map((entry) => entry.name));
    assert.equal(functionNames.has('claimable'), false);
    assert.equal(functionNames.has('claimed'), false);
    assert.equal(functionNames.has('claim'), true);
  });

  it('conserves the exact distributable pool and hashes the ordered allocations', async () => {
    const f = await fixture();
    const allocations = [allocation(f.alice.account.address, 5_000_001n),
      allocation(f.bob.account.address, 4_999_999n)];
    const digest = await f.settlement.read.validateAllocations([allocations, 10_000_000n]);
    assert.equal(digest, allocationsHashOf(allocations));
  });

  it('rejects duplicate recipients, zero amounts, zero recipients and empty allocations', async () => {
    const f = await fixture();
    const recipient = f.alice.account.address;
    await expectError(f.settlement.read.validateAllocations([[allocation(recipient, 5n), allocation(recipient, 5n)], 10n]),
      'DuplicateRecipient');
    await expectError(f.settlement.read.validateAllocations([[allocation(recipient, 0n)], 0n]), 'InvalidAmount');
    await expectError(f.settlement.read.validateAllocations([[allocation('0x0000000000000000000000000000000000000000', 1n)], 1n]),
      'InvalidRecipient');
    await expectError(f.settlement.read.validateAllocations([[], 0n]), 'EmptyAllocations');
  });

  it('caps allocations at the participant limit and refuses a mismatched total', async () => {
    const f = await fixture();
    const over = Array.from({ length: 21 }, () => allocation(privateKeyToAccount(generatePrivateKey()).address, 1n));
    await expectError(f.settlement.read.validateAllocations([over, 21n]), 'TooManyAllocations');
    await expectError(f.settlement.read.validateAllocations([[allocation(f.bob.account.address, 9n)], 10n]),
      'AllocationTotalMismatch');
  });

  it('derives the half-open evidence/review/settlement boundaries and rejects overflow', async () => {
    const f = await fixture();
    const [evidence, review, settlement] = windowsOf(1_000n, 3_600n);
    assert.deepEqual((await f.settlement.read.settlementWindowClosesAt([1_000n, 3_600n])).map(BigInt),
      [evidence, review, settlement]);
    assert.equal(review - evidence, DAY);
    assert.equal(settlement - review, SETTLEMENT_WINDOW);
    await expectError(f.settlement.read.settlementWindowClosesAt([(2n ** 40n) - 1n, 1n]), 'InvalidTimeout');
  });

  it('refuses every authorization path without the configured registry', async () => {
    const f = await fixture();
    const allocations = [allocation(f.alice.account.address, 1n)];
    const ticket = await f.signed(allocations);
    await expectError(f.settlement.write.settleV6([ticket.authorization, allocations, ticket.signature],
      { account: f.outsider.account }), 'NotRegistry');
    await expectError(f.settlement.write.refundTimedOutV6([1n], { account: f.outsider.account }),
      'NotRegistry');
  });
});

describe('Pact Settlement V6 authorization, claims and timeout refund', () => {
  async function settledFixture() {
    const f = await fixture();
    const endAt = (await f.now()) + DAY;
    await f.configure(1n, { participants: [f.alice.account.address, f.bob.account.address],
      distributable: 10_000_000n, endAt, settlementKind: 1 });
    const allocations = [allocation(f.alice.account.address, 6_000_000n),
      allocation(f.bob.account.address, 4_000_000n)];
    const ticket = await f.signed(allocations);
    return { f, endAt, allocations, ticket };
  }

  it('settles a full EIP-712 authorization, credits claims and pays each owner once', async () => {
    const { f, allocations, ticket } = await settledFixture();
    assert.equal(await f.settlement.read.domainSeparator(), hashDomain({ domain: {
      name: 'PactSettlementModuleV6', version: '1', chainId: f.chainId,
      verifyingContract: f.settlement.address }, types: DOMAIN_TYPES }));
    assert.equal(await f.settlement.read.settlementDigest([ticket.authorization]), ticket.digest);

    const receipt = await f.settle(ticket, allocations);
    assert.equal(await f.sink.read.credited([1n, f.alice.account.address]), 6_000_000n);
    assert.equal(await f.sink.read.credited([1n, f.bob.account.address]), 4_000_000n);
    assert.equal(await f.sink.read.payoutCallCount(), 2n);
    assert.equal(await f.settlement.read.consumedNonce([1n, ticket.authorization.nonce]), true);
    const settled = event(receipt, 'SettledV6');
    assert.equal(settled.pactId, 1n);
    assert.equal(settled.verifier.toLowerCase(), f.verifier.address.toLowerCase());
    assert.equal(settled.authorizationDigest, ticket.digest);
    assert.equal(settled.termsHash, TERMS.toLowerCase());
    assert.equal(settled.allocationsHash, ticket.authorization.allocationsHash);
    assert.equal(settled.nonce, ticket.authorization.nonce);
    assert.equal(settled.outcome, 0);
    assert.equal(settled.distributable, 10_000_000n);

    const firstClaim = await send(f.client, f.settlement.write.claim([1n], { account: f.alice.account }));
    assert.equal(await f.sink.read.claimedTotal([1n, f.alice.account.address]), 6_000_000n);
    assert.equal(await f.sink.read.credited([1n, f.alice.account.address]), 0n);
    const claimEvent = event(firstClaim, 'ClaimV6');
    assert.equal(claimEvent.recipient.toLowerCase(), f.alice.account.address.toLowerCase());
    assert.equal(claimEvent.amount, 6_000_000n);
    assert.equal(claimEvent.refundPath, false);

    await expectError(f.settlement.write.claim([1n], { account: f.alice.account }), 'NothingToClaim');
    await expectError(f.settlement.write.claim([1n], { account: f.carol.account }), 'NothingToClaim');
    await send(f.client, f.settlement.write.claim([1n], { account: f.bob.account }));
    assert.equal(await f.sink.read.claimedTotal([1n, f.bob.account.address]), 4_000_000n);
    assert.equal(await f.sink.read.claimCallCount(), 2n);
  });

  it('requires the registry to report Settled and consumes each nonce once', async () => {
    const { f, allocations, ticket } = await settledFixture();
    const openAllocations = [allocation(f.alice.account.address, 10_000_000n)];
    await f.configure(2n, { participants: [f.alice.account.address], distributable: 10_000_000n,
      endAt: (await f.now()) + DAY, settlementKind: 0 });
    await expectError(f.settle(await f.signed(openAllocations, { pactId: 2n }), openAllocations),
      'UnexpectedSettlementKind');

    await f.settle(ticket, allocations, f.deployer, { finalize: false });
    await expectError(f.settle(ticket, allocations, f.deployer, { finalize: false }), 'NonceAlreadyConsumed');
    await f.finalizePending(1n, allocations);
    assert.equal(await f.sink.read.credited([1n, f.alice.account.address]), 6_000_000n);
  });

  it('rejects verifier, domain, message and signature tampering', async () => {
    const { f, allocations } = await settledFixture();
    const impostor = privateKeyToAccount(generatePrivateKey());
    await expectError(f.settle(await f.signed(allocations, {}, { signer: impostor }), allocations),
      'InvalidVerifierSignature');
    await expectError(f.settle(await f.signed(allocations, {}, { domain: { chainId: 999n } }), allocations),
      'InvalidVerifierSignature');
    await expectError(f.settle(await f.signed(allocations, {},
      { domain: { verifyingContract: f.registry.address } }), allocations), 'InvalidVerifierSignature');

    const untouched = await f.signed(allocations);
    await expectError(f.settle({ ...untouched, authorization: {
      ...untouched.authorization, resultsHash: `0x${'44'.repeat(32)}` } }, allocations),
    'InvalidVerifierSignature');
    await expectError(f.settle({ ...untouched, authorization: {
      ...untouched.authorization, evidenceHash: `0x${'55'.repeat(32)}` } }, allocations),
    'InvalidVerifierSignature');
    await expectError(f.settle({ ...untouched,
      signature: `${untouched.signature.slice(0, -2)}00` }, allocations), 'InvalidVerifierSignature');
    await expectError(f.settle({ ...untouched, signature: '0x1234' }, allocations), 'InvalidVerifierSignature');

    await expectError(f.settle(await f.signed(allocations,
      { termsHash: `0x${'66'.repeat(32)}` }), allocations), 'TermsHashMismatch');
    await expectError(f.settle(await f.signed(allocations,
      { generationId: `0x${'77'.repeat(32)}` }), allocations), 'GenerationMismatch');
    await expectError(f.settle(await f.signed(allocations,
      { registry: f.outsider.account.address }), allocations), 'RegistryMismatch');
    await expectError(f.settle(await f.signed(allocations,
      { allocationsHash: `0x${'88'.repeat(32)}` }), allocations), 'AllocationsHashMismatch');
    await expectError(f.settle(await f.signed(allocations, { deadline: (await f.now()) - 1n }), allocations),
      'AuthorizationExpired');
  });

  it('requires exact allocations to active participants', async () => {
    const { f } = await settledFixture();
    await expectError(f.settle(await f.signed([allocation(f.alice.account.address, 9n)]),
      [allocation(f.alice.account.address, 9n)]), 'AllocationTotalMismatch');
    await expectError(f.settle(await f.signed([allocation(f.alice.account.address, 5n),
      allocation(f.alice.account.address, 5n)]),
    [allocation(f.alice.account.address, 5n), allocation(f.alice.account.address, 5n)]), 'DuplicateRecipient');
    await expectError(f.settle(await f.signed([allocation(f.alice.account.address, 0n)]),
      [allocation(f.alice.account.address, 0n)]), 'InvalidAmount');
    await expectError(f.settle(await f.signed([allocation('0x0000000000000000000000000000000000000000', 1n)]),
      [allocation('0x0000000000000000000000000000000000000000', 1n)]), 'InvalidRecipient');
    await expectError(f.settle(await f.signed([allocation(f.alice.account.address, 6_000_000n),
      allocation(f.carol.account.address, 4_000_000n)]),
    [allocation(f.alice.account.address, 6_000_000n), allocation(f.carol.account.address, 4_000_000n)]),
    'InvalidParticipant');
    const over = Array.from({ length: 21 }, () => allocation(privateKeyToAccount(generatePrivateKey()).address, 1n));
    await expectError(f.settle(await f.signed(over), over), 'TooManyAllocations');
  });

  it('accepts an outcome-3 rollover authorization with no allocations and consumes the nonce', async () => {
    const f = await fixture();
    const endAt = (await f.now()) + DAY;
    await f.configure(1n, { participants: [f.alice.account.address, f.bob.account.address],
      distributable: 10_000_000n, endAt, settlementKind: 1 });
    const ticket = await f.signed([], { outcome: 3 });
    const receipt = await f.settle(ticket, []);
    assert.equal(event(receipt, 'SettledV6').outcome, 3);
    assert.equal(event(receipt, 'SettledV6').distributable, 10_000_000n);
    assert.equal(await f.settlement.read.consumedNonce([1n, ticket.authorization.nonce]), true);
    // The reserve move is the registry's job: the module itself credits nothing.
    assert.equal(await f.sink.read.payoutCallCount(), 0n);
    assert.equal(await f.sink.read.refundPayoutCallCount(), 0n);

    const withAllocations = [allocation(f.alice.account.address, 10_000_000n)];
    await expectError(f.settle(await f.signed(withAllocations, { outcome: 3 }), withAllocations),
      'NonEmptyRolloverAllocations');
    const tampered = await f.signed([], { outcome: 3, allocationsHash: `0x${'99'.repeat(32)}` });
    await expectError(f.settle(tampered, []), 'AllocationsHashMismatch');
  });

  it('refunds with a deterministic split only through the registry and the terminal kind', async () => {
    const f = await fixture();
    const endAt = (await f.now()) + 60n;
    await f.configure(1n, { participants: [f.alice.account.address, f.bob.account.address,
      f.carol.account.address], distributable: 10n, endAt, evidenceGrace: 60n, settlementKind: 2 });
    const [, reviewClosesAt, settlementClosesAt] = windowsOf(endAt, 60n);
    await expectError(f.refund(1n, f.outsider), 'TimeoutNotReached');
    assert.equal(reviewClosesAt, endAt + 60n + DAY);

    await f.networkHelpers.time.setNextBlockTimestamp(settlementClosesAt - 1n);
    await expectError(f.refund(1n, f.outsider), 'TimeoutNotReached');
    await f.networkHelpers.time.setNextBlockTimestamp(settlementClosesAt);
    const receipt = await f.refund(1n, f.outsider);
    const sorted=[f.alice,f.bob,f.carol].sort((a,b)=>a.account.address.toLowerCase()<b.account.address.toLowerCase()?-1:1);
    for(const [index,member] of sorted.entries()) assert.equal(await f.sink.read.credited([1n,member.account.address]),index===0?4n:3n);
    const refundEvent = event(receipt, 'RefundTimedOutV6');
    assert.equal(refundEvent.pactId, 1n);
    assert.equal(refundEvent.participantCount, 3n);
    assert.equal(refundEvent.distributable, 10n);

    const claimReceipt = await send(f.client, f.settlement.write.claim([1n], { account: f.alice.account }));
    assert.equal(event(claimReceipt, 'ClaimV6').refundPath, true);
    assert.equal(await f.sink.read.claimedTotal([1n, f.alice.account.address]), sorted[0]===f.alice?4n:3n);
    assert.equal(await f.sink.read.payoutCallCount(), 0n);
    await expectError(f.settlement.write.claim([1n], { account: f.alice.account }), 'NothingToClaim');
  });

  it('requires the registry to report Refunded before any refund split is credited', async () => {
    const f = await fixture();
    const past = 1n;
    await f.configure(1n, { participants: [f.alice.account.address, f.bob.account.address],
      distributable: 2n, endAt: past, settlementKind: 1 });
    await expectError(f.refund(1n), 'UnexpectedSettlementKind');
    await f.configure(1n, { participants: [f.alice.account.address, f.bob.account.address],
      distributable: 2n, endAt: past, settlementKind: 3 });
    await expectError(f.refund(1n), 'UnexpectedSettlementKind');
    await f.configure(1n, { participants: [f.alice.account.address, f.bob.account.address],
      distributable: 2n, endAt: past, settlementKind: 2 });
    await f.refund(1n, f.outsider);
    assert.equal(await f.sink.read.credited([1n, f.alice.account.address]), 1n);
    assert.equal(await f.sink.read.credited([1n, f.bob.account.address]), 1n);
  });

  it('rejects unrepresentable refunds and non-canonical participant lists', async () => {
    const f = await fixture();
    const past = { endAt: 1n, evidenceGrace: 1n, settlementKind: 2 };
    await f.configure(1n, { participants: [f.alice.account.address, f.bob.account.address,
      f.carol.account.address], distributable: 2n, ...past });
    await expectError(f.refund(1n), 'RefundNotRepresentable');
    await f.configure(1n, { participants: [], distributable: 0n, ...past });
    await expectError(f.refund(1n), 'RefundNotRepresentable');
    const many = Array.from({ length: 21 }, () => privateKeyToAccount(generatePrivateKey()).address);
    await f.configure(1n, { participants: many, distributable: 21n, ...past });
    await expectError(f.refund(1n), 'RefundParticipantLimitExceeded');
    await f.configure(1n, { participants: [f.alice.account.address,
      '0x0000000000000000000000000000000000000000'], distributable: 2n, ...past });
    await expectError(f.refund(1n), 'InvalidRefundRecipient');
    await f.configure(1n, { participants: [f.alice.account.address, f.alice.account.address],
      distributable: 2n, ...past });
    await expectError(f.refund(1n), 'InvalidRefundRecipient');
  });

  it('rejects direct custody mutation and blocks reentrant claims through the module lock', async () => {
    const f = await fixture({ reentrantSink: true });
    await expectError(f.sink.write.payout([1n, f.alice.account.address, 1n], { account: f.outsider.account }),
      'NotModule');

    const endAt = (await f.now()) + DAY;
    await f.configure(1n, { participants: [f.alice.account.address, f.bob.account.address],
      distributable: 10_000_000n, endAt, settlementKind: 1 });
    const allocations = [allocation(f.alice.account.address, 6_000_000n),
      allocation(f.bob.account.address, 4_000_000n)];
    await f.settle(await f.signed(allocations), allocations);

    await send(f.client, f.settlement.write.claim([1n], { account: f.alice.account }));
    assert.equal(await f.sink.read.reentered(), false);
    assert.equal(await f.sink.read.reentrySelector(), toFunctionSelector('ReentrantCall()'));
    assert.equal(await f.sink.read.claimedTotal([1n, f.alice.account.address]), 6_000_000n);
    assert.equal(await f.sink.read.claimCallCount(), 1n);
  });
});

describe('Pact Settlement V6 randomized invariants and gas envelope', () => {
  it('conserves every randomly split pool across 25 settlement scenarios', async () => {
    const f = await fixture();
    const prng = createPrng(0x5e77_0001);
    let expectedPayoutCalls = await f.sink.read.payoutCallCount();

    for (let scenario = 0; scenario < 25; ++scenario) {
      const pactId = BigInt(scenario + 1);
      const count = scenario === 0 ? 1 : scenario === 1 ? 20 : prng.between(1, 20);
      const accounts = randomAccounts(count);
      await Promise.all(accounts.map((account) => f.networkHelpers.setBalance(account.address, 10n ** 18n)));

      const distributable = 1_000_000n + prng.big(9_000_000n);
      const amounts = randomAmounts(prng, distributable, count);
      const allocations = accounts.map((account, index) => allocation(account.address, amounts[index]));
      await f.configure(pactId, { participants: accounts.map((account) => account.address), distributable,
        endAt: (await f.now()) + DAY, settlementKind: 1 });
      const ticket = await f.signed(allocations, { pactId });

      const victim = prng.int(count);
      const bumped = allocations.map((entry, index) => index === victim
        ? allocation(entry.recipient, entry.amount + 1n) : entry);
      const duplicated = allocations.map((entry) => ({ ...entry }));
      if (count >= 2) duplicated[1] = allocation(duplicated[0].recipient, duplicated[1].amount);
      else duplicated.push(allocation(duplicated[0].recipient, 1n));
      const zeroed = allocations.map((entry, index) => index === victim
        ? allocation(entry.recipient, 0n) : entry);
      await expectError(f.settlement.read.validateAllocations([bumped, distributable]), 'AllocationTotalMismatch');
      await expectError(f.settlement.read.validateAllocations([duplicated, distributable]), 'DuplicateRecipient');
      await expectError(f.settlement.read.validateAllocations([zeroed, distributable]), 'InvalidAmount');
      await expectError(f.settle(ticket, [bumped, duplicated, zeroed][scenario % 3]),
        ['AllocationTotalMismatch', 'DuplicateRecipient', 'InvalidAmount'][scenario % 3]);

      const receipt = await f.settle(ticket, allocations);
      assert.equal(event(receipt, 'SettledV6').distributable, distributable);
      assert.equal(await f.settlement.read.consumedNonce([pactId, ticket.authorization.nonce]), true);
      for (let index = 0; index < count; ++index) {
        assert.equal(await f.sink.read.credited([pactId, accounts[index].address]), amounts[index]);
      }

      const claimReceipts = await Promise.all(accounts.map((account) =>
        send(f.client, f.settlement.write.claim([pactId], { account }))));
      let paid = 0n;
      for (let index = 0; index < count; ++index) {
        assert.equal(event(claimReceipts[index], 'ClaimV6').refundPath, false);
        assert.equal(event(claimReceipts[index], 'ClaimV6').amount, amounts[index]);
        assert.equal(await f.sink.read.claimedTotal([pactId, accounts[index].address]), amounts[index]);
        assert.equal(await f.sink.read.credited([pactId, accounts[index].address]), 0n);
        paid += amounts[index];
      }
      await Promise.all(accounts.map((account) =>
        expectError(f.settlement.write.claim([pactId], { account }), 'NothingToClaim')));
      assert.equal(paid, distributable);
      expectedPayoutCalls += BigInt(count);
      assert.equal(await f.sink.read.payoutCallCount(), expectedPayoutCalls);
      assert.equal(await f.sink.read.refundPayoutCallCount(), 0n);
    }
  });

  it('splits every randomized timeout refund in numeric address order with no stranded unit', async () => {
    const f = await fixture();
    const prng = createPrng(0x11f0_0002);
    let expectedRefundCalls = await f.sink.read.refundPayoutCallCount();
    let sawExact = false;
    let sawRemainder = false;
    let sawOrderSensitiveShuffle = false;

    for (let scenario = 0; scenario < 25; ++scenario) {
      const pactId = BigInt(scenario + 1);
      const count = scenario === 0 ? 1 : scenario === 1 ? 20 : prng.between(1, 20);
      const accounts = randomAccounts(count);
      // Scenario 1 pins count=20 and remainder=1 in descending address order so the +1 unit
      // provably follows ascending address order rather than the shuffled registry roster.
      if (scenario === 1) {
        accounts.sort((left, right) => left.address.toLowerCase() < right.address.toLowerCase() ? 1 : -1);
      }
      await Promise.all(accounts.map((account) => f.networkHelpers.setBalance(account.address, 10n ** 18n)));

      const distributable = scenario === 0 ? BigInt(count)
        : scenario === 1 ? BigInt(count) + 1n
        : BigInt(count) + prng.big(BigInt(3 * count + 1));
      const endAt = (await f.now()) + BigInt(prng.between(5, 120));
      const evidenceGrace = BigInt(prng.between(0, 60));
      await f.configure(pactId, { participants: accounts.map((account) => account.address), distributable,
        endAt, evidenceGrace, settlementKind: 2 });
      const [, , settlementClosesAt] = windowsOf(endAt, evidenceGrace);
      await expectError(f.refund(pactId, f.outsider), 'TimeoutNotReached');

      const base = distributable / BigInt(count);
      const remainder = distributable % BigInt(count);
      if (remainder === 0n) sawExact = true;
      if (remainder > 0n) sawRemainder = true;
      const numericOrder = [...accounts].sort((a,b)=>a.address.toLowerCase()<b.address.toLowerCase()?-1:1);
      const dustOwners = new Set(numericOrder.slice(0,Number(remainder)).map(a=>a.address.toLowerCase()));
      const expected = accounts.map(a => base + (dustOwners.has(a.address.toLowerCase()) ? 1n : 0n));
      for (let index = 0; index < count; ++index) {
        assert.equal((await f.registry.read.settlementParticipantAt([pactId, BigInt(index)])).toLowerCase(),
          accounts[index].address.toLowerCase());
      }
      await f.networkHelpers.time.increaseTo(settlementClosesAt);
      const receipt = await f.refund(pactId, f.outsider);
      const refundEvent = event(receipt, 'RefundTimedOutV6');
      assert.equal(refundEvent.pactId, pactId);
      assert.equal(refundEvent.participantCount, BigInt(count));
      assert.equal(refundEvent.distributable, distributable);
      if (remainder > 0n) {
        const sortedFirst = [...accounts]
          .sort((left, right) => left.address.toLowerCase() < right.address.toLowerCase() ? -1 : 1)
          .slice(0, Number(remainder)).map((account) => account.address.toLowerCase());
        const configured = new Set(accounts.slice(0, Number(remainder))
          .map((account) => account.address.toLowerCase()));
        if (sortedFirst.some((address) => !configured.has(address))) {
          sawOrderSensitiveShuffle = true;
          for (const address of sortedFirst) {
            if (!configured.has(address)) assert.equal(await f.sink.read.credited([pactId, address]), base + 1n);
          }
        }
      }

      for (let index = 0; index < count; ++index) {
        assert.equal(await f.sink.read.credited([pactId, accounts[index].address]), expected[index]);
      }
      const claimReceipts = await Promise.all(accounts.map((account) =>
        send(f.client, f.settlement.write.claim([pactId], { account }))));
      let paid = 0n;
      for (let index = 0; index < count; ++index) {
        const claimEvent = event(claimReceipts[index], 'ClaimV6');
        assert.equal(claimEvent.refundPath, true);
        assert.equal(claimEvent.amount, expected[index]);
        assert.equal(await f.sink.read.claimedTotal([pactId, accounts[index].address]), expected[index]);
        paid += expected[index];
      }
      await Promise.all(accounts.map((account) =>
        expectError(f.settlement.write.claim([pactId], { account }), 'NothingToClaim')));
      assert.equal(paid, distributable);
      expectedRefundCalls += BigInt(count);
      assert.equal(await f.sink.read.refundPayoutCallCount(), expectedRefundCalls);
    }
    assert.ok(sawExact && sawRemainder);
    assert.ok(sawOrderSensitiveShuffle);
  });

  it('binds settlement, refund and claim gas for the 20 participant maximum', async () => {
    const f = await fixture();
    const accounts = randomAccounts(20);
    await Promise.all(accounts.map((account) => f.networkHelpers.setBalance(account.address, 10n ** 18n)));
    const participants = accounts.map((account) => account.address);
    const perHead = 1_000_000n;
    const distributable = perHead * 20n;
    await f.configure(1n, { participants, distributable, endAt: (await f.now()) + DAY, settlementKind: 1 });
    const allocations = accounts.map((account) => allocation(account.address, perHead));
    const settleGas = (await f.settle(await f.signed(allocations), allocations)).gasUsed;

    await f.configure(2n, { participants, distributable, endAt: 1n, evidenceGrace: 1n, settlementKind: 2 });
    const refundGas = (await f.refund(2n, f.outsider)).gasUsed;
    const claimGas = (await send(f.client, f.settlement.write.claim([1n],
      { account: accounts[0] }))).gasUsed;

    // Measured locally with the prototype compiler profile (optimizer runs=1, cancun) via the
    // mock registry path. The bounds leave generous headroom so the 20-participant cap is
    // proven to stay well inside the gas envelope.
    assert.ok(settleGas < 1_500_000n, `settleV6 gas at 20 participants: ${settleGas}`);
    assert.ok(refundGas < 1_600_000n, `refundTimedOutV6 gas at 20 participants: ${refundGas}`);
    assert.ok(claimGas < 150_000n, `claim gas: ${claimGas}`);
  });
});

describe('Pact Settlement V6 outcome range, binding and guardian levers', () => {
  it('refuses any outcome above 3 and accepts every evaluator code', async () => {
    const f = await fixture();
    const endAt = (await f.now()) + DAY;
    const members = [f.alice.account.address, f.bob.account.address];
    const allocations = [allocation(members[0], 6_000_000n), allocation(members[1], 4_000_000n)];
    for (const [pactId, outcome] of [[11n, 4], [12n, 255]]) {
      await f.configure(pactId, { participants: members, distributable: 10_000_000n, endAt });
      await expectError(f.settle(await f.signed(allocations, { pactId, outcome }), allocations), 'InvalidOutcome');
    }
    // Outcomes 1 (refund) and 2 (fallback) must be equal splits in ascending address order;
    // an unequal split under those codes is refused, outcome 0 stays free-form.
    const sorted = [...members].sort((a, b) => (BigInt(a) < BigInt(b) ? -1 : 1));
    const equal = [allocation(sorted[0], 5_000_000n), allocation(sorted[1], 5_000_000n)];
    for (const [pactId, outcome] of [[15n, 1], [16n, 2]]) {
      await f.configure(pactId, { participants: members, distributable: 10_000_000n, endAt });
      await expectError(f.settle(await f.signed(allocations, { pactId, outcome }), allocations), 'OutcomeAllocationMismatch');
      const reversed = [...equal].reverse();
      await expectError(f.settle(await f.signed(reversed, { pactId, outcome }), reversed), 'OutcomeAllocationMismatch');
    }
    await f.configure(17n, { participants: members, distributable: 10_000_000n, endAt });
    const partial = [allocation(sorted[0], 10_000_000n)];
    await expectError(f.settle(await f.signed(partial, { pactId: 17n, outcome: 1 }), partial), 'OutcomeAllocationMismatch');
    // A one-recipient fallback (sole closest member) is an equal split of one.
    const sole = await f.settle(await f.signed(partial, { pactId: 17n, outcome: 2 }), partial);
    assert.equal(event(sole, 'SettledV6').outcome, 2);
    for (const [pactId, outcome] of [[13n, 1], [14n, 2]]) {
      await f.configure(pactId, { participants: members, distributable: 10_000_000n, endAt });
      const receipt = await f.settle(await f.signed(equal, { pactId, outcome }), equal);
      assert.equal(event(receipt, 'SettledV6').outcome, outcome);
    }
    assert.equal(await f.settlement.read.MAX_OUTCOME(), 3);
  });

  it('binds once per Pact, only from the registry, and refuses settlement of an unbound Pact', async () => {
    const f = await fixture();
    const endAt = (await f.now()) + DAY;
    const members = [f.alice.account.address, f.bob.account.address];
    const allocations = [allocation(members[0], 10_000_000n)];
    await f.configure(1n, { participants: members, distributable: 10_000_000n, endAt, bound: false });
    assert.equal(await f.settlement.read.pactVerifier([1n]), zeroAddress);
    await expectError(f.settle(await f.signed(allocations), allocations), 'PactNotBound');
    await expectError(f.settlement.write.bindPactV6([1n], { account: f.outsider.account }), 'NotRegistry');
    await expectError(f.settlement.write.bindPactV6([1n], { account: f.guardian.account }), 'NotRegistry');
    const bound = await send(f.client, f.registry.write.callBindPactV6([f.settlement.address, 1n]));
    assert.equal(event(bound, 'PactBoundV6').verifier, f.verifier.address);
    assert.equal(await f.settlement.read.pactVerifier([1n]), f.verifier.address);
    await expectError(f.registry.write.callBindPactV6([f.settlement.address, 1n]), 'PactAlreadyBound');
    await f.settle(await f.signed(allocations), allocations);
  });

  it('pauses binding and settlement but never the timeout refund or claims', async () => {
    const f = await fixture();
    const endAt = (await f.now()) + DAY;
    const members = [f.alice.account.address, f.bob.account.address];
    const allocations = [allocation(members[0], 6_000_000n), allocation(members[1], 4_000_000n)];
    await f.configure(1n, { participants: members, distributable: 10_000_000n, endAt });
    await f.configure(2n, { participants: members, distributable: 10_000_000n, endAt, settlementKind: 2 });
    await expectError(f.settlement.write.pauseSettlement([true], { account: f.outsider.account }), 'NotGuardian');
    const paused = await send(f.client, f.settlement.write.pauseSettlement([true], { account: f.guardian.account }));
    assert.equal(event(paused, 'SettlementPausedV6').paused, true);
    assert.equal(await f.settlement.read.settlementPaused(), true);

    await expectError(f.settle(await f.signed(allocations), allocations), 'SettlementPaused');
    await expectError(f.registry.write.callBindPactV6([f.settlement.address, 3n]), 'SettlementPaused');
    // The escape hatch keeps working while paused: deterministic refund, then claims.
    await f.networkHelpers.time.increase(DAY + REVIEW_WINDOW + SETTLEMENT_WINDOW + 2n * DAY);
    const refunded = await f.refund(2n);
    assert.equal(event(refunded, 'RefundTimedOutV6').participantCount, 2n);
    await send(f.client, f.settlement.write.claim([2n], { account: f.alice.account }));
    assert.equal(await f.sink.read.claimedTotal([2n, f.alice.account.address]), 5_000_000n);

    await send(f.client, f.settlement.write.pauseSettlement([false], { account: f.guardian.account }));
    await send(f.client, f.registry.write.callBindPactV6([f.settlement.address, 3n]));
    assert.equal(await f.settlement.read.pactVerifier([3n]), f.verifier.address);
  });

  it('revokes a pinned verifier for its Pacts and refuses new bindings to a revoked key', async () => {
    const f = await fixture();
    const endAt = (await f.now()) + DAY;
    const members = [f.alice.account.address, f.bob.account.address];
    const allocations = [allocation(members[0], 10_000_000n)];
    await f.configure(1n, { participants: members, distributable: 10_000_000n, endAt });
    await expectError(f.settlement.write.setVerifierRevoked([f.verifier.address, true],
      { account: f.outsider.account }), 'NotGuardian');
    await expectError(f.settlement.write.setVerifierRevoked([zeroAddress, true],
      { account: f.guardian.account }), 'InvalidConfiguration');
    const revoked = await send(f.client, f.settlement.write.setVerifierRevoked([f.verifier.address, true],
      { account: f.guardian.account }));
    assert.deepEqual(event(revoked, 'VerifierRevokedV6'), { verifier: f.verifier.address, revoked: true });
    assert.equal(await f.settlement.read.revokedVerifier([f.verifier.address]), true);

    await expectError(f.settle(await f.signed(allocations), allocations), 'VerifierRevoked');
    await expectError(f.registry.write.callBindPactV6([f.settlement.address, 2n]), 'VerifierRevoked');

    await send(f.client, f.settlement.write.setVerifierRevoked([f.verifier.address, false],
      { account: f.guardian.account }));
    await f.settle(await f.signed(allocations), allocations);
    assert.equal(await f.sink.read.credited([1n, members[0]]), 10_000_000n);
  });

  it('has an immutable verifier and no rotation surface', async () => {
    const f = await fixture();
    assert.equal(await f.settlement.read.verifier(), f.verifier.address);
    for (const name of ['proposeVerifier', 'applyVerifier', 'cancelVerifierProposal', 'pendingVerifier',
      'pendingVerifierAppliesAt', 'VERIFIER_ROTATION_DELAY']) {
      assert.equal(artifact.abi.some((item) => item.name === name), false, `${name} must not exist`);
    }
    assert.equal(await f.settlement.read.challengeWindow(), Number(CHALLENGE_WINDOW));
  });

  it('accepts an EIP-1271 contract verifier and rejects a wrong magic value', async () => {
    const owner = privateKeyToAccount(generatePrivateKey());
    const f = await fixture({ contractVerifierOwner: owner });
    const { contractVerifier } = f;

    const endAt = (await f.now()) + DAY;
    const members = [f.alice.account.address, f.bob.account.address];
    const allocations = [allocation(members[0], 4_000_000n), allocation(members[1], 6_000_000n)];
    await f.configure(1n, { participants: members, distributable: 10_000_000n, endAt });
    assert.equal((await f.settlement.read.pactVerifier([1n])).toLowerCase(), contractVerifier.address.toLowerCase());

    await expectError(f.settle(await f.signed(allocations), allocations), 'InvalidVerifierSignature');
    await send(f.client, contractVerifier.write.setBroken([true]));
    await expectError(f.settle(await f.signed(allocations, {}, { signer: owner }), allocations), 'InvalidVerifierSignature');
    await send(f.client, contractVerifier.write.setBroken([false]));
    const receipt = await f.settle(await f.signed(allocations, {}, { signer: owner }), allocations);
    assert.equal(event(receipt, 'SettledV6').verifier.toLowerCase(), contractVerifier.address.toLowerCase());
    assert.equal(await f.sink.read.credited([1n, members[1]]), 6_000_000n);
  });

  it('refuses to construct against a codeless registry, a foreign sink or a guardian that is the verifier', async () => {
    const f = await fixture();
    const attempt = (args) => assert.rejects(send(f.client, f.deployer.deployContract({ abi: artifact.abi,
      bytecode: artifact.bytecode, args })));
    const verifier = f.verifier.address, guardian = f.guardian.account.address;
    const window = Number(CHALLENGE_WINDOW);
    await attempt([f.outsider.account.address, verifier, f.sink.address, guardian, window]);
    await attempt([f.registry.address, verifier, f.outsider.account.address, guardian, window]);
    await attempt([f.registry.address, verifier, f.sink.address, verifier, window]);
    await attempt([f.registry.address, verifier, f.sink.address, zeroAddress, window]);
    // The challenge window is bounded to [1 h, 7 d].
    for (const bad of [0, 3_599, 7 * 86_400 + 1]) await attempt([f.registry.address, verifier, f.sink.address, guardian, bad]);
    for (const good of [3_600, 86_400, 7 * 86_400]) {
      const receipt = await send(f.client, f.deployer.deployContract({ abi: artifact.abi, bytecode: artifact.bytecode,
        args: [f.registry.address, verifier, f.sink.address, guardian, good] }));
      assert.ok(receipt.contractAddress);
    }
  });
});
