# Sapient V26 — Scaled LAMBDA_COEF

**Date:** 2025-02-10  
**Purpose:** V25 (scaled FLOW_SIZE + ACT) still gave edge 40.30 because **LAMBDA_COEF × lambdaHat** can add **60 bps** when lambdaHat = 5 (LAMBDA_CAP). Scale LAMBDA_COEF so total activity stays ~5–20 bps.

**Change vs V25:** `LAMBDA_COEF = 12e14` → **`2e14`** (max 10 bps from lambda when lambdaHat = 5). FLOW_SIZE_COEF and ACT_COEF unchanged (300e14, 500e14).

**Run:** `amm-match run contracts/src/SapientStrategyV26.sol --simulations 1000`  
Compare edge to V23 (~380), V24/V25 (40.30).
