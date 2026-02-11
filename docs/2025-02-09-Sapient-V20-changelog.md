# Sapient V20 — Changelog

**Date:** 2025-02-09  
**Base:** V14 (low base + additive, 75 bps cap).  
**Change:** Add trade-aligned toxicity boost when the current trade is toxic.

## Summary

- **Toxic trade:** (isBuy && spot ≥ pHat) or (!isBuy && spot < pHat).
- **Boost:** `TRADE_TOX_BOOST × min(tradeRatio, TRADE_RATIO_CAP)` applied to the side being hit (bid if isBuy, ask if sell), capped at `CAP_TRADE_BOOST`.
- **Constants:** TRADE_TOX_BOOST = 25e14 (25 bps per unit trade ratio), CAP_TRADE_BOOST = 25e14. Reuses TRADE_RATIO_CAP = 20e16 from V14.
- **Slots:** 0 new.

## Reference

- [2025-02-09-Sapient-other-levers-research.md](2025-02-09-Sapient-other-levers-research.md) — Section D (trade-aligned boost), Step 7 (priority 3)
- [2025-02-09-Sapient-V18-pImplied-only-plan.md](2025-02-09-Sapient-V18-pImplied-only-plan.md) — §6 next levers

## Simulation

Run: `amm-match run contracts/src/SapientStrategyV20.sol --simulations 1000`  
Target: edge ≥ 382 (break 380 plateau).
