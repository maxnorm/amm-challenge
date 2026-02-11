# Sapient V13 — First-in-step pHat/sigma

**Date:** 2025-02-09  
**Base:** V11 (tuned flow terms + cap)  
**File:** `amm-challenge/contracts/src/SapientStrategyV13.sol`

---

## Summary

V13 adds **first-in-step pHat/sigma** as recommended in the audit: use a **fast alpha** on the first trade in a step and a **slow alpha** on subsequent trades in the same step; update **sigmaHat only on the first trade in a step**. No new fee terms and no new slots — reuses existing `stepTradeCount` from V11.

---

## Motivation (from audit)

- **Gap:** We update pHat and sigma on every trade; YQ uses two alphas and updates sigma only on first-in-step.
- **Effect:** Multi-trade steps become noisier and more exploitable (e.g. move pHat/sigma then fade). First-in-step logic makes pHat/sigma more responsive to the first move in a step and less reactive to follow-up noise.

---

## Changes

### 1. New constant

- **`PHAT_ALPHA_RETAIL = 5e16`** (0.05) — slow blend for pHat when the trade is **not** the first in the current step. Keeps existing **`PHAT_ALPHA = 26e16`** (0.26) for the first trade in a step.

### 2. First-in-step flag

- **`firstInStep = (stepTradeCount == 0)`**  
  After the new-step block, `stepTradeCount` is 0 either because we just entered a new step (and reset it) or because it was already 0. So the current trade is “first in step” exactly when `stepTradeCount == 0`.

### 3. pHat update (dual alpha)

- **Before (V11):** Always `pHat = (1 - PHAT_ALPHA)*pHat + PHAT_ALPHA*pImplied` when `ret <= adaptiveGate`.
- **After (V13):**  
  `pAlpha = firstInStep ? PHAT_ALPHA : PHAT_ALPHA_RETAIL`  
  `if (ret <= adaptiveGate) pHat = (1 - pAlpha)*pHat + pAlpha*pImplied`  
  So: fast adaptation on first trade in step, slow on later trades in the same step.

### 4. Sigma update (first-in-step only)

- **Before (V11):** Every trade: `sigmaHat = SIGMA_DECAY*sigmaHat + (1 - SIGMA_DECAY)*ret` (with `ret` capped at `RET_CAP`).
- **After (V13):**  
  `if (firstInStep) sigmaHat = SIGMA_DECAY*sigmaHat + (1 - SIGMA_DECAY)*ret`  
  So volatility state updates only once per step, on the first trade.

### 5. Unchanged

- All other logic is unchanged from V11: step boundary (timestamp change), lambdaHat/sizeHat/flow terms, toxEma, dirState, fee pipeline, caps, etc.
- Slot layout and constant set (except one new constant) unchanged.

---

## Formula (audit-style)

```text
firstInStep = (stepTradeCount == 0)   // after new-step reset
pAlpha     = firstInStep ? PHAT_ALPHA : PHAT_ALPHA_RETAIL
if (ret <= gate) pHat = (1 - pAlpha)*pHat + pAlpha*pImplied
if (firstInStep) sigmaHat = SIGMA_DECAY*sigmaHat + (1 - SIGMA_DECAY)*ret
```

---

## Implications

1. **No new slots** — reuses `SLOT_STEP_TRADE_COUNT` already used for lambdaHat in V11.
2. **No new fee terms** — only the way pHat and sigma are updated changes; fee formulas are unchanged.
3. **Step definition** — same as V11: a new step when `trade.timestamp > lastTs`; then `stepTradeCount` is reset to 0, so the very next trade is first-in-step.
4. **Sigma in fees** — sigmaHat is still used in adaptiveGate, sigma×tox, etc.; it now evolves only once per step, so it is less noisy in multi-trade steps.
5. **Compiler/config** — No change to Foundry config (per workspace rules).

---

## References

- [2025-02-09-Sapient-audit-380-vs-526.md](2025-02-09-Sapient-audit-380-vs-526.md) — Section C (First-in-step pHat/sigma), Step 6 formulas.
- [2025-02-09-YQ-extract-for-Sapient.md](2025-02-09-YQ-extract-for-Sapient.md) — Section 11 (PHAT_ALPHA first-in-step vs retail).
- `refs/YQStrategy.sol` — `firstInStep = stepTradeCount == 0`, dual alpha, sigma only when `firstInStep`.
