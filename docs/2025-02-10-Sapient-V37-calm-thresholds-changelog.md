# Sapient V37 — Calm vs stressed, different thresholds

**Date:** 2025-02-10  
**Purpose:** Same calm/stressed logic as V36 but **looser** calm thresholds so we classify as calm more often (more attract discount, less stressed bump).

**Reference:** [2025-02-10-Sapient-V36-calm-stressed-changelog.md](2025-02-10-Sapient-V36-calm-stressed-changelog.md). V36: 524.56 (1% sigma, 2% tox).

---

## Threshold change vs V36

| Constant | V36 | V37 |
|----------|-----|-----|
| CALM_SIGMA_THRESH | 1e16 (1%) | **2e16 (2%)** |
| CALM_TOX_THRESH | 2e16 (2%) | **5e16 (5%)** |
| CALM_ATTRACT_DISCOUNT | 97e16 | 97e16 (unchanged) |
| STRESSED_PROTECT_BPS | 3 * BPS | 3 * BPS (unchanged) |

So in V37 we are in **calm** more often (sigma ≤ 2% and tox ≤ 5%), and apply the 0.97 attract discount more; stressed (and the +3 bps protect) less often.

---

## Validation

```bash
amm-match run contracts/src/SapientStrategyV37.sol --simulations 1000
```

- **V34:** 524.63  
- **V36 (1%/2%):** 524.56  
- **V37 (2%/5% looser):** **524.42**

**Conclusion:** Looser calm thresholds **hurt** (524.42 < 524.56). So far: **V34 (no calm/stressed) is best**. Next option: try **tighter** thresholds (e.g. 0.5% sigma, 1% tox) in V38 to see if rarely-calm + more stressed bump helps; otherwise stay on V34.
