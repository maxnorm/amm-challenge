# Sapient V36 — Calm vs stressed regime changelog

**Date:** 2025-02-10  
**Purpose:** Add **calm vs stressed** regime (unique angle 2.2) to V34. In calm: discount the attract side to invite rebalancing; in stressed: add a small amount to the protect side for wider spread. No new slots.

**Reference:** [2025-02-10-V34-explanation-and-unique-angles.md](2025-02-10-V34-explanation-and-unique-angles.md) — section 2.2.

---

## What changed vs V34

- **Regime classification:** Calm when `sigmaHat <= CALM_SIGMA_THRESH` **and** `toxSignal <= CALM_TOX_THRESH`; otherwise stressed.
- **Constants:**
  - `CALM_SIGMA_THRESH = 1e16` (1% in WAD)
  - `CALM_TOX_THRESH = 2e16` (2% in WAD)
  - `CALM_ATTRACT_DISCOUNT = 97e16` (0.97): in calm, attract-side fee is multiplied by this
  - `STRESSED_PROTECT_BPS = 3 * BPS` (3 bps): in stressed, this is added to the protect side
- **Block placement:** After trade-aligned boost, before tail compression.
- **Calm:** If sellPressure then ask (attract) *= 0.97; else bid (attract) *= 0.97.
- **Stressed:** If sellPressure then bid += 3 bps; else ask += 3 bps. Tail compression then applies.

**Slots:** No new slots; uses existing sigmaHat and toxSignal.

---

## Validation

Run from `amm-challenge/` with venv:

```bash
amm-match run contracts/src/SapientStrategyV36.sol --simulations 1000
```

- **V34 baseline:** 524.63
- **V36 result:** **524.56** (marginal regression of ~0.07)

**Conclusion:** Calm vs stressed is roughly neutral; slight drop. Keep **V34** as baseline. Optional: try tuning (e.g. different CALM_SIGMA_THRESH / CALM_TOX_THRESH, or stronger discount / smaller stressed bump) in a later variant; otherwise move on to another unique angle.
