# Pact contracts (V6)

Solidity contracts behind [Pact](https://pactside.com), an iPhone and Mac app for keeping
commitments with friends. Friends agree on a goal, each puts a small stake into a shared pool,
and the pool is split by the result when the Pact ends.

> **Status: unaudited prototype, Avalanche Fuji testnet only.** These contracts have not had
> an independent security review. They are deployed only on Fuji and hold test USDC only. Do
> not use them with real funds. The constructors accept Fuji (43113), Avalanche C-Chain
> (43114) and a local test chain (31337); a mainnet deployment would need an explicit owner
> decision and an independent audit first, and neither has happened.
>
> **The sources here are exactly what runs on Fuji.** Some code comments are out of date. They
> are left unchanged on purpose. See [Source comments](#source-comments).

## How a Pact works on-chain

App users never see a wallet, gas or a chain. They sign in with a passkey, and their passkey
smart account sends sponsored transactions for them. Underneath:

1. **Create.** The creator opens a Walking Pact (a daily step goal) or a Working Pact (focus
   time protected on iPhone and Mac) and deposits their stake. Terms, dates and the stake
   amount are fixed at creation, and the Pact is pinned to its settlement module's verifier.
2. **Join.** Joining is invite-only. Each joiner needs an EIP-712 `InvitePermit` signed by that
   Pact's invite signer. The creator can rotate the signer, which cancels every outstanding
   invite, and can block recipients while recruiting. Until the Pact is activated, every member
   except the creator can leave and get the full stake back.
3. **Activate.** Activation closes recruitment. The creator can activate at any time before the
   activation deadline. Once recruitment is closed (the join deadline has passed or the Pact is
   full), anyone can activate it, so Pacts start on their own. If the activation deadline
   passes, anyone can cancel the Pact and every participant gets a full refund. A Pact whose
   verifier has been revoked cannot be activated. An exit before the start date is free, and if
   it leaves fewer than two members the Pact is cancelled with a full refund.
4. **Settle.** Results come from on-device evidence (Apple Health steps, or iPhone and Mac focus
   protection) and are evaluated off-chain. The outcome is submitted as an EIP-712
   `SettlementAuthorization` signed by the module's verifier key. Anyone can submit it: the
   outcome and every amount come from the signed message, never from the sender. The contracts
   check the signature, the settlement window, the outcome shape and the allocations:
   recipients must be active participants, with no duplicates, and the amounts must add up
   exactly to the pool.
5. **Challenge window.** A split that pays by result (outcome 0, performance; outcome 2, closest
   wins) is not paid at once. It is recorded as pending for 24 hours. After that, anyone can call
   `finalizeSettlementV6` with the exact signed allocations to credit it. Until then, the
   guardian can veto it (see [Guardian](#guardian-incident-key)). A refund outcome (outcome 1) is
   credited at once, because it must already be the equal split a veto would produce.
6. **Pay out.** A participant can `claim` their own credit, or anyone can call
   `claimTo(pactId, recipient)`, which pays that recipient's credit to the recipient and no one
   else.
7. **Timeout.** If no valid settlement arrives before the settlement window closes, anyone can
   trigger the timeout refund: the pool is split equally across the active members.

Walking Pacts can also roll the pool into a successor Pact, but only if every participant
consents. Starting a Pact with a rolled-over pool stays creator-only.

Because activation, settlement, finalization, refunds and payouts are open to any caller, Pact
runs a server keeper that performs them on time, so nobody has to come back to press a button.
The keeper holds no special rights: it can only do what any address could do, and it cannot
change who is paid or how much.

## Contracts

| Contract | Role |
|---|---|
| [`PactRegistryV6`](contracts/src/PactRegistryV6.sol) | Owns the Pact lifecycle: create, join, leave, exit, activate, cancel, settle, refund, rollover. Every state transition happens here. |
| [`PactVaultV6`](contracts/src/PactVaultV6.sol) | Holds the ERC-20 stakes and is the only accounting ledger: pool, rollover reserve, claimable credits, commission, payouts. |
| [`PactSettlementModuleV6`](contracts/src/PactSettlementModuleV6.sol) | Verifies verifier authorizations, enforces outcome shapes, holds pending splits for the challenge window, exposes the guardian levers and turns allocations into vault credits. Deployed twice, once for Walking and once for Working Pacts. |
| [`PactAllocationsV6`](contracts/src/libraries/PactAllocationsV6.sol) | Pure allocation validation. |
| [`PactTimeoutV6`](contracts/src/libraries/PactTimeoutV6.sol) | Evidence, review and settlement window arithmetic. |

Design properties:

- **No admin over funds.** There is no owner and no upgradeability, and nothing can transfer to
  an arbitrary recipient. Contract addresses, the verifier, the guardian, the challenge window
  and the commission are bound immutably at deployment. The only privileged key is the
  guardian, an incident key that cannot move funds (below).
- **Immutable verifier.** Each module has one verifier for its whole life. There is no rotation:
  a new verifier means a new contract generation.
- **One ledger.** The vault keeps the invariant
  `tokenBalance + Σ paidOut == Σ deposited`. A value is never counted in two accounts at once.
- **Fixed timing.** `evidenceClosesAt = endAt + evidenceGrace`, then one 24-hour review window
  and one 72-hour settlement window. All windows are half-open. A pending split opens for
  finalization 24 hours after it was settled.
- **Outcome shapes.** Outcome 1 (refund) must be the exact equal split over the whole roster.
  Outcome 2 (closest wins) must be an equal split among its recipients. Outcome 0 (performance)
  is decided by the verifier and is not loss-bounded on-chain. Outcome 3 (rollover) carries no
  allocations.
- **Liveness without the operator.** If the Pact operator disappears, anyone can trigger the
  refunds for missed activation and missed settlement, anyone can finalize a pending split
  after its challenge window, and anyone can pay out existing credits.

### Trust assumptions

- **Verifier.** The verifier key decides how the pool is split between the Pact's own
  participants, within the rules above. It cannot pay anyone outside the Pact, cannot pay out
  more than the pool, and cannot block the timeout refund. Because of the challenge window, a
  split it signs cannot be paid before the guardian has had 24 hours to react.
- **Guardian.** See the next section. It can force the equal split and stop new Pacts, but it
  cannot choose who is paid or how much.
- **Commission wallets.** They receive the commission as ordinary credits and have no other
  rights. They can never join a Pact.

### Guardian (incident key)

Both modules share one guardian address,
[`0xF115c8832381Dc2e08f53b2b45BeD86719dFD0ca`](https://testnet.snowtrace.io/address/0xF115c8832381Dc2e08f53b2b45BeD86719dFD0ca).
It is a single key (an externally owned account, not a multisig) held by the Pact owner off the
Pact server, so a compromised server does not also hold the lever that stops it. It is **not an
admin key that can move funds.** It has exactly three levers:

| Lever | Effect |
|---|---|
| `pauseSettlement(bool)` | Stops new Pacts from being created on the module and new signed settlements from being accepted. Finalization, vetoes, timeout refunds and claims keep working, so a pause cannot freeze funds. Reversible. |
| `setVerifierRevoked(verifier, bool)` | Marks the verifier as compromised. Its Pacts can no longer settle or finalize, **anyone** can veto their pending splits, their timeout refund opens early (at the end of the review window), and no new Pact can be created on the module. Reversible, but vetoes and refunds already done stay final. |
| `vetoSettlementV6(pactId)` | Replaces one pending split with the deterministic equal split of the pool over the Pact's active members (the same split as the timeout refund). Only while the split is pending. Irreversible. |

What the guardian cannot do: choose a recipient or an amount, author or rewrite an outcome,
change the verifier (there is no rotation), touch a split that has already been finalized, or
send funds anywhere, including to itself. The worst it can do to a Pact is force the equal
split: winners then get only their equal share, and no commission is charged. It can also stop
new Pacts on a module.

### Commission

This generation charges a commission of **5% of each recipient's net gain**, and nothing else:

- The gain is the part of a recipient's payout above their own principal in that Pact (their
  stake plus any rolled-over principal). A member who gets back their stake or less pays
  nothing.
- It is charged only when a performance or closest-wins split (outcome 0 or 2) is finalized
  after its challenge window. It is rounded down per recipient, so the member keeps the dust.
- Of the commission, 10% (0.5% of the gain) goes to the operator wallet
  [`0x42242B1A459c00A83a8523CA46BFA9083aE67729`](https://testnet.snowtrace.io/address/0x42242B1A459c00A83a8523CA46BFA9083aE67729)
  and the rest (4.5% of the gain) to the company wallet
  [`0x7B578F2A27E3291081bD9584847e8486509069e8`](https://testnet.snowtrace.io/address/0x7B578F2A27E3291081bD9584847e8486509069e8),
  as ordinary pull credits of the same Pact.
- **No commission** on refunds (outcome 1, timeout or early refund), cancellations, leaves,
  exits, any rollover step, a veto, or any finalized split that is the equal split of the whole
  roster (every member gets `pool / n`, at most one unit more), whatever its outcome code.
- The rate, the 10/90 split and both wallets are immutable for this deployment. The vault caps
  any generation at 10% (`MAX_COMMISSION_BPS`).

## Avalanche Fuji deployment

Current deployment: chain ID 43113, block 59196737 (8 October 2026). The source code of all
four contracts is verified on Snowtrace. Stake token: USDC on Fuji
(`0x5425890298aed601595a70AB815c96711a31Bc65`). Challenge window: 24 hours on both modules.

| Contract | Address | Source |
|---|---|---|
| PactRegistryV6 | [`0x5128EC89CB377C535622Eb52Ab5295938FcC0caa`](https://testnet.snowtrace.io/address/0x5128EC89CB377C535622Eb52Ab5295938FcC0caa) | [Verified](https://testnet.snowtrace.io/address/0x5128EC89CB377C535622Eb52Ab5295938FcC0caa/contract/43113/code) |
| PactVaultV6 | [`0x6c879419659374d9BEF26CBFFF0Fb6f9Ee050a8f`](https://testnet.snowtrace.io/address/0x6c879419659374d9BEF26CBFFF0Fb6f9Ee050a8f) | [Verified](https://testnet.snowtrace.io/address/0x6c879419659374d9BEF26CBFFF0Fb6f9Ee050a8f/contract/43113/code) |
| PactSettlementModuleV6 (Walking) | [`0xB527eEE58674f5264e7B3A82034d2F04F9C54BA3`](https://testnet.snowtrace.io/address/0xB527eEE58674f5264e7B3A82034d2F04F9C54BA3) | [Verified](https://testnet.snowtrace.io/address/0xB527eEE58674f5264e7B3A82034d2F04F9C54BA3/contract/43113/code) |
| PactSettlementModuleV6 (Working) | [`0xCfE3ECFa42A5Cc8DC447D68C3E2Ac9232E0c7839`](https://testnet.snowtrace.io/address/0xCfE3ECFa42A5Cc8DC447D68C3E2Ac9232E0c7839) | [Verified](https://testnet.snowtrace.io/address/0xCfE3ECFa42A5Cc8DC447D68C3E2Ac9232E0c7839/contract/43113/code) |

The full manifest, with runtime code hashes, verifier, invite signer and commission addresses
and the deployment transaction, is in
[`deployments/avalanche-fuji-v6-prototype.json`](deployments/avalanche-fuji-v6-prototype.json).

### What changed from the 30 September deployment

- **Guardian incident key** with pause, verifier revocation and veto of a pending payout to the
  equal split. No verifier rotation, and no lever that can redirect funds.
- **Immutable verifier** per module.
- **24-hour challenge window** for outcome 0 and 2 splits, then permissionless
  `finalizeSettlementV6`.
- **Outcome shape rules** for outcomes 1 and 2, enforced on-chain.
- **72-hour settlement window** (was 24 hours), so a few days of keeper downtime no longer turn
  a result into the equal refund.
- **Leave until activation** (was: until the join deadline). A free pre-start exit that leaves
  fewer than two members cancels the Pact.
- **Early refund after revocation**: with the Pact's verifier revoked, the timeout refund opens
  at the end of the review window, and activation is refused.
- **5% commission on net winnings**, as described above.
- The registry refuses a stake token that does not have 6 decimals, and token call failures
  surface the token's revert reason (`TokenCallReverted`).

### Previous deployments

| Deployed | Registry | Manifest | Sources |
|---|---|---|---|
| 23 September 2026, block 58628167 | `0xAC8eb93e608D78521D6Cf4d3d74b1d162e5964F0` | [`retired/…-2026-09-23.json`](deployments/retired/avalanche-fuji-v6-prototype-2026-09-23.json) | tag [`fuji-2026-09-23`](../../tree/fuji-2026-09-23) |
| 30 September 2026, block 58898597 | `0x7F735A4f179153579e1B360fCe3DE93c0dc0dd6a` | [`retired/…-2026-09-30.json`](deployments/retired/avalanche-fuji-v6-prototype-2026-09-30.json) | tag [`fuji-2026-09-30`](../../tree/fuji-2026-09-30) |
| 7 October 2026, block 59136740 | `0xe89755B9ca6f5a5DE660cb45c2A45fd1b963dB3F` | [`retired/…-2026-10-07.json`](deployments/retired/avalanche-fuji-v6-prototype-2026-10-07.json) | not published |
| 8 October 2026, block 59185321 | `0x04298422d93C86531D5a9eF3820e1EEFbf55edfa` | [`retired/…-2026-10-08.json`](deployments/retired/avalanche-fuji-v6-prototype-2026-10-08.json) | not published |

The 23 September deployment was retired when activation, settlement and payouts were opened to
any caller. The 30 September deployment was retired on 7 October. Two short-lived intermediate
Fuji deployments (7 October and earlier on 8 October, both without a commission) were retired
within a day, before their sources were published here. Their manifests are kept for the
record, but `npm run verify:bytecode` only checks the current deployment.

## Build, test and reproduce

Requires Node.js 22 or later.

```bash
npm ci
npm test                  # compiles with solc 0.8.30 and runs 91 tests on an in-process Hardhat network
npm run verify:bytecode   # rebuilds and compares against the live Fuji contracts
```

The tests deploy the vault without a commission. The commission arithmetic is not covered by
this suite.

Compiler settings: solc `0.8.30+commit.73712a01`, `evmVersion: cancun`, `viaIR: true`,
optimizer enabled with `runs: 1`. They are defined in
[`scripts/pact-settlement-v6-artifact.mjs`](scripts/pact-settlement-v6-artifact.mjs).

`verify:bytecode` reads each contract from Fuji over public RPC and checks that:

- the runtime code matches the compiled code byte for byte (immutables are masked; the
  metadata hash is compared, so sources and settings must be identical), and
- the creation transaction starts with the compiled creation code.

`node scripts/verify-fuji-bytecode.mjs --write` also writes the Standard JSON input and the
constructor arguments used for explorer verification to `verification/`.

## Source comments

The sources are published exactly as deployed on Fuji. Some NatSpec comments are out of date:

- `IPactSettlementV6` says the surface "is not wired to the deployed Fuji registry" and "must not
  be deployed to any network". It is the interface of the deployed modules.
- `PactAllocationsV6` says "V5 is already at EIP-170 size". Only V6 exists and is deployed.
- Comments mention a "handoff report" and `docs/TODO-mainnet-hardening.md`. These are internal
  project notes and are not in this repository.
- The registry and vault say "The bytecode accepts Avalanche Fuji and Avalanche C-Chain". That
  is what the code allows; the contracts are deployed only on Fuji.

Solidity puts a hash of the source files, comments included, into the compiled bytecode.
Changing any comment would mean redeploying the contracts. It would also break the byte-for-byte
match with the chain that `npm run verify:bytecode` and the explorer verification prove. The
comments will be cleaned up before the audit. Until then, this README is the current
description.

## Security

See [SECURITY.md](SECURITY.md). An independent audit is a precondition for any mainnet
deployment.

## License

[MIT](LICENSE)
