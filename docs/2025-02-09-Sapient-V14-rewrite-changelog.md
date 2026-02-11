# Sapient V14 — Rewrite Changelog (Low base + additive)

**Date:** 2025-02-09  
**Contract:** [amm-challenge/contracts/src/SapientStrategyV14.sol](../amm-challenge/contracts/src/SapientStrategyV14.sol)

V14 is a **rewrite** of the base fee formula only: replace multiplicative base (35 bps × vol × imb) with **low base + additive** terms. All downstream logic (tox premium, asym, dir, surge, size bump, cap) is unchanged from V7.

---

## Summary of changes

1. **Base formula**
   - **Before (V7):** `rawFee = BASE_FEE * (1 + K_VOL*vol) * (1 + K_IMB*imbalance)` then add symTox, floor, decay.
   - **After (V14):** `fBase = BASE_LOW + SIGMA_COEF*sigmaHat + IMB_COEF*imbalance + VOL_COEF*vol + symTox(toxEma)` then same floor and decay (floor = BASE_LOW + FLOOR_IMB_SCALE*imbalance).

2. **Constants**
   - Removed: `BASE_FEE`, `K_IMB`, `K_VOL`.
   - Added: `BASE_LOW = 8e14` (8 bps), `SIGMA_COEF = 15e18`, `IMB_COEF = 100e14`, `VOL_COEF = 15e18`.
   - Unchanged: `FLOOR_IMB_SCALE`, `DECAY_FACTOR`, `MAX_FEE_CAP` (75 bps), all toxicity/dir/surge/size constants.

3. **Helper**
   - Replaced `_computeRawFee(vol, toxEma, lastTs)` with `_computeRawFeeAdditive(vol, sigmaHat, toxEma, lastTs)`; imbalance and timestamp read from temp slots inside.

4. **Init**
   - `afterInitialize` returns `(BASE_LOW, BASE_LOW)` instead of `(BASE_FEE, BASE_FEE)`.

5. **Slots**
   - No new slots; same layout as V7 (0–4 persistent, 10–15 temp).

---

## How to run

From `amm-challenge` (with project deps installed: `pip install -e .` and `amm-match` on PATH, or use `python3 -m amm_competition.cli`):

```bash
amm-match run contracts/src/SapientStrategyV14.sol --simulations 1000
```

Compare edge to V7 (380.14). If the CLI is not installed, run from repo root: `python3 -m amm_competition.cli run contracts/src/SapientStrategyV14.sol --simulations 1000`. Tune BASE_LOW, SIGMA_COEF, IMB_COEF, VOL_COEF if needed for edge ≥ 380 and calm-regime fee ~28–35 bps.

---

## References

- [docs/plans/2025-02-09-rewrite-low-base-additive-design.md](plans/2025-02-09-rewrite-low-base-additive-design.md) — Design and formulas.
- [2025-02-09-Sapient-what-works-next-big-thing.md](2025-02-09-Sapient-what-works-next-big-thing.md) — Option B (low base + additive).
