# Security

These contracts are an **unaudited prototype** deployed only to the Avalanche Fuji testnet. They
hold test USDC only. They have not had an independent security review and must not be used with
real funds.

## Reporting a vulnerability

Please report issues privately through the support form at https://pactside.com/support, or open
a [GitHub security advisory](https://github.com/girginomer10/pact-contracts/security/advisories/new)
on this repository. Do not open a public issue for an exploitable bug.

Include the affected contract and function, the conditions needed to trigger the issue, and a
proof of concept if you have one.

## Scope

In scope: everything under `contracts/src/`.

Out of scope: the test mocks under `contracts/test/`, and the off-chain Pact server and apps,
which are not in this repository.
