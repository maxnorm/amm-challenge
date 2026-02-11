# Sapient V47 — Momentum asymmetric fee (P2) changelog

**Date:** 2025-02-10  
**Purpose:** Add **momentum asymmetric fee** (P2): if the last price move was up (pImplied >= pHat), add a small bump to the **ask** (we're behind); else add to the **bid**. One slot, one constant. No ML.

**Reference:** P2 in [2025-02-10-next-formulas-innovative-research.md](2025-02-10-next-formulas-innovative-research.md) — section 3.3.

---

## What changed vs V34

- **New slot:** slots[11] = lastRetSign. WAD = price moved up last trade, 0 = down or unchanged.
- **New constant:** MOMENTUM_COEF = 2 * BPS (2 bps).
- **Logic:** In the pHat block we set retSignForNext = WAD if pImplied >= pHat, else 0. After tail compression we read lastRetSign = slots[11]: if lastRetSign >= WAD/2 we add MOMENTUM_COEF to ask and clamp; else add to bid and clamp. Then persist slots[11] = retSignForNext.
- **First trade:** slots[11] init to 0, so we add momentum to bid by default.

---

## Validation

Run from `amm-challenge/` (with venv / amm-match on PATH):

```bash
amm-match run contracts/src/SapientStrategyV47.sol --simulations 1000
```

- **V34 baseline:** 524.63  
- **V47 result:** **524.09**

**Conclusion:** Momentum asymmetric fee **slightly regressed** (524.09 < 524.63). V34 remains baseline. Next: try **dual sigma + dual lambda (P3)**, **constant tuning**, or a smaller MOMENTUM_COEF (e.g. 1 bps) in a follow-up version.
