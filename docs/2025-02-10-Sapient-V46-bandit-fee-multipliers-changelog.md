# Sapient V46 — Bandit over 4 fee multipliers changelog

**Date:** 2025-02-10  
**Purpose:** Add an **on-chain bandit** on top of V34: same fee formula, but final bid/ask are scaled by a chosen multiplier (0.85, 1.0, 1.15, 1.3). Arm chosen by **epsilon-greedy** on running average reward; reward = fee collected (proxy: `wmul(prevFee, amountY)`).

**Reference:** P1 in [2025-02-10-next-formulas-innovative-research.md](2025-02-10-next-formulas-innovative-research.md).

---

## What changed vs V34

- **New slots (9):**
  - slots[11..14] = sumReward[0..3] (running sum of reward per arm, WAD-scaled)
  - slots[15..18] = count[0..3] (number of times each arm was used, capped at 1e9)
  - slots[19] = lastArm (0..3, or 4 = invalid on first trade)
- **Constants:** MULT_0 = 0.85 WAD, MULT_1 = 1.0 WAD, MULT_2 = 1.15 WAD, MULT_3 = 1.3 WAD; EPSILON_DENOM = 20 (explore when seed % 20 == 0, i.e. 5%); COUNT_CAP = 1e9.
- **Flow in afterSwap:** (1) If lastArm in 0..3, update bandit: reward = wmul(prevFee, amountY), sumReward[lastArm] += reward, count[lastArm] += 1 (capped). (2) Choose arm via _chooseArm(seed) with seed = timestamp + stepTradeCount (epsilon-greedy: 5% explore = random arm, else argmax of sumReward[i]/count[i]; ties → smallest index). (3) Run full V34 fee pipeline to get bidFeeRaw, askFeeRaw. (4) Apply multiplier: bidFee = clampFee(wmul(bidFeeRaw, mult)), same for ask. (5) Persist slots 0..10 (V34 state), 19 = arm (slots 11..18 already updated in step 1).
- **Helpers:** _multiplierForArm(arm), _chooseArm(seed) (reads slots 11..18). All V34 helpers kept (_compressTailWithSlope, _powWad, _decayCentered).

---

## Validation

Run from `amm-challenge/` (with venv / amm-match on PATH):

```bash
amm-match run contracts/src/SapientStrategyV46.sol --simulations 1000
```

- **V34 baseline:** 524.63  
- **V46 result:** **516.69**

**Conclusion:** Bandit over fee multipliers **regressed** (516.69 < 524.63). V34 remains baseline. The on-chain bandit (epsilon-greedy over 4 multipliers) hurt edge in this harness. Next: try **momentum asymmetric fee (P2)** or **constant tuning**; do not keep V46 as baseline.
