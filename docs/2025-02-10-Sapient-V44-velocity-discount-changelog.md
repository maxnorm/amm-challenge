# Sapient V44 — Velocity discount changelog

**Date:** 2025-02-10  
**Purpose:** Add **HydraSwap-style velocity discount** to V43. Reduce the base fee when activity (lambdaHat×sizeHat) is high, so fee goes down in high-turnover regimes (attract flow).

**Reference:** [2025-02-10-alternative-fee-formulas-research.md](2025-02-10-alternative-fee-formulas-research.md) — §2 (HydraSwap), §7–8 (velocity discount).

---

## HydraSwap inspiration

- **HydraSwap formula:** percentFee = volatility_drag / velocity, with velocity = volume / TVL. High vol → higher fee; high velocity → lower fee to stay competitive.
- **Our adaptation:** We have σ (sigmaHat) and activity = lambdaHat×sizeHat (flowSize). No TVL in the strategy interface, so we use flowSize as a velocity proxy and **subtract** a discount from the base fee when activity is high.

---

## What changed vs V43

- **No new slots.** flowSize is already computed from slots[7] and slots[8] (lambdaHat, sizeHat).
- **New constants:**
  - `VELOCITY_DISCOUNT = 500 * BPS` (5 bps per WAD of capped flowSize) — conservative initial value.
  - `VELOCITY_CAP = WAD / 2` (0.5 WAD) — cap on flowSize used for the discount.
- **Formula:**  
  Base fee is computed as in V43, then we subtract a velocity discount and apply a floor:
  - `fBase = BASE_FEE + SIGMA_COEF×sigmaHat + LAMBDA_COEF×lambdaHat + FLOW_SIZE_COEF×flowSize`
  - `fBase = fBase − VELOCITY_DISCOUNT × min(flowSize, VELOCITY_CAP)` (with underflow guard: if discount would exceed fBase, set fBase = BASE_FEE)
  - `fBase = max(BASE_FEE, fBase)`
- **Helper:** `_computeBaseFeeWithVelocityDiscount(sigmaHat, lambdaHat, sizeHat)` — computes flowSize, raw base fee, capped discount, and returns floored fBase (also used to avoid stack-too-deep in `afterSwap`).
- **Stack:** As with V43, `forge build` in-contracts may report stack too deep; **amm-match** compiles and runs the strategy. Use `amm-match run` for validation.

---

## Validation

Run from `amm-challenge/` (with venv / amm-match on PATH):

```bash
amm-match run contracts/src/SapientStrategyV44.sol --simulations 1000
```

- **V34/V43 baseline:** 524.63  
- **V44 result:** **524.59**

**Conclusion:** Velocity discount is a **slight regression** (524.59 &lt; 524.63). The effect is small; next options: try reducing VELOCITY_DISCOUNT or VELOCITY_CAP and re-run, or revert to V34/V43 for subsequent experiments.
