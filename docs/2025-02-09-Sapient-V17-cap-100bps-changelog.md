# Sapient V17 — Changelog (V14 with cap 100 bps)

**Date:** 2025-02-09  
**Contract:** [amm-challenge/contracts/src/SapientStrategyV17.sol](../amm-challenge/contracts/src/SapientStrategyV17.sol)

V17 is V14 (low base + additive) with **MAX_FEE_CAP = 100e14** (100 bps = 1%). Intermediate between V14 (75 bps), V15 (85 bps), and V16 (10% — which collapsed edge to 72.59). Tests whether ~25 bps extra headroom helps without volume/adverse-selection collapse.

---

## Summary of changes

- **MAX_FEE_CAP:** `75e14` (75 bps) → **`100e14`** (100 bps = 1%).
- All other logic unchanged from V14.

---

## How to run

From `amm-challenge`:

```bash
amm-match run contracts/src/SapientStrategyV17.sol --simulations 1000
```

Compare edge to V14 (380.13), V15 (85 bps, 380.02), and V16 (10%, 72.59).
