---
name: "Bug report"
about: "Report a bug or unexpected behavior in contracts, tests, or scripts"
title: "[bug] "
labels: ["bug"]
assignees: []
---

## Description

A clear and concise description of the bug. What did you expect to happen, and what happened instead?

## Steps to Reproduce

1.
2.
3.

## Expected Behavior

What you expected.

## Actual Behavior

What actually happened. If a test fails, paste the relevant `forge test -vvv` trace below:

```
<paste trace here>
```

## Environment

- **Foundry version:** output of `forge --version`
- **OS:** Windows / macOS / Linux + version
- **Solidity version:** from `foundry.toml` (default: 0.8.28)
- **Node.js version (if verifier-service related):** `node --version`
- **Branch / commit SHA:** `git rev-parse HEAD`

## Relevant Logs / Output

```
<paste here, code-fenced; redact RPC URLs and private addresses you don't want public>
```

## Additional Context

Anything else that helps reproduce the issue: related PRs, recent dependency upgrades, network conditions, fork block number, etc.

---

> Security-relevant bugs: do **not** open a public issue. See [`SECURITY.md`](../../SECURITY.md) for the private reporting channels.
