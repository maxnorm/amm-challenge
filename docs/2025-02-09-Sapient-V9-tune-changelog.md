# Sapient V9 — Tune Changelog (V8 tuning)

**Date:** 2025-02-09  
**Contract:** [amm-challenge/contracts/src/SapientStrategyV9.sol](../amm-challenge/contracts/src/SapientStrategyV9.sol)

V9 is V8 with one set of tuned constants to test whether cap, stale+attract, or dirState skew caused the V8 regression (V8 edge 378.99 vs V7 380.14).

---

## Tunes applied

| Constant      | V8 value | V9 value | Effect |
|---------------|----------|----------|--------|
| MAX_FEE_CAP   | 85e14    | 75e14    | Cap back to 75 bps (same as V7). |
| STALE_COEF    | 68e14    | 0        | No stale shift added to vulnerable side. |
| ATTRACT_FRAC  | 1124e15  | 0        | No attract subtraction from other side. |
| DIR_COEF      | 20e14    | 0        | No dirState skew (bps per dirDev). |
| DIR_TOX_COEF  | 10e14    | 0        | No dirState×tox term in skew. |

Logic and all other constants are unchanged: pImplied, sigma×tox, cubic tox, trade-aligned boost, dir/surge/size, time-consistent decay, and dirState update still run; only the **fee impact** of stale+attract and dirState skew is removed, and the cap is lowered to 75 bps.

---

## How to run

From `amm-challenge`:

```bash
amm-match run contracts/src/SapientStrategyV9.sol --simulations 1000
```

Compare edge to V7 (380.14) and V8 (378.99). If V9 > 378.99, the regression was likely from cap 85 and/or stale/attract and/or dirState skew. If V9 ≈ 380 or above, we can try re-enabling one of the tuned levers (e.g. cap 85 only) in a follow-up variant.
