# verifier-service

Off-chain Verifiable Credential verifier for `gated-vault`. It accepts an
OpenID4VP presentation from a holder wallet, validates the credential, and
signs an EIP-712 attestation that the on-chain `IdentityVerifier` consumes
inside the deposit gate.

This is the Phase 4 component. The on-chain side (Phase 3, `IdentityVerifier`
+ `GatedVault.depositWithAttestation`) is complete; this service produces the
attestations that side verifies.

## Stack

| Layer | Choice | Rationale |
|---|---|---|
| SSI agent | Credo TS `0.7.0` | ADR-001 (TypeScript uniformity, first-class OpenID4VC, OpenWallet Foundation governance) |
| Protocol | OpenID4VC (OID4VCI + OID4VP) | ADR-002 (eIDAS 2.0 / EUDI Wallet alignment, mainstream wallet support) |
| Web server | Fastify `^5.8` | async-first, schema validation, low overhead |
| Signing | ethers `^6.16` | EIP-712 `signTypedData` matching the on-chain domain |
| Language | TypeScript `^5.7`, ESM, strict | decorator metadata for Credo TS (tsyringe / class-transformer) |

`@credo-ts/*` is pinned to an **exact** patch (`0.7.0`). Credo TS is pre-1.0;
minor releases have shipped breaking changes (e.g. v0.5 to v0.6 module
registration). Treat an upgrade as a deliberate, tested PR — not a routine
bump. See ADR-001 for the full decision and trade-offs.

### Deferred dependencies

- `@credo-ts/askar` (encrypted secure storage) is wired when persistent key
  storage is needed (issuer/verifier todos), not at init. It pulls a native
  binding, so it is added once with platform attention rather than blocking
  the project skeleton.
- `@credo-ts/anoncreds` is deferred indefinitely: eIDAS 2.0 and MiCA mandate
  JWT VC and SD-JWT VC, not AnonCreds (ADR-001).

## Commands

```bash
npm install        # install pinned deps
npm run build      # tsc -> dist/
npm run dev        # tsx watch (hot reload)
npm start          # run the built service
npm test           # vitest run
npm run lint       # eslint
npm run format     # prettier --write
```

## Environment

Copy `.env.example` to `.env` and fill it in. Testnet only — no mainnet RPC or
mainnet key. The `.env` file is gitignored; never commit a real key.

## Layout

```
verifier-service/
├── src/            service source (entrypoint: src/index.ts)
├── test/           vitest specs
├── tsconfig.json   ESM, strict, decorator metadata
├── eslint.config.mjs
└── .env.example    config template
```
