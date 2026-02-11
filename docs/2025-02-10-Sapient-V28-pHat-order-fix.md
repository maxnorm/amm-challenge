# Sapient V28 — pHat write order fix (root cause of V24–V27 regression)

**Date:** 2025-02-10  
**Purpose:** V27 (activity terms zeroed) still gave 40.30 → the regression came from the **activity logic**, not the activity terms. Root cause: **vol uses pHat**; in V23 we use **old** pHat for vol and write **new** pHat at the end; in V24–V27 `_computeSpotPhatRetGate` wrote **new** pHat to the slot before the vol computation, so vol used **new** pHat (closer to spot) → smaller vol → different fee path.

**Fix:** `_computeSpotPhatRetGate` no longer writes `slots[SLOT_PHAT]`. It writes the new pHat to `SLOT_TEMP_PHAT` (19) and returns sigmaHat. Caller computes vol using `slots[SLOT_PHAT]` (old), uses `slots[SLOT_TEMP_PHAT]` for dir/surge and trade boost, then writes `slots[SLOT_PHAT] = slots[SLOT_TEMP_PHAT]` at the end (same order as V23).

**V28:** Same as V27 (activity terms zeroed) with the above fix. If edge recovers to ~380, we can re-enable activity terms (e.g. V26 coefs) in a follow-up and expect them to work with the correct pHat order.

**Run:** `amm-match run contracts/src/SapientStrategyV28.sol --simulations 1000`
