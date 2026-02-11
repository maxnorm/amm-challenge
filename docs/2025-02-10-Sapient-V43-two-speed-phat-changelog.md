# Sapient V43 — Two-speed pHat changelog

**Date:** 2025-02-10  
**Purpose:** Add **two-speed pHat** (unique angle 2.7) to V34. Maintain pHat_slow (slower EMA); when |pHat - pHat_slow|/pHat_slow > threshold, add a fee term (regime change).

**Reference:** [2025-02-10-V34-explanation-and-unique-angles.md](2025-02-10-V34-explanation-and-unique-angles.md) — section 2.7.

---

## What changed vs V34

- **New slot:** `slots[11] = pHat_slow` — slower EMA of fair price (alpha 0.05 when we blend pImplied into pHat).
- **New constants:**
  - `PHAT_SLOW_ALPHA = 5e16` (0.05)
  - `GAP_THRESH = 1e16` (1%) — add fee only when gap above this
  - `GAP_CAP = 1e17` (10%)
  - `GAP_COEF = 10 * BPS`
- **Logic:** When we update pHat from pImplied (ret <= adaptiveGate), also update pHat_slow = wmul(pHat_slow, WAD - PHAT_SLOW_ALPHA) + wmul(pImplied, PHAT_SLOW_ALPHA). After building fMid (post cubic tox), gap = |pHat - pHat_slow|/pHat_slow (capped at GAP_CAP); if gap > GAP_THRESH, fMid += wmul(GAP_COEF, gap). Gate/tox still use pHat (fast).
- **afterInitialize:** Set slots[11] = same as slots[5] (initial price).
- **Stack:** `forge build` in-contracts may report stack too deep; **amm-match** compiles and runs the strategy (uses py-solc-x). Use `amm-match run` for validation.

---

## Validation

Run from `amm-challenge/` with venv:

```bash
amm-match run contracts/src/SapientStrategyV43.sol --simulations 1000
```

- **V34 baseline:** 524.63  
- **V43 result:** **524.63**

**Conclusion:** Two-speed pHat is **neutral** — same edge as V34. No regression, no gain. V34 remains baseline. Next: try **size-dependent attract (2.8)** or **constant tuning**.
