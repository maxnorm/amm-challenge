# Sapient V33 — Fee path never reads slots 5,6,7 (bug isolate)

**Date:** 2025-02-10

## Goal

Isolate whether the 40.30 regression is caused by **reading** slots 5,6,7 in the fee path (even when activity coefficients are 0) or by **writing** to slots 5,6,7,8 in the activity block.

## Change

- **Base:** SapientStrategyV28 (pHat write-order fix + scaled activity coefs; terms were already 0 in V27 and we kept the same formula).
- **V33:** In `_computeRawFeeAdditive`, the three lines that read `slots[SLOT_LAMBDA_HAT]`, `slots[SLOT_SIZE_HAT]`, `slots[SLOT_ACT_EMA]` and add `LAMBDA_COEF*lambdaHat`, `FLOW_SIZE_COEF*lambdaHat*sizeHat`, `ACT_COEF*actEma` are **removed**.
- The activity block (step decay, blend, step count, writes to slots 5,6,7,8) still runs in `after_swap`; only the fee formula no longer reads those slots.
- So the **raw fee formula is byte-identical to V23** (base + sigma + imb + vol + symTox + floor + decay); no SLOAD of slots 5,6,7 in the fee path.

## How to run

From `amm-challenge` (with project deps and `amm-match` on PATH, e.g. venv):

```bash
amm-match run contracts/src/SapientStrategyV33.sol --simulations 1000
```

## Interpretation

- **If edge ≈ 380:** The bug was **reading** slots 5,6,7 in the fee path (e.g. compiler/stack/optimizer side effect when those SLOADs are present). Next: keep activity state for other use, but never read 5,6,7 in the fee formula; or refactor so activity lives in different storage.
- **If edge ≈ 40.30:** The bug is **writing** to 5,6,7,8 (or some other effect of the activity block), not the reads. Next: minimal repro that only writes to one of 5,6,7,8 and see which write causes 40; or strip activity entirely and keep V23/V29 as production.
