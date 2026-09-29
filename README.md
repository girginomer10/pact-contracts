# Pact contracts (V6)

Solidity contracts behind [Pact](https://pactside.com), an iPhone and Mac app for keeping
commitments with friends. Friends agree on a goal, each puts a small stake into a shared pool,
and the pool is split by the result when the Pact ends.

> **Status: unaudited prototype, Avalanche Fuji testnet only.** These contracts have not had
> an independent security review. The constructors refuse to deploy on any chain other than
> Fuji (43113) or a local test chain (31337). Do not use them with real funds.
>
> **The sources here are exactly what runs on Fuji.** Some code comments are older than the
> deployment and are out of date. They are left unchanged on purpose. See
> [Source comments](#source-comments).

## How a Pact works on-chain

App users never see a wallet, gas or a chain. They sign in with a passkey, and their passkey
smart account sends sponsored transactions for them. Underneath:

1. **Create.** The creator opens a Walking Pact (a daily step goal) or a Working Pact (focus
   time protected on iPhone and Mac) and deposits their stake. Terms, dates and the stake
   amount are fixed at creation.
2. **Join.** Joining is invite-only. Each joiner needs an EIP-712 `InvitePermit` signed by that
   Pact's invite signer. The creator can rotate the signer, which cancels every outstanding
   invite, and can block recipients while recruiting.
3. **Activate.** Activation closes recruitment. If the activation deadline passes, anyone can
   cancel the Pact and every participant gets a full refund.
4. **Settle.** Results come from on-device evidence (Apple Health steps, or iPhone and Mac focus
   protection) and are evaluated off-chain. The outcome is submitted as an EIP-712
   `SettlementAuthorization` signed by the module's verifier key. The contracts check the
   signature, the settlement window and the allocations: recipients must be active
   participants, with no duplicates, and the amounts must add up exactly to the pool.
5. **Claim.** Each participant pulls their own credit from the vault.
6. **Timeout.** If no valid settlement arrives before the settlement window closes, anyone can
   trigger the timeout refund.

Walking Pacts can also roll the pool into a successor Pact, but only if every participant
consents.

## Contracts

| Contract | Role |
|---|---|
| [`PactRegistryV6`](contracts/src/PactRegistryV6.sol) | Owns the Pact lifecycle: create, join, leave, exit, activate, cancel, settle, refund, rollover. Every state transition happens here. |
| [`PactVaultV6`](contracts/src/PactVaultV6.sol) | Holds the ERC-20 stakes and is the only accounting ledger: pool, rollover reserve, claimable credits, payouts. |
| [`PactSettlementModuleV6`](contracts/src/PactSettlementModuleV6.sol) | Verifies verifier authorizations, consumes settlement nonces and turns allocations into vault credits. Deployed twice, once for Walking and once for Working Pacts. |
| [`PactAllocationsV6`](contracts/src/libraries/PactAllocationsV6.sol) | Pure allocation validation. |
| [`PactTimeoutV6`](contracts/src/libraries/PactTimeoutV6.sol) | Evidence, review and settlement window arithmetic. |

Design properties:

- **No admin path.** There is no owner and no upgradeability, and nothing can transfer to an
  arbitrary recipient. Contract addresses are bound to each other immutably at deployment.
- **One ledger.** The vault keeps the invariant
  `tokenBalance + Σ paidOut == Σ deposited`. A value is never counted in two accounts at once.
- **Fixed timing.** `evidenceClosesAt = endAt + evidenceGrace`, then one 24-hour review window
  and one 24-hour settlement window. All windows are half-open.
- **Liveness without the operator.** If the Pact operator disappears, anyone can trigger the
  refunds for missed activation and missed settlement.

Trust assumption: the verifier key decides how the pool is split between the Pact's own
participants, within the rules above. It cannot pay anyone outside the Pact, cannot pay out
more than the pool, and cannot block the timeout refund.

## Avalanche Fuji deployment

Chain ID 43113, deployed at block 58628167. The source code of all four contracts is verified on
Snowtrace. Stake token: USDC on Fuji
(`0x5425890298aed601595a70AB815c96711a31Bc65`).

| Contract | Address | Source |
|---|---|---|
| PactRegistryV6 | [`0xAC8eb93e608D78521D6Cf4d3d74b1d162e5964F0`](https://testnet.snowtrace.io/address/0xAC8eb93e608D78521D6Cf4d3d74b1d162e5964F0) | [Verified](https://testnet.snowtrace.io/address/0xAC8eb93e608D78521D6Cf4d3d74b1d162e5964F0/contract/43113/code) |
| PactVaultV6 | [`0x3bAb5dE2D7Ed73848d2f377F43A39c757f199a43`](https://testnet.snowtrace.io/address/0x3bAb5dE2D7Ed73848d2f377F43A39c757f199a43) | [Verified](https://testnet.snowtrace.io/address/0x3bAb5dE2D7Ed73848d2f377F43A39c757f199a43/contract/43113/code) |
| PactSettlementModuleV6 (Walking) | [`0xd3Caa4821C10443aa0CEaa34e87c9D0efF82D411`](https://testnet.snowtrace.io/address/0xd3Caa4821C10443aa0CEaa34e87c9D0efF82D411) | [Verified](https://testnet.snowtrace.io/address/0xd3Caa4821C10443aa0CEaa34e87c9D0efF82D411/contract/43113/code) |
| PactSettlementModuleV6 (Working) | [`0x40F3b5bc99f55c8286438c2871C388d5eABBF332`](https://testnet.snowtrace.io/address/0x40F3b5bc99f55c8286438c2871C388d5eABBF332) | [Verified](https://testnet.snowtrace.io/address/0x40F3b5bc99f55c8286438c2871C388d5eABBF332/contract/43113/code) |

The full manifest, with runtime code hashes, verifier and invite signer addresses and the
deployment transaction, is in
[`deployments/avalanche-fuji-v6-prototype.json`](deployments/avalanche-fuji-v6-prototype.json).

## Build, test and reproduce

Requires Node.js 22 or later.

```bash
npm ci
npm test                  # compiles with solc 0.8.30 and runs 64 tests on an in-process Hardhat network
npm run verify:bytecode   # rebuilds and compares against the live Fuji contracts
```

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

The sources are published exactly as deployed on Fuji. Some NatSpec comments were written
before the deployment, so parts of them are out of date:

- `PactRegistryV6` and `PactVaultV6` say "not deployed". Both are deployed on Fuji (see above).
- `PactSettlementModuleV6` says it is "NOT wired to the deployed registry" and "MUST NOT be
  deployed to any network". It is wired to the registry and vault and deployed twice on Fuji.
  "Unaudited" is still true.
- Comments mention a "handoff report", `memory/` and `docs/TODO-mainnet-hardening.md`. These
  are internal project notes and are not in this repository. Older design versions (V5) are
  also mentioned; only V6 exists and is deployed.

Solidity puts a hash of the source files, comments included, into the compiled bytecode.
Changing any comment would mean redeploying the contracts. It would also break the byte-for-byte
match with the chain that `npm run verify:bytecode` and the explorer verification prove.
The comments will be updated with the next contract deployment. Until then, this README is the
current description.

## Security

See [SECURITY.md](SECURITY.md). An independent audit is a precondition for any mainnet
deployment.

## License

[MIT](LICENSE)
