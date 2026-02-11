# Sapient V35 — Imbalance skew changelog

**Date:** 2025-02-10  
**Purpose:** Add a small **inventory-based skew** to V34 (YQ baseline). No change to base or mid fee; imbalance only nudges which side we protect, reinforcing or supplementing dirState.

**Reference:** [2025-02-10-V34-explanation-and-unique-angles.md](2025-02-10-V34-explanation-and-unique-angles.md) — section 2.1 (Reserve imbalance as a second pressure signal).

---

## What changed vs V34

- **New constant:** `IMB_SKEW_COEF = 15 * BPS` (max ~15 bps at full imbalance).
- **New block (after dirState skew, before stale/attract):**
  - `totalReserves = trade.reserveX + trade.reserveY`
  - `imbalance = |reserveX - reserveY| / totalReserves` (in WAD; 0 when balanced, up to WAD when one side dominates)
  - `imbSkew = IMB_SKEW_COEF * imbalance`
  - If **reserveY >= reserveX:** we're long Y → next arb likely sells us X → **protect bid:** bidFee += imbSkew, askFee -= imbSkew (floor 0)
  - Else: **protect ask:** askFee += imbSkew, bidFee -= imbSkew (floor 0)

**Design choice:** Imbalance is used only as a **skew** (add to one side, subtract from the other), not in the base. So we avoid the V24 trap (stacking large terms on top of an already heavy base). When dirState and imbalance agree (e.g. sell pressure + we're long Y), we protect that side more; when they disagree, we still have dirState as primary and imbalance as a small nudge.

**Slots:** No new slots; imbalance is computed from `trade.reserveX` and `trade.reserveY` each call.

---

## Validation

Run from `amm-challenge/` with venv:

```bash
amm-match run contracts/src/SapientStrategyV35.sol --simulations 1000
```

- **V34 baseline:** 524.63
- **V35 result:** **510.76** (regression of ~14 points)

**Conclusion:** Imbalance skew as implemented (15 bps max, inventory-based add/subtract) **hurts** edge. Keep **V34** as baseline for next experiments; do not carry imbalance skew forward. Next: try another unique angle (e.g. calm/stressed regime, silence risk, tox-dependent decay) or a much smaller IMB_SKEW_COEF (e.g. 5 bps) in a separate variant if we want to retest imbalance later.
