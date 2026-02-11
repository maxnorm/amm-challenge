# Sapient Version Comparison — Best V21 for Edge

**Date:** 2025-02-10  
**Goal:** From all strategy versions V4–V21, choose the V21 with the highest chance of improving edge above the 380 plateau.

---

## Version lineage (summary)

| Version | Base / structure | Key add-ons | Edge / note |
|---------|------------------|-------------|-------------|
| **V4** | 30 bps, vol×imb multiplicative | Toxicity, trade-aligned boost (toxEma thresh), asymmetry | — |
| **V5** | 30 bps, vol×imb | Tox only vulnerable side, directionality, surge on gate | — |
| **V6** | 35 bps, vol×imb | Sym tox floor, dir (ret≥0.5%), surge 25 bps, cap 75 | — |
| **V7** | 35 bps, vol×imb | Dir only when ret≤gate, scaled surge 15–40, SYM_HIGH, size bump, cap 75 | **~380** |
| **V8** | 35 bps, vol×imb | V7 + pImplied, sigma×tox, cubic, trade boost, stale+attract, dirState, cap 85 | **Regressed ~379** |
| **V9** | — | Isolate V8 levers (cap/stale/dirState) | — |
| **V10** | 35 bps, V8 stack | + lambdaHat, sizeHat, flow in base (activity/flow) | — |
| **V11** | 35 bps, V10 | Tuned LAMBDA/FLOW + cap on flow term | — |
| **V12** | — | (intermediate) | — |
| **V13** | 35 bps, V11 | **+ first-in-step** pHat/sigma (dual alpha, sigma only first-in-step) | On heavy V8 stack |
| **V14** | **8 bps additive** (sigma+imb+vol+symTox), cap 75 | Same pipeline as V7 (tox, dir, surge, size); no stale/dirState/lambda | **380.13 plateau** |
| **V15** | V14 | **+ tail compression** (knee 5 bps, slope protect/attract), cap 85 | Structural; run result TBD |
| **V16** | V14 | Cap 10% experiment | — |
| **V17** | V14 | Cap 100 bps experiment | — |
| **V18** | V14 | + pImplied only (cleaner pHat/ret) | 380.13 |
| **V19** | V14 | + sigma×tox + cubic | 380.13 |
| **V20** | V14 | + trade-aligned toxicity boost (size-scaled, cap 25 bps) | 380.13 |
| **V21 (current)** | V20 | **Tuned constants only** (lower SIGMA/VOL/TOX/surge/dir/ASYMM/TRADE_TOX) | **No structural change** → unlikely to break 380 |

---

## Takeaways

1. **Plateau is on the V14 family.** V14 and every “V14 + one lever” (V18, V19, V20) score 380.13. Tuning constants (current V21) does not change structure.
2. **First-in-step exists only on the V8 family (V13).** It was never applied to the V14 family (8 bps additive, 75 cap). The V8 stack had already regressed, so first-in-step’s effect was never isolated on our best-scoring base.
3. **Tail compression exists on V15** (V14 + tail compression). Not combined with V20’s trade-aligned boost in a single version.
4. **Activity/flow exists on V10/V11/V13** (lambdaHat, sizeHat) but on the 35 bps base and 85 cap stack, not on V14.

---

## Best V21 for improving edge

**Recommendation:** Make V21 the **first structural change** on the V14/V20 base that the diagnosis prioritized: **first-in-step + dual alpha**.

- **What:** V20 (8 bps additive, tox, dir, surge, size, trade-aligned boost, cap 75) **+**  
  - One new slot: `stepTradeCount`.  
  - On **first trade in a step** (timestamp just advanced): use PHAT_ALPHA (0.26), update sigmaHat.  
  - On **later trades in the same step**: use PHAT_ALPHA_RETAIL (0.05), **do not** update sigmaHat.  
- **Why this V21:**  
  - Addresses **move-then-fade** and multi-trade noise (sigma and fast pHat only on first-in-step).  
  - Minimal change (one slot, clear logic), low risk.  
  - Aligns with leaderboard/YQ “first-in-step” and windowed behavior; highest-priority structural fix from [2025-02-10-Sapient-V20-amm-fee-designer-diagnosis.md](2025-02-10-Sapient-V20-amm-fee-designer-diagnosis.md).  
- **What to do with “V21 tuned” (current file):** Keep it as a separate variant (e.g. rename to a tuning branch or document as “V20-tuned”) if you want to A/B test; for “best V21” we replace it with **V20 + first-in-step**.

---

## If first-in-step alone doesn’t move edge

Next structural options (in order):

1. **Tail compression** (V14/V20 + tail like V15): replace hard 75 bps cap with knee + slope, then clamp.  
2. **Two regimes:** calm (sigma/tox below thresholds) → flat low fee; stress → full pipeline.  
3. **Activity/flow on V14 base:** add lambdaHat, sizeHat, LAMBDA_COEF, FLOW_SIZE_COEF to the additive base (share stepTradeCount with first-in-step).

---

## Changelog

- **2025-02-10:** Version comparison; recommendation: best V21 = V20 + first-in-step + dual alpha; doc created.
