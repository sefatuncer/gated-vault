# VC Verifier Gas Overhead

Raw measurements. No commentary. Source: `forge test --gas-report`.
Function-level numbers exclude the 21,000 intrinsic transaction cost.
Cold = first interaction with a storage slot / account in the call.

## Toolchain

| Component | Version |
|---|---|
| Foundry | v1.7.0 |
| solc | 0.8.28 |
| EVM | Prague |
| Optimizer | enabled, runs = 200 |
| via_ir | false |

## Deployment

| Contract | Deploy cost (gas) | Deploy size (bytes) |
|---|---:|---:|
| GatedVault (with VC) | 1,776,406 | 9,211 |
| IdentityVerifier | 954,447 | 5,164 |
| Whitelist | 522,948 | 2,285 |

## GatedVault Deployment Delta (whitelist-only -> VC)

| Metric | Whitelist-only (todo-27) | With VC (todo-40) | Delta |
|---|---:|---:|---:|
| Deploy cost (gas) | 1,490,042 | 1,776,406 | +286,364 |
| Deploy size (bytes) | 7,787 | 9,211 | +1,424 |

## Function Gas — GatedVault

| Function | Min | Avg | Median | Max | # Calls |
|---|---:|---:|---:|---:|---:|
| depositWithAttestation | 32,474 | 145,049 | 221,707 | 222,855 | 12 |
| deposit | 27,718 | 114,098 | 133,077 | 137,853 | 36 |
| setRequiredCredentialType | 30,365 | 42,579 | 47,465 | 47,465 | 7 |

## Function Gas — IdentityVerifier

| Function | Min | Avg | Median | Max | # Calls |
|---|---:|---:|---:|---:|---:|
| consumeAttestation | 27,243 | 63,113 | 34,115 | 101,365 | 25 |
| hashAttestation | 1,143 | 1,143 | 1,143 | 1,143 | 12 |
| attestedUntil | 597 | 1,722 | 2,597 | 2,597 | 16 |
| attestedCredentialType | 538 | 1,680 | 2,538 | 2,538 | 7 |
| usedNonces | 2,524 | 2,524 | 2,524 | 2,524 | 2 |
| SIGNER_ROLE | 239 | 239 | 239 | 239 | 13 |

## Deposit Path — Cold First-Deposit (consistent methodology)

| Path | Gas | # Calls |
|---|---:|---:|
| Plain deposit (whitelist gate) | 133,077 | 1 |
| depositWithAttestation (VC gate) | 221,707 | 1 |
| Overhead | +88,630 | |

## consumeAttestation — Cold First-Time Breakdown (~101,365)

| Bucket | Gas | Source |
|---|---:|---|
| 3x cold SSTORE (usedNonces, attestedUntil, attestedCredentialType) | 66,300 | zero->nonzero @ 22,100 (EIP-2929/3529) |
| ecrecover precompile | 3,000 | signature recovery |
| hasRole cold SLOAD | 2,100 | role membership slot first read |
| usedNonces cold SLOAD | 2,100 | replay check before write |
| _hashTypedDataV4 (struct keccak, domain cached) | ~250 | EIP-712 digest |
| calldata decode + abi.encode keccak + dispatch + memory | ~27,615 | remainder |
| Sum | ~101,365 | |

## consumeAttestation — First-Time vs Returning User

| Slot state | Per-write gas | Notes |
|---|---:|---|
| usedNonces (always fresh nonce) | 22,100 | zero->nonzero every call |
| attestedUntil (first time) | 22,100 | zero->nonzero |
| attestedUntil (returning) | ~5,000 | nonzero->nonzero |
| attestedCredentialType (first time) | 22,100 | zero->nonzero |
| attestedCredentialType (returning) | ~5,000 | nonzero->nonzero |

| Scenario | consumeAttestation gas |
|---|---:|
| Cold first-time (max measured) | 101,365 |
| Returning user / warm (median measured) | 34,115 |
| Revert path, no SSTORE (min measured) | 27,243 |

## Deposit Gate Progression (suite-avg, prior benchmarks)

| Gating | deposit avg gas | Delta | Source |
|---|---:|---:|---|
| None | 125,528 | — | todo-22 |
| Whitelist | 130,648 | +5,120 | todo-27 |

Note: the VC path uses `depositWithAttestation`, which consumes a fresh
attestation and is not directly comparable to the plain-deposit suite
average above; see the cold first-deposit table for the like-for-like
delta.

## Test / Coverage / Static Analysis

| Gate | Value |
|---|---|
| Tests | 137 / 137 pass |
| Coverage (line) | 100% |
| Coverage (statement) | 100% |
| Coverage (branch) | 100% |
| Coverage (function) | 100% |
| Slither v0.11.5 | 0 result |
| `forge fmt --check` | clean |
| `forge snapshot --check` | clean |
