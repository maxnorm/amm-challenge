# Sapient V32 — Activity block after price/vol (order fix)

**Date:** 2025-02-10  
**Purpose:** Fix the bug that caused the activity pipeline to yield edge 40.30. Hypothesis: running the activity block (step decay, blend, step count) **before** spot/pHat/sigma/vol/tox could affect the fee path (e.g. via slot usage or ordering). V32 runs **price/vol/tox and temp slots first** (same as V23), **then** the activity block, **then** `_computeRawFeeAdditive`.

**Change vs V28:** In V28 the order was: activity block → spot/pHat/vol/tox → temp slots → rawFee. In V32: spot/pHat/vol/tox → temp slots → **activity block** → rawFee. So activity state is updated with the current trade immediately before the fee is computed, but it no longer runs before any price/vol logic.

**V32** keeps activity terms zeroed (same as V28) so we can test whether the order fix alone recovers edge. If V32 → ~380, then add scaled activity coefs (e.g. V26 values) in a follow-up.

**Run:** `amm-match run contracts/src/SapientStrategyV32.sol --simulations 1000`
