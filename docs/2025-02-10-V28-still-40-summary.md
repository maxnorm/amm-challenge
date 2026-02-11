# V28 still 40.30 — summary and next steps

**Date:** 2025-02-10  

**Facts:**
- V23 (no activity): edge ~380
- V24–V27 (activity, various coefs / zeroed terms): edge 40.30
- V28 (V27 + pHat write order fix so vol uses old pHat): edge **40.30** (no change)

So the **pHat write order** (vol using old vs new pHat) was not the only cause of the regression. Something else in the activity pipeline still makes the outcome match the 40.30 branch.

**Possible causes:**
1. **Another ordering or logic difference** — e.g. running step decay/blend **before** spot/pHat/sigma changes some downstream behavior (state, timing, or a read we didn’t account for).
2. **Sim sensitive to contract shape** — e.g. bytecode size, slot usage, or deployment; different strategy layout might get different treatment even if fee logic were equivalent.
3. **Subtle bug** — e.g. wrong slot index or a path where we read/write a different slot than intended.

**Suggested checks:**
1. **Re-run V23** — `amm-match run contracts/src/SapientStrategyV23.sol --simulations 1000` and confirm edge is still ~380.
2. **V29** — Exact copy of V23, only `getName` = "Sapient v29 - (V23 copy)". Run `amm-match run contracts/src/SapientStrategyV29.sol --simulations 1000`; if edge ≈ 380, the 40.30 branch is specific to the V24+ code path.
3. **V31** — V28 (pHat fix) + V26 scaled activity coefs (LAMBDA_COEF=2e14, FLOW_SIZE_COEF=300e14, ACT_COEF=500e14). Run `amm-match run contracts/src/SapientStrategyV31.sol --simulations 1000`; if edge moves away from 40.30, we can tune activity on top of the pHat fix.

**Conclusion:** With the current pipeline, fixing only the pHat order was not enough to recover V23’s edge. Either another difference in the activity path is still wrong, or the sim responds to something other than fee outputs (e.g. contract layout). Re-running V23, testing a V23 copy (V29), and trying scaled activity on top of V28 are the next diagnostic steps.
