# Sapient V41 — Gate by trade size changelog

**Date:** 2025-02-10  
**Purpose:** Add **gate/alpha by size** (unique angle 2.3) to V34. When trade size is large (≥ 1% of reserve), the adaptive gate is widened so we don't trust one big move to update pHat.

**Reference:** [2025-02-10-V34-explanation-and-unique-angles.md](2025-02-10-V34-explanation-and-unique-angles.md) — section 2.3.

---

## What changed vs V34

- **New constants:**
  - `LARGE_TRADE_THRESH = 1e16` (1% in WAD) — tradeRatio (amountY/reserveY) above this is "large."
  - `GATE_LARGE_MULT = 15e17` (1.5 WAD) — when trade is large, adaptive gate is multiplied by this (50% wider).
- **Logic:** `tradeRatio` is computed once, right after `firstInStep`, and reused for dirState/actEma/sizeHat and for the gate. In the pHat block, after setting `adaptiveGate` from sigma: if `tradeRatio >= LARGE_TRADE_THRESH`, set `adaptiveGate = wmul(adaptiveGate, GATE_LARGE_MULT)`. So a large trade needs a larger move (ret) to pass the gate and update pHat — one big toxic trade distorts pHat less.
- **Slots:** No new slots.

---

## Validation

Run from `amm-challenge/` with venv:

```bash
amm-match run contracts/src/SapientStrategyV41.sol --simulations 1000
```

- **V34 baseline:** 524.63  
- **V41 result:** **524.08**

**Conclusion:** Gate by size **hurt** (524.08 < 524.63). Revert to V34 for next experiments. Next: try **toxic flow run (2.5)**, **two-speed pHat (2.7)**, **size-dependent attract (2.8)**, or **constant tuning**.
