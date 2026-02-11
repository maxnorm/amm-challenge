# Sapient V27 — Activity terms zeroed (isolate test)

**Date:** 2025-02-10  
**Purpose:** V26 still gave edge 40.30. Isolate whether the regression comes from (1) **activity terms** adding to the fee, or (2) **activity logic** (step decay, blend, slot updates) changing behavior. V27 = V26 with **LAMBDA_COEF = 0, FLOW_SIZE_COEF = 0, ACT_COEF = 0**. Activity state and step logic still run; they just don’t add to the fee.

**Interpretation:**
- **V27 ≈ V23 (~380):** The activity *terms* (any positive add) caused the regression. Keep activity state/logic for future use but don’t add to fee in this sim, or add only a tiny capped amount.
- **V27 ≈ 40:** The activity *logic* (step/blend/slots) is affecting something else (e.g. timing, slot usage). Need to compare execution path to V23.

**Run:** `amm-match run contracts/src/SapientStrategyV27.sol --simulations 1000`
