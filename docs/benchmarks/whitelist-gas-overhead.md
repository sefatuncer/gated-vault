# Whitelist Gating Gas Overhead

Raw measurements. No commentary. Comparison: pre-gating baseline
(commit `f26d7a1`, todo-22 / Phase 1 closeout) vs post-gating state
(commit `1410c44`, todo-26 / Phase 2 fuzz suite).

## Toolchain

| Component | Version |
|---|---|
| Foundry | v1.7.0 |
| solc | 0.8.28 |
| EVM | Prague |
| Optimizer | enabled, runs = 200 |
| via_ir | false |

## Whitelist Deployment

| Metric | Value |
|---|---:|
| Deploy cost (gas) | 522,948 |
| Deploy size (bytes) | 2,285 |

## Whitelist — Function Gas (forge test --gas-report)

| Function | Min | Avg | Median | Max | # Calls |
|---|---:|---:|---:|---:|---:|
| checkWhitelisted | 2,534 | 2,540 | 2,534 | 2,610 | 35 |
| isWhitelisted | 2,628 | 2,628 | 2,628 | 2,628 | 1 |
| setWhitelist | 26,100 | 47,367 | 48,012 | 48,012 | 34 |

## GatedVault — Hot Path Delta

| Function | Pre-gating avg | Post-gating avg | Delta |
|---|---:|---:|---:|
| deposit | 125,528 | 130,648 | +5,120 |
| redeem | 66,743 | 66,742 | -1 |
| harvest | 40,932 | 40,855 | -77 |

## GatedVault — Deployment Delta

| Metric | Pre-gating | Post-gating | Delta |
|---|---:|---:|---:|
| Deploy cost (gas) | 1,452,759 | 1,490,042 | +37,283 |
| Deploy size (bytes) | 7,503 | 7,787 | +284 |

## Attribution — deposit +5,120 gas

| Bucket | Gas | Source |
|---|---:|---|
| Cold STATICCALL account access | 2,600 | EIP-2929 cold account access (Whitelist contract address) |
| Cold SLOAD `isWhitelisted[receiver]` | 2,100 | EIP-2929 cold storage slot read (mapping slot first access) |
| Function dispatch + branch + revert encoding | ~420 | selector match in Whitelist + JUMPI + revert path setup |
| Immutable read (`whitelist` field) | 3 | bytecode-embedded PUSH20 (no SLOAD) |
| Sum (theoretical) | ~5,123 | |
| Measured delta (avg) | +5,120 | |

## Cold vs Warm Path

| Bucket | Cold (measured) | Warm (theoretical) |
|---|---:|---:|
| STATICCALL account access | 2,600 | 100 |
| SLOAD `isWhitelisted[receiver]` | 2,100 | 100 |
| Dispatch + branch | ~420 | ~420 |
| Immutable | 3 | 3 |
| Total | ~5,123 | ~623 |

## Test / Coverage / Static Analysis

| Gate | Value |
|---|---|
| Tests | 80 / 80 pass |
| Coverage (line) | 100% (75/75) |
| Coverage (statement) | 100% (72/72) |
| Coverage (branch) | 100% (11/11) |
| Coverage (function) | 100% (17/17) |
| Slither v0.11.5 | 0 result |
| `forge fmt --check` | clean |
