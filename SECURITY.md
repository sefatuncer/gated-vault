# Security Policy

## Supported Versions

Only the `main` branch is supported. This project ships from `main`; there are no release branches. If you need stability, pin a commit SHA.

| Branch          | Supported |
| --------------- | --------- |
| `main`          | yes       |
| anything else   | no        |

## Reporting a Vulnerability

Two channels, in order of preference:

1. **GitHub Security Advisories (private)** — preferred for anything that could affect deployed contracts or off-chain verifier behavior:
   https://github.com/sefatuncer/gated-vault/security/advisories/new
2. **Email:** `tuncersefa@gmail.com` (plaintext is fine; PGP not yet set up). If the issue is sensitive, prefer the advisory channel above.

Please do **not** open a public issue for a security-relevant bug.

When reporting, include:

- A clear description of the issue and its impact.
- Steps to reproduce (Foundry version, OS, exact command sequence).
- Proof-of-concept code or test if you have one.
- Your name or handle if you'd like credit; "anonymous" is fine too.

## Timeline

- **Acknowledgment of receipt:** within 72 hours.
- **Initial triage and severity:** within 14 days.
- **Fix in `main` (target):** within 30 days. Structural issues may take longer; we will keep you informed.

If you don't hear back within 7 days, please follow up. Messages can fall through.

## Coordinated Disclosure

We operate on a coordinated disclosure basis. The default embargo is 30 days from triage to public disclosure. If a fix lands sooner and a proof-of-concept is already public elsewhere, we may disclose earlier with credit to the reporter.

## Scope

**In scope:**

- `contracts/` — Solidity sources in this repository.
- `verifier-service/` — off-chain Verifiable Credential verifier (TypeScript, added in Phase 4).
- `script/deploy/` — deploy scripts targeting Sepolia, Base Sepolia, Arbitrum Sepolia testnets.
- Documented patterns in `docs/` and the README.

**Out of scope:**

- OpenZeppelin Contracts internals (`lib/openzeppelin-contracts/`). Report upstream: https://github.com/OpenZeppelin/openzeppelin-contracts/security
- Foundry tooling and forge-std (`lib/forge-std/`). Report upstream: https://github.com/foundry-rs/foundry/security
- RPC provider issues (Alchemy, Infura, etc.).
- User-side issues: lost private keys, phishing, wallet vulnerabilities.
- Theoretical attacks without a concrete exploit path on this codebase.

## Deployment Status

This project does **not** ship on mainnet. Deployments target testnets only:

- Sepolia
- Base Sepolia
- Arbitrum Sepolia

Test funds only. There is no real value at risk on-chain. Reports are still welcome, since the patterns here may be reused in production projects elsewhere.

## No Bug Bounty

This is a portfolio and educational project. No monetary bounty is offered. Reporters are credited in:

- The advisory itself (with consent).
- A `SECURITY_HALL_OF_FAME.md` file, added when the first valid report arrives.

Credit only. If you need paid compensation for your time, this is not the right project.
