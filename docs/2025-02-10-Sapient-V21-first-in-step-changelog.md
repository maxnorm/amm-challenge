# Sapient V21 — First-in-step + dual alpha (changelog)

**Date:** 2025-02-10  
**Base:** V20 (V14 + trade-aligned toxicity boost)  
**Goal:** One structural change with highest expected impact to break the 380 edge plateau.

---

## Change

- **First-in-step pHat/sigma:**  
  - **Step** = timestamp advance (same as in YQ / audit).  
  - On **first trade in a step:** use `PHAT_ALPHA` (0.26) for pHat update and **update sigmaHat**.  
  - On **later trades in the same step:** use `PHAT_ALPHA_RETAIL` (0.05) for pHat and **do not** update sigmaHat.  
- **New slot:** `SLOT_STEP_TRADE_COUNT` (slot 5). Reset to 0 when `timestamp > lastTs`; increment after each trade (capped at 64).  
- **Temp slots 6–9** used to avoid stack-too-deep: store ret, adaptiveGate, spot, pHat there; helpers read from slots.  
- **Logic split:** `afterSwap` delegates to `_afterSwapImpl(reserveX, reserveY, amountY, isBuy, timestamp)`; `_updatePriceAndSigma(stepTradeCount)` writes spot/pHat/ret/gate to slots and returns newSigma; `_applyDirSurgeSizeAndTradeBoostFromSlots(bidFeeOut, askFeeOut)` reads from slots. No change to fee formula constants vs V20.

---

## Why

- Diagnosis ([2025-02-10-Sapient-V20-amm-fee-designer-diagnosis.md](2025-02-10-Sapient-V20-amm-fee-designer-diagnosis.md)): multi-trade steps and “move-then-fade” exploit; sigma and pHat updated every trade.  
- First-in-step reduces noise and differentiates first-mover toxicity; aligns with leaderboard/YQ.

---

## How to test

- Run the same harness (1000 sims) as for V20.  
- Compare edge: target is to move above 380.13.

---

## Result (initial)

- **1000 sims:** Edge **128.27** (vs V20 **380.13**) — large regression.
- **Cause (hypothesis 1):** Sigma updated only on first-in-step → frozen sigma in multi-trade steps → undercharge.
- **Fix tried:** Sigma every trade, first-in-step for pHat only → **still 128.27**. So the regression is not from sigma-only-on-first.
- **Cause (hypothesis 2):** Dual alpha for pHat (slow 0.05 on later trades in step) makes pHat lag → directionality/surge/boost use stale fair price → wrong fees. Or step/timestamp semantics in the sim differ from our assumption.
- **Decision:** **Revert V21 to V20 logic** so that `SapientStrategyV21.sol` again scores ~380. Next structural try: **tail compression** (V22) or two regimes.

## Changelog

- **2025-02-10:** V21 implemented: first-in-step + dual alpha on V20 base; stack-too-deep worked around with temp slots and helpers.
- **2025-02-10:** V21 result 128.27; changed to sigma-every-trade (first-in-step for pHat only); re-run still 128.27.
- **2025-02-10:** V21 reverted to V20 logic (same code as V20, name updated). First-in-step abandoned for this sim.
