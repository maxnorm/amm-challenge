# Sapient V40 — Silence risk changelog

**Date:** 2025-02-10  
**Purpose:** Add **silence risk** (unique angle 2.4) to V34. First trade after long silence gets a one-off fee scale: quote is staler → higher arb risk.

**Reference:** [2025-02-10-V34-explanation-and-unique-angles.md](2025-02-10-V34-explanation-and-unique-angles.md) — section 2.4.

---

## What changed vs V34

- **New constants:**
  - `SILENCE_COEF = 2e15` (0.2% in WAD) — scale factor per elapsed step.
  - `SILENCE_ELAPSED_CAP = 8` — cap elapsed for the bump (same as ELAPSED_CAP).
- **Logic:** On each trade we keep `silenceElapsed = 0` unless we're in a new step, in which case `silenceElapsed = elapsed` (time since last trade, capped). After tail compression, if **first trade in step** and **silenceElapsed > 0**, scale both bid and ask by `(1 + SILENCE_COEF * min(silenceElapsed, SILENCE_ELAPSED_CAP))`, then clamp. So after 8 steps of silence, max scale is 1 + 0.002*8 = 1.016 (~1.6% bump).
- **Slots:** No new slots; `elapsed` is already available at step boundary.

---

## Validation

Run from `amm-challenge/` with venv:

```bash
amm-match run contracts/src/SapientStrategyV40.sol --simulations 1000
```

- **V34 baseline:** 524.63  
- **V40 result:** **524.63**

**Conclusion:** Silence risk is **neutral** — same edge as V34. No regression, no gain. V34 remains baseline. Next: try another angle (e.g. gate/alpha by size 2.3, toxic flow run 2.5) or constant tuning.
