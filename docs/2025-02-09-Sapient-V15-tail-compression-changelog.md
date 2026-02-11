# Sapient V15 — Changelog (V14 + tail compression)

**Date:** 2025-02-09  
**Contract:** [amm-challenge/contracts/src/SapientStrategyV15.sol](../amm-challenge/contracts/src/SapientStrategyV15.sol)

V15 adds **tail compression** on top of V14 (low base + additive). No new slots; cap raised to 85 bps. Protect vs attract is determined by reserve imbalance (same as vulnerable side: reserveY ≥ reserveX → bid protect, ask attract).

---

## Summary of changes

1. **Tail compression (like YQ / V12)**  
   Above `TAIL_KNEE` (5 bps), fee becomes `knee + slope × (fee − knee)` instead of a hard clip.  
   - **Protect side** (the side we charge more): `TAIL_SLOPE_PROTECT = 0.93`.  
   - **Attract side**: `TAIL_SLOPE_ATTRACT = 0.955`.  
   Then clamp to `MAX_FEE_CAP` (85 bps).

2. **Which side is protect**  
   V15 has no dirState. We use the same rule as for asym: **reserveY ≥ reserveX** → bid is protect (vulnerable), ask is attract; else ask is protect, bid is attract.

3. **Cap**  
   `MAX_FEE_CAP` raised from 75 to **85 bps** (after compression).

4. **New helper**  
   `_compressTailWithSlope(fee, slope)`: if `fee ≤ TAIL_KNEE` return fee; else return `TAIL_KNEE + _wmul(fee − TAIL_KNEE, slope)`.

5. **Constants added**  
   `TAIL_KNEE = 5e14`, `TAIL_SLOPE_PROTECT = 93e16`, `TAIL_SLOPE_ATTRACT = 955e15`.

---

## How to run

From `amm-challenge`:

```bash
amm-match run contracts/src/SapientStrategyV15.sol --simulations 1000
```

Compare edge to V14 (380.13) and V7 (380.14).

---

## References

- [2025-02-09-Sapient-V14-amm-fee-designer-analysis.md](2025-02-09-Sapient-V14-amm-fee-designer-analysis.md) — Recommendation: tail compression on V14.
- [2025-02-09-Sapient-V12-changelog.md](2025-02-09-Sapient-V12-changelog.md) — V12 tail compression (with dirState).
- [2025-02-09-YQ-extract-for-Sapient.md](2025-02-09-YQ-extract-for-Sapient.md) — Section 10 (Tail compression).
