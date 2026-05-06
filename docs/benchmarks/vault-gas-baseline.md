# GatedVault Gas Baseline

Phase 1 closeout snapshot. Raw measurements only — no commentary.

## Toolchain

| Component | Version |
|---|---|
| Foundry | v1.7.0 |
| solc | 0.8.28 |
| EVM | Prague |
| Optimizer | enabled, runs = 200 |
| via_ir | false |

Snapshot commit: `8ac4401` (HEAD before this benchmark cycle).
Snapshot date: 2026-05-06.

## Deployment

| Metric | Value |
|---|---|
| GatedVault deployment cost (gas) | 1,452,759 |
| GatedVault deployed size (bytes) | 7,503 |

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
| deposit | 27,718 | 125,528 | 126,029 | 132,344 | 800 |
| depositYieldReserve | 23,796 | 36,133 | 36,155 | 37,144 | 262 |
| harvest | 31,225 | 40,932 | 41,165 | 41,173 | 260 |
| lastHarvest | 2,393 | 2,393 | 2,393 | 2,393 | 2 |
| maxRedeem | 2,671 | 2,671 | 2,671 | 2,671 | 2 |
| name | 3,154 | 3,154 | 3,154 | 3,154 | 1 |
| owner | 2,398 | 2,398 | 2,398 | 2,398 | 1 |
| pendingYield | 2,452 | 7,177 | 7,184 | 7,184 | 778 |
| previewDeposit | 5,945 | 5,945 | 5,945 | 5,945 | 1 |
| previewRedeem | 10,634 | 10,634 | 10,634 | 10,634 | 2 |
| principal | 2,416 | 2,416 | 2,416 | 2,416 | 773 |
| redeem | 24,977 | 66,743 | 66,606 | 83,861 | 268 |
| setYieldRate | 23,728 | 31,887 | 29,642 | 47,826 | 5 |
| symbol | 3,197 | 3,197 | 3,197 | 3,197 | 1 |
| totalAssets | 2,578 | 5,732 | 7,310 | 7,310 | 3 |
| totalSupply | 2,370 | 2,370 | 2,370 | 2,370 | 1 |
| withdraw | 32,117 | 32,117 | 32,117 | 32,117 | 1 |
| yieldRate | 2,372 | 2,372 | 2,372 | 2,372 | 3 |

## Test Suite

- 42 unit tests (`test/unit/GatedVaultTest.t.sol`)
- 4 mock unit tests (`test/unit/MockUSDCTest.t.sol`)
- 3 fuzz tests, 1000 runs each (`test/fuzz/GatedVaultFuzz.t.sol`)
- All passing.

## Coverage Snapshot

| File | Lines | Statements | Branches | Funcs |
|---|---:|---:|---:|---:|
| GatedVault.sol | 100% (52/52) | 100% (53/53) | 100% (9/9) | 100% (10/10) |
| MockERC777.sol | 100% (2/2) | 100% (1/1) | n/a | 100% (1/1) |
| MockUSDC.sol | 100% (4/4) | 100% (2/2) | n/a | 100% (2/2) |
| Total | 100% (58/58) | 100% (56/56) | 100% (9/9) | 100% (13/13) |

## Static Analysis

`slither .` (config: `slither.config.json`): `0 result(s) found` after triage of baseline 9 findings (4 medium incorrect-equality false positives, 4 low timestamp aggressive flags, 1 informational low-level-calls intentional staticcall).
