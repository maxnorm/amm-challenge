# Sapient V19 — Changelog

**Date:** 2025-02-09  
**Base:** V14 (low base + additive, 75 bps cap).  
**Change:** Add sigma×tox and cubic tox to vulnerable-side toxicity premium only.

## Summary

- **SIGMA_TOX_COEF** = 50e14 (50 bps per sigma×tox)
- **TOX_CUBIC_COEF** = 15e14 (15 bps per tox³)
- **Slots:** 0 new (same as V14)
- **Formula:** `toxPremium += SIGMA_TOX_COEF * sigmaHat * toxEma` and `toxPremium += TOX_CUBIC_COEF * toxEma³`; applied to vulnerable side only (same logic as V14).

## Reference

- [2025-02-09-Sapient-other-levers-research.md](2025-02-09-Sapient-other-levers-research.md) — Section C, Step 7 (priority 2)
- [2025-02-09-Sapient-V18-pImplied-only-plan.md](2025-02-09-Sapient-V18-pImplied-only-plan.md) — §6 next levers

## Simulation

Run: `amm-match run contracts/src/SapientStrategyV19.sol --simulations 1000`  
**Result (1000 sims): Edge 380.13** — same as V14/V18; sigma×tox + cubic tox did not break the plateau.  
**Next:** Try V20 (trade-aligned boost) per [2025-02-09-Sapient-V18-pImplied-only-plan.md](2025-02-09-Sapient-V18-pImplied-only-plan.md) §6.
