# Sapient V12 — Changelog (Tail compression)

**Date:** 2025-02-09  
**Contract:** [amm-challenge/contracts/src/SapientStrategyV12.sol](../amm-challenge/contracts/src/SapientStrategyV12.sol)

V12 is V8 with **tail compression** instead of a hard cap on the final fee. No new slots; same pipeline up to dirState skew, then compress each side above a knee with a slope before clamping to 85 bps.

---

## Summary of changes

1. **Tail compression (like YQ)**  
   Above `TAIL_KNEE` (5 bps), fee becomes `knee + slope × (fee - knee)` instead of a hard clip.  
   - **Protect side** (the one we’re charging more): `TAIL_SLOPE_PROTECT = 0.93`.  
   - **Attract side**: `TAIL_SLOPE_ATTRACT = 0.955`.  
   Then clamp to `MAX_FEE_CAP` (85 bps).

2. **Which side is protect**  
   `sellPressure = (dirState >= ONE_WAD)`.  
   - If sell pressure: bid is protect, ask is attract.  
   - Else: ask is protect, bid is attract.

3. **New helper**  
   `_compressTailWithSlope(fee, slope)`: if `fee <= TAIL_KNEE` return fee; else return `TAIL_KNEE + _wmul(fee - TAIL_KNEE, slope)`.

4. **Constants added**  
   `TAIL_KNEE = 5e14`, `TAIL_SLOPE_PROTECT = 93e16`, `TAIL_SLOPE_ATTRACT = 955e15`.

---

## How to run

From `amm-challenge`:

```bash
amm-match run contracts/src/SapientStrategyV12.sol --simulations 1000
```

Compare edge to V8 (~378.99) and V7 (380.14).

---

## References

- [2025-02-09-YQ-extract-for-Sapient.md](2025-02-09-YQ-extract-for-Sapient.md) — Section 10 (Tail compression).
- [2025-02-09-Sapient-audit-380-vs-526.md](2025-02-09-Sapient-audit-380-vs-526.md) — Recommendation: tail compression as structural change.
