# Sapient V20 — Tuning for Challenge (Avg Fee 75 bps → lower)

**Date:** 2025-02-09  
**Context:** V20 submitted to challenge: **Avg Edge +378.94**, **Avg Fee 75.0 bps**, Arb 11.97K, Retail 41.34K. Edge distribution ~258–537 (some sims much better).

## Diagnosis

- **Avg Fee = 75.0 bps** → We are at the **cap** almost all the time. So pre-clamp fee is often ≥ 75 bps.
- **Implication:** We may be over-charging on average → retail routes to the 30 bps normalizer more, and we only hit the high-edge cases when we’re not pegged. The histogram shows we *can* reach 500+ edge in some sims; those may be where we’re not always at cap.
- **Tuning goal:** Reduce coefficients so **average fee is ~65–72 bps** instead of 75. That gives headroom, more retail volume, and may shift the edge distribution right.

## Levers to tune (V20 → V21)

| Constant | V20 | V21 (tuned) | Rationale |
|----------|-----|-------------|-----------|
| SIGMA_COEF | 15e18 | 12e18 | ~15 → ~12 bps per 1% sigma |
| VOL_COEF | 15e18 | 12e18 | Same; vol term often large |
| TOX_COEF | 25e14 | 20e14 | 25 → 20 bps per unit tox |
| TOX_QUAD_COEF | 60e14 | 50e14 | 60 → 50 bps per tox² |
| SURGE_BASE | 15e14 | 12e14 | 15 → 12 bps min surge |
| CAP_SURGE | 40e14 | 35e14 | 40 → 35 bps max surge |
| CAP_DIR_BPS | 30e14 | 25e14 | 30 → 25 bps max dir |
| ASYMM | 60e16 | 55e16 | 60% → 55% extra on vulnerable |
| TRADE_TOX_BOOST | 25e14 | 18e14 | 25 → 18 bps per unit trade ratio (toxic) |
| CAP_TRADE_BOOST | 25e14 | 18e14 | Match boost |

**Unchanged:** BASE_LOW (8 bps), IMB_COEF, MAX_FEE_CAP (75), sym tox, K_SIZE/CAP_SIZE_BPS, PHAT/sigma/tox alpha, decay. We keep the same structure and cap; we only soften the additive terms so we don’t hit cap every time.

## What to measure after submit

- **Avg Fee:** Target 65–72 bps (clearly below 75).
- **Avg Edge:** Hope for ≥ 379 or higher (distribution shifts right).
- **Avg Retail Volume:** May increase if we’re less often at 75 bps.

If V21 avg fee is still ~75, try a second pass (e.g. lower SIGMA/VOL/TOX again or reduce BASE_LOW slightly). If avg fee drops but edge drops too, try a milder tune (e.g. only SURGE + TRADE_TOX_BOOST).
