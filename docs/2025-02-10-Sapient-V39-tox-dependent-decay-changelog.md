# Sapient V39 — Tox-dependent dirState decay changelog

**Date:** 2025-02-10  
**Purpose:** Add **tox-dependent decay** (unique angle 2.6) to V34. When `toxEma` is high at a new step, decay `dirState` faster toward neutral so we don't carry stale direction in stressed regimes.

**Reference:** [2025-02-10-V34-explanation-and-unique-angles.md](2025-02-10-V34-explanation-and-unique-angles.md) — section 2.6.

---

## What changed vs V34

- **New constants:**
  - `DIR_DECAY_STRESSED = 0.60` (WAD) — used for dirState decay when tox is high (V34 uses 0.80 for all).
  - `TOX_DECAY_STRESSED_THRESH = 2e16` (2% in WAD) — when `toxEma >=` this at step boundary, use `DIR_DECAY_STRESSED` instead of `DIR_DECAY`.
- **Logic (new-step block):** Before `dirState = _decayCentered(dirState, DIR_DECAY, elapsed)`, set  
  `dirDecay = toxEma >= TOX_DECAY_STRESSED_THRESH ? DIR_DECAY_STRESSED : DIR_DECAY`  
  and use `dirDecay` in `_decayCentered`. So in high-tox steps we decay direction faster toward WAD (neutral).
- **Slots:** No new slots; uses existing `toxEma` (read at start of trade, before step decay).

---

## Validation

Run from `amm-challenge/` with venv:

```bash
amm-match run contracts/src/SapientStrategyV39.sol --simulations 1000
```

- **V34 baseline:** 524.63  
- **V39 result:** **524.63**

**Conclusion:** Tox-dependent decay is **neutral** — same edge as V34. No regression, no gain. V34 remains baseline; V39 can be kept as an equivalent variant. Next: try another angle (e.g. silence risk 2.4) or constant tuning.
