# Contributing to gated-vault

Thanks for taking the time to look. This is a personal portfolio project: an ERC-4626 yield vault gated by W3C Verifiable Credentials, designed in the eIDAS 2.0, MiCA, and RWA tokenization context.

PRs and issues are welcome, but note that review cadence is best-effort. Solo maintainer; large rewrites may sit while I focus on the roadmap. Smaller, focused changes (bug fixes, doc tweaks, new test cases) move faster.

## Reporting Issues

Open an issue with the following sections. The more specific you are, the faster the fix.

- **Foundry version:** output of `forge --version`
- **OS:** Windows / macOS / Linux + version
- **Steps to reproduce:** numbered, minimal
- **Expected behavior:**
- **Actual behavior:** include the failing trace if any (`forge test -vvv`)
- **Logs / output:** code-fenced block, redact any address or RPC URL you don't want public

For security issues, do **not** open a public issue. See `SECURITY.md`.

## Development Setup

### Prerequisites

- Foundry (forge, cast, anvil) — `forge --version` should be 1.x+.
- Git 2.30+.
- Node.js 20 LTS (only needed for the verifier service in Phase 4).

### First-time setup

```bash
# Foundry, if not yet installed (Linux / macOS):
curl -L https://foundry.paradigm.xyz | bash
foundryup
forge --version

# Clone with submodules (lib/forge-std, lib/openzeppelin-contracts):
git clone --recurse-submodules git@github.com:sefatuncer/gated-vault.git
cd gated-vault

# Build & test:
forge build
forge test -vvv
```

If you cloned without `--recurse-submodules`, run `git submodule update --init --recursive` once.

Windows note: `foundryup` does not work under Git Bash MinGW64. Manual install instructions are tracked in the project's internal solutions notes; the short version is to download `foundry_<tag>_win32_amd64.zip` from the Foundry releases page, extract to `~/.foundry/bin/`, and add to PATH.

### Verifier service (Phase 4 onward)

```bash
cd verifier-service
npm install
npm run build
npm test
npm run dev      # local Fastify
```

## Pull Request Workflow

1. Fork the repo and create a feature branch off `main`:
   ```bash
   git checkout -b feat/<scope>/<short-description>
   ```
2. Keep changes small and focused. One logical change per PR. Drive-by refactors belong in a separate PR.
3. Tests must pass: `forge test`.
4. Line coverage must not drop below 95%:
   ```bash
   forge coverage --report lcov
   ```
5. Static analysis clean (high + medium severity):
   ```bash
   slither .
   aderyn .
   ```
6. Format clean: `forge fmt --check`.
7. Gas snapshot stable; existing tests should not regress:
   ```bash
   forge snapshot --check
   ```
8. NatSpec for any new public, external, or internal state-changing function: `@notice`, `@dev`, `@param`, `@return`.

The same gates run in CI (Phase 6 onward); the local commands above let you predict the outcome before pushing.

## Commit Style

Conventional Commits with a closed scope set:

```
feat(scope):  fix(scope):  test(scope):
docs(scope):  ci(scope):   chore(scope):
refactor(scope):  perf(scope):
```

Valid scopes (do not invent new ones):

`vault`, `verifier`, `identity`, `whitelist`, `ci`, `docs`, `tests`, `deploy`, `social`, `infra`.

Good: `feat(vault): add decimals offset for inflation defense`
Bad:  `update vault stuff`

## Code Style

- `forge fmt --check` is the source of truth for formatting. Don't fight the formatter.
- Custom errors instead of `require(string)`. Gas + UX both win.
- `SafeERC20.safeTransfer` / `safeTransferFrom`. No bare `transfer`.
- Checks-Effects-Interactions order. `nonReentrant` on state-changing external entrypoints.
- Rounding direction at ERC-4626 boundaries: vault favored. Floor on share-mint, Ceil on share-burn.
- EIP-712 typed data for off-chain signatures. No bare `eth_sign` (EIP-191).
- Replay protection on any off-chain to on-chain bridging: nonce + chainId + domain separator.

## Code of Conduct

Constructive, technical feedback only. Disagreement is welcome; ad hominem and dismissive tone are not. Assume goodwill and ask questions before assuming bad faith.

If you observe behavior that doesn't meet this bar, email `tuncersefa@gmail.com` with the context. Reports are taken seriously.

## Maintainer Note

This is a personal portfolio project, not a community-maintained framework. The internal roadmap drives priorities. PRs that align with current direction merge faster; PRs that don't may sit or be politely declined. That's a feature, not a bug, of solo work.

If you're considering a larger contribution (new module, architectural change), open an issue first to discuss. It saves both of us time.
