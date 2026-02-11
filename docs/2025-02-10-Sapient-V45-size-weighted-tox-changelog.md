# Sapient V45 — Size-weighted toxicity changelog

**Date:** 2025-02-10  
**Purpose:** Add **size-weighted toxicity** (CrocSwap-style) to V34: toxicity terms scaled by (1 + SIZE_TOX_COEF×sizeHat). Large typical trade size → higher tox-based fees.

**Reference:** [2025-02-10-alternative-fee-formulas-research.md](2025-02-10-alternative-fee-formulas-research.md) §6 — Formula: tox term × (1 + coef×sizeHat).

---

## What changed vs V34

- **New constant:** `SIZE_TOX_COEF = 5e17` (0.5 WAD). At sizeHat = WAD, effective toxicity multiplier = 1.5×.
- **Logic:** After computing `toxSignal` (toxEma) and `sizeHat`:
  - `sizeCap = min(sizeHat, WAD)` (cap so multiplier is bounded).
  - `sizeToxMult = WAD + wmul(SIZE_TOX_COEF, sizeCap)` → in [1, 1.5] when SIZE_TOX_COEF = 0.5.
  - `toxWeighted = wmul(toxSignal, sizeToxMult)`.
- **Fee build-up:** All toxicity-related terms now use `toxWeighted` instead of `toxSignal`:
  - fMid: linear tox, quadratic tox, sigma×tox, cubic tox.
  - Skew: dir×tox term.
  - Stale/attract: staleShift from toxWeighted.
- **No new slots.** Same 11 slots as V34.
- **Trade-aligned boost** still uses `tradeRatio` (unchanged).

---

## Validation

Run from `amm-challenge/` (with venv / amm-match on PATH):

```bash
amm-match run contracts/src/SapientStrategyV45.sol --simulations 1000
```

- **V34 baseline:** 524.63  
- **V45 result:** **524.63**

**Conclusion:** Size-weighted toxicity is **neutral** — same edge as V34 (524.63). No regression, no gain. V34 remains baseline. Next: try **vol regime (sigma / sigma_slow)**, **constant tuning**, or a different **SIZE_TOX_COEF** (e.g. 0.3 or 0.7) in a follow-up version.
