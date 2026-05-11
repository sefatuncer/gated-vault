# GatedVault Gas Baseline

Raw measurements only — no commentary. Phase 1 baseline locked at commit
`8ac4401`; this file tracks the live `forge snapshot` numbers so each phase
that touches the vault hot path leaves a visible delta.

## Toolchain

| Component | Version |
|---|---|
| Foundry | v1.7.0 |
| solc | 0.8.28 |
| EVM | Prague |
| Optimizer | enabled, runs = 200 |
| via_ir | false |

Latest measurement: 2026-05-11, after todo-25 (Whitelist gating wired into
`_deposit`). Previous baseline: 2026-05-06, commit `8ac4401`.

## Deployment

| Metric | Value | Delta vs 2026-05-06 |
|---|---:|---:|
| GatedVault deployment cost (gas) | 1,490,042 | +37,283 |
| GatedVault deployed size (bytes) | 7,787 | +284 |

## GatedVault — Function Gas (forge test --gas-report)

| Function | Min | Avg | Median | Max | # Calls |
|---|---:|---:|---:|---:|---:|
| MAX_YIELD_RATE | 250 | 250 | 250 | 250 | 1 |
| SECONDS_PER_YEAR | 249 | 249 | 249 | 249 | 3 |
| allowance | 2,755 | 2,755 | 2,755 | 2,755 | 1 |
| approve | 46,440 | 46,440 | 46,440 | 46,440 | 1 |
| asset | 269 | 269 | 269 | 269 | 1 |
| balanceOf | 2,659 | 2,659 | 2,659 | 2,659 | 261 |
| convertToShares | 10,656 | 10,656 | 10,656 | 10,656 | 2 |
| deposit | 27,696 | 130,648 | 131,403 | 137,718 | 804 |
| depositYieldReserve | 23,796 | 36,133 | 36,155 | 37,144 | 262 |
| harvest | 31,225 | 40,855 | 41,165 | 41,173 | 260 |
| lastHarvest | 2,393 | 2,393 | 2,393 | 2,393 | 2 |
| maxRedeem | 2,671 | 2,671 | 2,671 | 2,671 | 2 |
| mint (ERC-4626 entry) | 28,098 | 28,098 | 28,098 | 28,098 | 1 |
| name | 3,154 | 3,154 | 3,154 | 3,154 | 1 |
| owner | 2,398 | 2,398 | 2,398 | 2,398 | 1 |
| pendingYield | 2,452 | 7,177 | 7,184 | 7,184 | 778 |
| previewDeposit | 5,945 | 5,945 | 5,945 | 5,945 | 1 |
| previewRedeem | 10,634 | 10,634 | 10,634 | 10,634 | 2 |
| principal | 2,416 | 2,416 | 2,416 | 2,416 | 773 |
| redeem | 24,977 | 66,742 | 66,606 | 83,861 | 269 |
| setYieldRate | 23,728 | 31,887 | 29,642 | 47,826 | 5 |
| symbol | 3,197 | 3,197 | 3,197 | 3,197 | 1 |
| totalAssets | 2,578 | 5,732 | 7,310 | 7,310 | 3 |
| totalSupply | 2,370 | 2,370 | 2,370 | 2,370 | 1 |
| whitelist (getter) | 283 | 283 | 283 | 283 | 1 |
| withdraw | 32,117 | 32,117 | 32,117 | 32,117 | 1 |
| yieldRate | 2,372 | 2,372 | 2,372 | 2,372 | 3 |

## Whitelist — Function Gas (forge test --gas-report)

| Function | Min | Avg | Median | Max | # Calls |
|---|---:|---:|---:|---:|---:|
| checkWhitelisted | 2,534 | 2,534 | 2,534 | 2,610 | 805 |
| isWhitelisted | — | — | — | — | per-test |
| setWhitelist | — | — | — | — | per-test |

## Deltas vs 2026-05-06 (todo-25 impact)

| Function | 2026-05-06 avg | 2026-05-11 avg | Delta |
|---|---:|---:|---:|
| deposit | 125,528 | 130,648 | +5,120 |
| harvest | 40,932 | 40,855 | -77 |
| redeem | 66,743 | 66,742 | -1 |

The deposit hot-path overhead is one external staticcall into `Whitelist.checkWhitelisted` (~2,534 gas) plus warm SLOAD of the immutable address — well below the 10k psychological gate.

## Test Suite

- 49 unit tests (`test/unit/GatedVaultTest.t.sol`)
- 4 mock unit tests (`test/unit/MockUSDCTest.t.sol`)
- 19 RBAC unit tests (`test/unit/WhitelistTest.t.sol`)
- 3 fuzz tests, 1000 runs each (`test/fuzz/GatedVaultFuzz.t.sol`)
- All passing.

## Coverage Snapshot

| File | Lines | Statements | Branches | Funcs |
|---|---:|---:|---:|---:|
| GatedVault.sol | 100% (56/56) | 100% (57/57) | 100% (10/10) | 100% (10/10) |
| Whitelist.sol | 100% (13/13) | 100% (12/12) | 100% (1/1) | 100% (4/4) |
| MockERC777.sol | 100% (2/2) | 100% (1/1) | n/a | 100% (1/1) |
| MockUSDC.sol | 100% (4/4) | 100% (2/2) | n/a | 100% (2/2) |
| Total | 100% (75/75) | 100% (72/72) | 100% (11/11) | 100% (17/17) |

## Static Analysis

`slither .` (config: `slither.config.json`): `0 result(s) found` after triage of baseline 9 findings (4 medium incorrect-equality false positives, 4 low timestamp aggressive flags, 1 informational low-level-calls intentional staticcall).
