# Sapient V48 — Dual sigma + dual lambda (P3) changelog

**Date:** 2025-02-10  
**Purpose:** Add **dual sigma** and **dual lambda**: slower EMAs (sigma_slow, lambda_slow). Fee bump when sigma/sigma_slow > 1.1 (vol regime) or lambda/lambda_slow > 1.2 (activity regime).

**Reference:** P3 in [2025-02-10-next-formulas-innovative-research.md](2025-02-10-next-formulas-innovative-research.md) — section 3.4.

---

## What changed vs V34

- **New slots:** slots[11] = sigma_slow, slots[12] = lambda_slow.
- **Constants:** SIGMA_SLOW_DECAY = 0.95, LAMBDA_SLOW_DECAY = 0.95; VOL_REGIME_THRESH = 1.1 WAD, ACTIVITY_REGIME_THRESH = 1.2 WAD; VOL_REGIME_COEF = 2 BPS, ACTIVITY_REGIME_COEF = 2 BPS.
- **Updates:** When firstInStep we update sigmaHat and sigma_slow = blend(sigma_slow, sigmaHat) with SIGMA_SLOW_DECAY. In the new-step block when we update lambdaHat, also lambda_slow = blend(lambda_slow, lambdaHat) with LAMBDA_SLOW_DECAY.
- **Fee:** After building fMid (incl. cubic tox), if sigma_slow > 0 and sigmaHat > sigma_slow * 1.1 then fMid += VOL_REGIME_COEF; if lambda_slow > 0 and lambdaHat > lambda_slow * 1.2 then fMid += ACTIVITY_REGIME_COEF.
- **afterInitialize:** slots[11] = initial sigma (95e13), slots[12] = initial lambda (0.8e18).

---

## Validation

Run from `amm-challenge/` (with venv / amm-match on PATH):

```bash
amm-match run contracts/src/SapientStrategyV48.sol --simulations 1000
```

- **V34 baseline:** 524.63  
- **V48 result:** **524.40**

**Conclusion:** Dual sigma + dual lambda **slightly regressed** (524.40 < 524.63). V34 remains baseline. Next: **constant tuning** or try different thresholds/coefs (e.g. VOL_REGIME_THRESH 1.15, or smaller regime coefs) in a follow-up version.
