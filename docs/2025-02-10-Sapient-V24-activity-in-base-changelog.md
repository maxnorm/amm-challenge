# Sapient V24 — Activity in the base

**Date:** 2025-02-10  
**Purpose:** Add YQ-style activity in the base (λ, flowSize, actEma) on top of V23 (3 bps base + tail compression), to test “low base + activity build-up” without the full V22 stack that regressed to 128.

**Reference:** [2025-02-10-BASE-LOW-3bps-edge-unchanged-analysis.md](2025-02-10-BASE-LOW-3bps-edge-unchanged-analysis.md), [2025-02-10-Sapient-V23-vs-YQ-structural-comparison.md](2025-02-10-Sapient-V23-vs-YQ-structural-comparison.md).

---

## 1. What changed vs V23

- **New persistent state (slots 5–8):**
  - `lambdaHat` — trades-per-step estimate; on new step: `lambdaInst = stepTradeCount/elapsed` (capped), blended with decay.
  - `sizeHat` — smoothed trade size (tradeRatio); blended when `tradeRatio > SIGNAL_THRESHOLD`; decay on new step.
  - `actEma` — activity EMA from tradeRatio; same blend/decay.
  - `stepTradeCount` — number of trades in current step; reset to 0 on new step; capped at 64.

- **Step logic:**
  - `isNewStep = (trade.timestamp > lastTs)`.
  - On new step: `actEma` and `sizeHat` decay by `ACT_DECAY^elapsed` and `SIZE_DECAY^elapsed` (elapsed capped at 8); `lambdaHat` updated from `stepTradeCount/elapsedRaw` (capped at 5); `stepTradeCount` set to 0.
  - `_powWad(factor, exp)` used for step-based decay.

- **Blend on trade:**
  - When `tradeRatio > SIGNAL_THRESHOLD` (~0.2%): blend `tradeRatio` into `actEma` and `sizeHat` with `ACT_BLEND_DECAY` and `SIZE_BLEND_DECAY`; cap `sizeHat` at 1 WAD.
  - After processing, `stepTradeCount` incremented and capped.

- **Base fee (raw fee) add-ons:**
  - `rawFee += LAMBDA_COEF * lambdaHat`
  - `rawFee += FLOW_SIZE_COEF * (lambdaHat * sizeHat)` (flowSize)
  - `rawFee += ACT_COEF * actEma`
  - Existing V23 terms (sigma, imb, vol, symTox, floor, time-decay) unchanged.

- **Constants (YQ-aligned):**
  - `ELAPSED_CAP = 8`, `SIGNAL_THRESHOLD = 2e15`, `ACT_DECAY = 0.70`, `SIZE_DECAY = 0.70`, `LAMBDA_DECAY = 0.99`, `LAMBDA_CAP = 5e18`, `STEP_COUNT_CAP = 64`
  - `LAMBDA_COEF = 12e14`, `FLOW_SIZE_COEF = 4842e14`, `ACT_COEF = 91843e14`
  - `SIZE_BLEND_DECAY = 0.818`, `ACT_BLEND_DECAY = 0.985`

- **Initialization:** `lambdaHat = 0.8`, `sizeHat = 0.2%`, `actEma = 0`, `stepTradeCount = 0`.

- **Stack-too-deep fix:** Logic split into helpers and temp slots (no foundry config change): `_applyStepDecayAndLambda`, `_blendActivityOnTrade`, `_computeSpotPhatRetGate`; temp slots 16–18 for spot, ret, adaptiveGate.

---

## 2. What is unchanged vs V23

- Base 3 bps, sigma/imb/vol/symTox, imbalance floor, time-decay toward floor.
- pHat/sigma update every trade (no first-in-step).
- Toxicity from spot vs pHat; vulnerable-side tox premium; dir/surge/size; trade-aligned boost; tail compression by reserve imbalance; 75 bps cap.
- No pImplied, no dirState, no stale/attract.

---

## 3. How to run and compare

From `amm-challenge`:

```bash
amm-match run contracts/src/SapientStrategyV24.sol --simulations 1000
```

Compare edge to:
- **V23** (~379.74 with 3 bps base)
- **V22** (128 when adding full YQ-like stack)
- **YQ** (~520)

---

## 4. Interpretation

- If **V24 edge ≈ V23 (~380):** Activity terms may be small in this sim, or our existing base (imb/vol/symTox) already captures most of what activity adds in YQ.
- If **V24 edge &gt; V23:** “Low base + activity in base” helps; next step could be tuning coefs or adding one more YQ piece (e.g. pImplied or first-in-step) in isolation.
- If **V24 edge &lt;&lt; V23 (e.g. toward 128):** Activity coefs may be too large (overcharge) or interaction with our imb/vol/floor is wrong; try lower `ACT_COEF` / `FLOW_SIZE_COEF` or reduce imbalance/vol weight when activity is present.
