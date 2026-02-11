# Sapient V42 — Toxic flow run changelog

**Date:** 2025-02-10  
**Purpose:** Add **toxic flow run** (unique angle 2.5) to V34. A decayed state "toxRun" tracks recent toxic trades (buy above pHat / sell below); when high, add a fee boost to both sides.

**Reference:** [2025-02-10-V34-explanation-and-unique-angles.md](2025-02-10-V34-explanation-and-unique-angles.md) — section 2.5.

---

## What changed vs V34

- **New slot:** `slots[11] = toxRun` — decayed accumulator of "recent toxic" (same definition as trade-aligned: buy when spot ≥ pHat, sell when spot < pHat).
- **New constants:**
  - `TOX_RUN_DECAY = 0.92` — per-trade decay.
  - `TOX_RUN_INCR = 0.5 WAD` — add when current trade is toxic.
  - `TOX_RUN_CAP = 3 * WAD` — cap toxRun.
  - `TOX_RUN_COEF = 5 * BPS` — fee boost per WAD of toxRun (added to both bid and ask).
- **Logic:** After trade-aligned boost, if current trade is toxic then `toxRun = wmul(toxRun, TOX_RUN_DECAY) + TOX_RUN_INCR`, else `toxRun = wmul(toxRun, TOX_RUN_DECAY)`. Cap toxRun. Add `wmul(TOX_RUN_COEF, toxRun)` to both bidFee and askFee, then tail compression.
- **afterInitialize:** Set `slots[11] = 0`.

---

## Validation

Run from `amm-challenge/` with venv:

```bash
amm-match run contracts/src/SapientStrategyV42.sol --simulations 1000
```

- **V34 baseline:** 524.63  
- **V42 result:** **507.46**

**Conclusion:** Toxic flow run **hurt** (507.46 < 524.63). Revert to V34 for next experiments. Next: try **two-speed pHat (2.7)**, **size-dependent attract (2.8)**, or **constant tuning**.
