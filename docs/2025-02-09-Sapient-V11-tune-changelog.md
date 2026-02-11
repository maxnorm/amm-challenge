# Sapient V11 — Tune Changelog (Flow terms tuned down + cap)

**Date:** 2025-02-09  
**Contract:** [amm-challenge/contracts/src/SapientStrategyV11.sol](../amm-challenge/contracts/src/SapientStrategyV11.sol)

V11 is V10 with **reduced flow coefficients** and a **cap on the total flow term** to avoid overcharging in active regimes (V10 edge 365.83 vs V7 380.14).

---

## Tunes applied

| Constant       | V10 value | V11 value | Effect |
|----------------|-----------|-----------|--------|
| LAMBDA_COEF    | 12e14     | 6e14      | 6 bps per unit lambdaHat (half of V10). |
| FLOW_SIZE_COEF | 48e14     | 15e14     | 15 bps per unit flowSize (about one-third of V10). |
| CAP_FLOW_BPS   | (none)    | 12e14     | Total flow term (lambda + flowSize) capped at 12 bps. |

Logic: `flowBps = LAMBDA_COEF*lambdaHat + FLOW_SIZE_COEF*flowSize`; then `flowBps = min(flowBps, CAP_FLOW_BPS)`; `rawFee += flowBps`. All other logic and slots unchanged from V10.

---

## How to run

From `amm-challenge`:

```bash
amm-match run contracts/src/SapientStrategyV11.sol --simulations 1000
```

Compare edge to V7 (380.14), V8 (378.99), and V10 (365.83). If V11 > 365.83, the regression was partly from flow terms being too strong; if V11 ≥ 378, the cap + reduced coefs are a better balance.
