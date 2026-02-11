# Sapient V10 — Changelog (Activity/Flow in Base)

**Date:** 2025-02-09  
**Contract:** [amm-challenge/contracts/src/SapientStrategyV10.sol](../amm-challenge/contracts/src/SapientStrategyV10.sol)

Sapient V10 adds the **activity/flow in base** structural change from the audit: **lambdaHat** (trades per step), **sizeHat** (smoothed trade size), and **stepTradeCount**, with fee terms `LAMBDA_COEF×lambdaHat` and `FLOW_SIZE_COEF×lambdaHat×sizeHat` in the base fee. Baseline is V8.

---

## Summary of changes

1. **New persistent slots (3)**  
   - `SLOT_LAMBDA_HAT = 8` — EMA of trades-per-step (instantaneous lambda per step).  
   - `SLOT_SIZE_HAT = 9` — Smoothed trade size (tradeRatio), blended when tradeRatio > SIGNAL_THRESHOLD, decayed on new step.  
   - `SLOT_STEP_TRADE_COUNT = 16` — Number of trades in the current step (reset to 0 on new step, incremented each trade, capped at STEP_COUNT_CAP).

2. **New-step block**  
   When `trade.timestamp > lastTs`:  
   - If `stepTradeCount > 0` and `elapsedRaw > 0`: compute `lambdaInst = (stepTradeCount * WAD) / elapsedRaw`, cap at LAMBDA_CAP; update `lambdaHat = LAMBDA_DECAY*lambdaHat + (1 - LAMBDA_DECAY)*lambdaInst`.  
   - Decay `sizeHat = sizeHat * SIZE_DECAY^elapsed`.  
   - Set `stepTradeCount = 0`.

3. **Per-trade updates**  
   - If `tradeRatioForDir > SIGNAL_THRESHOLD`: `sizeHat = SIZE_BLEND_DECAY*sizeHat + (1 - SIZE_BLEND_DECAY)*tradeRatioForDir`, cap sizeHat at ONE_WAD.  
   - Unconditionally: `stepTradeCount = stepTradeCount + 1`, cap at STEP_COUNT_CAP.

4. **Base fee**  
   After `rawFee = _computeRawFee(...)`:  
   - `flowSize = lambdaHat * sizeHat` (WAD).  
   - `rawFee += LAMBDA_COEF*lambdaHat + FLOW_SIZE_COEF*flowSize`.  
   Then `baseFee = min(rawFee, MAX_FEE_CAP)` as before.

5. **Initialization**  
   - `slots[SLOT_LAMBDA_HAT] = 8e17` (0.8), `slots[SLOT_SIZE_HAT] = 2e15` (0.2%), `slots[SLOT_STEP_TRADE_COUNT] = 0`.

---

## New constants

| Constant           | Value   | Description |
|--------------------|---------|-------------|
| LAMBDA_DECAY       | 99e16   | 0.99 EMA for lambdaHat |
| LAMBDA_COEF        | 12e14   | 12 bps per unit lambdaHat |
| LAMBDA_CAP         | 5e18    | Max 5 trades/step (WAD) |
| SIZE_DECAY         | 70e16   | 0.70 decay per elapsed step for sizeHat |
| SIZE_BLEND_DECAY   | 818e15  | 0.818 blend for sizeHat update |
| STEP_COUNT_CAP     | 64      | Cap on stepTradeCount |
| FLOW_SIZE_COEF     | 48e14   | 48 bps per unit flowSize (scaled down from YQ) |

---

## Slot usage (V10)

| Slot    | Content          |
|---------|------------------|
| 0       | pHat             |
| 1       | volatility       |
| 2       | timestamp        |
| 3       | sigmaHat         |
| 4       | toxEma           |
| 5       | prevBidFee       |
| 6       | prevAskFee       |
| 7       | dirState         |
| 8       | lambdaHat        |
| 9       | sizeHat          |
| 10–15   | temp (reserves, timestamp, isBuy, amountY, vol) |
| 16      | stepTradeCount   |

---

## References

- [2025-02-09-Sapient-audit-380-vs-526.md](2025-02-09-Sapient-audit-380-vs-526.md) — Audit and activity/flow recommendation.
- [2025-02-09-YQ-extract-for-Sapient.md](2025-02-09-YQ-extract-for-Sapient.md) — YQ lambdaHat, sizeHat, flowSize (sections 5–6).

---

## Verification

- **Build:** From `amm-challenge/contracts`, run `forge build --skip test`. (Note: the repo may have another file that hits stack-too-deep; V10 does not change Foundry config.)
- **Run:** From `amm-challenge`, run:
  ```bash
  amm-match run contracts/src/SapientStrategyV10.sol --simulations 1000
  ```
  Compare edge to V7 (~380.14) and V8 (~378.99).
