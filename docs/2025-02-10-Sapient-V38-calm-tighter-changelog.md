# Sapient V38 — Calm vs stressed, tighter thresholds

**Date:** 2025-02-10  
**Purpose:** Same calm/stressed logic as V36 but **tighter** calm thresholds so we're calm less often (more often in stressed: +3 bps protect).

**Reference:** [2025-02-10-Sapient-V36-calm-stressed-changelog.md](2025-02-10-Sapient-V36-calm-stressed-changelog.md). V37 (looser) = 524.42.

---

## Threshold change vs V36

| Constant | V36 | V38 |
|----------|-----|-----|
| CALM_SIGMA_THRESH | 1e16 (1%) | **5e15 (0.5%)** |
| CALM_TOX_THRESH | 2e16 (2%) | **1e16 (1%)** |
| CALM_ATTRACT_DISCOUNT | 97e16 | 97e16 (unchanged) |
| STRESSED_PROTECT_BPS | 3 * BPS | 3 * BPS (unchanged) |

So in V38 we are in **calm** less often (only when sigma ≤ 0.5% and tox ≤ 1%); stressed (and the +3 bps protect) more often.

---

## Validation

```bash
amm-match run contracts/src/SapientStrategyV38.sol --simulations 1000
```

- **V34:** 524.63  
- **V36 (1%/2%):** 524.56  
- **V37 (2%/5% looser):** 524.42  
- **V38 (0.5%/1% tighter):** **523.98**

**Conclusion:** Tighter calm thresholds **hurt** the most (523.98 < 524.56 < 524.63). Across V36–V38, calm vs stressed never beats V34. **V34 remains best**; calm/stressed experiment complete — do not carry forward. Proceed with other unique angles or constant tuning (see [2025-02-10-improve-edge-from-V34.md](2025-02-10-improve-edge-from-V34.md)).
