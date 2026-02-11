# Sapient — Research: Other Levers to Improve Edge

**Date:** 2025-02-09  
**Context:** V14 (75 bps, additive base) = 380.13 (best baseline). Cap/tail/cap-raise tested: V15 (85 + tail) 380.02, V17 (100 bps) 374.53, V16 (10%) 72.59. We need levers that don’t rely on higher cap or full tail compression.  
**Skill:** amm-fee-designer — diagnosis, exploit vectors, failure modes, new ideas, formulas, simulation plan, recommendation.

---

## Step 1 — Loss Diagnosis (Why We’re Stuck at ~380)

### What we’ve already tested

- **Cap:** 75 bps (V14) ≈ best; 85 bps (V15 with tail) ≈ same; 100 bps (V17) regressed; 10% (V16) collapsed. So the sim rewards a **75–85 bps** effective cap; more headroom hurts.
- **Tail compression:** V15 (full tail above 5 bps) regressed slightly (380.02) and reduced fees in the 25–85 bps band vs V14. Conditional tail (only above 75 bps) not yet implemented.
- **Base:** Additive (V14) ≈ multiplicative (V7). No gain from the rewrite alone.

### Mechanical reasons we’re still at ~380

1. **Price signal quality**  
   We update pHat and sigma on **every** trade using **spot**. So in multi-trade steps we react to each trade; a bot can move our quote then fade. We have not tried **pImplied** (fee-adjusted price) or **first-in-step** (fast alpha first trade, slow alpha later; sigma only on first-in-step) on V14.

2. **Vulnerable-side tox is linear + quad only**  
   V14 has TOX_COEF and TOX_QUAD_COEF. YQ adds **sigma×tox** and **cubic tox** on the vulnerable side for a sharper response when we’re wrong and vol is high. We haven’t added those on V14.

3. **No trade-aligned boost**  
   We don’t charge extra when the **current** trade is “toxic” (buy when spot ≥ pHat or sell when spot < pHat) scaled by trade size. YQ has TRADE_TOX_BOOST; V8 had it but regressed when bundled. Not tried alone on V14.

4. **No flow-direction memory (dirState)**  
   We decide “vulnerable side” from reserves only. We don’t persist “who’s been hitting us” (dirState) to protect one side and attract the other. V8 had dirState and regressed when bundled; not tried alone on V14.

5. **No stale + attract spread**  
   We don’t add a “stale” term on the vulnerable side and subtract an “attract” fraction on the other to widen spread and attract rebalancing. V8 had it; not tried alone on V14.

6. **No regime switch**  
   We use one formula everywhere. Research suggests **two regimes**: calm → low flat fee (compete for retail); stressed → full pipeline. We haven’t implemented an explicit threshold switch on V14.

**Summary:** The ceiling at ~380 comes from (a) cap/tail already explored with mixed or negative results, and (b) **unexplored or not-isolated levers**: better price signal (pImplied, first-in-step), richer tox (sigma×tox, cubic), trade-aligned boost, dirState, stale+attract, and regime switch.

---

## Step 2 — Adversarial Exploitation (Still Relevant)

1. **Move then fade in same step**  
   We update pHat/sigma every trade. In a step with several trades, arb can move our quote with one trade and fade with the next at a different fee. First-in-step (and/or pImplied) reduces this.

2. **Dir/surge from noisy spot**  
   Directionality and surge use spot vs pHat. If pHat lags or is distorted by a toxic trade, we add dir/surge to the wrong side. pImplied (fee-adjusted price) gives a cleaner signal.

3. **No extra charge for “toxic” current trade**  
   When the current trade is against us (buy when spot ≥ pHat, sell when spot < pHat), we don’t add a size-scaled boost. So we undercharge that trade relative to YQ.

4. **Reserve-only vulnerable side**  
   Without dirState, “vulnerable” is only from current reserves. Sustained one-sided flow can be under-priced until reserves move.

5. **Flat formula across regimes**  
   In calm regimes we may still be above 30 bps (floor); in stressed we cap at 75. We don’t explicitly lower fee in calm to grab retail or raise it more steeply only in stress.

---

## Step 3 — Failure Modes

| Regime / condition     | Limitation                          | Effect |
|------------------------|--------------------------------------|--------|
| Multi-trade steps      | pHat/sigma every trade               | Noisy; move-then-fade exploit |
| Toxic current trade    | No trade-aligned boost               | Undercharge that trade |
| High sigma + high tox  | No sigma×tox or cubic tox on V14    | Less sharp fee on vulnerable side |
| One-sided flow         | No dirState                          | Vulnerable side from reserves only |
| Calm vs stressed       | Same formula                         | No explicit “low in calm, high in stress” |

---

## Step 4 — New Strategy Ideas (Other Levers)

### A. First-in-step pHat/sigma on V14

- **Idea:** Add step boundary (timestamp change). On **first** trade in step: use PHAT_ALPHA (e.g. 0.26), update sigmaHat. On **later** trades in same step: use PHAT_ALPHA_RETAIL (e.g. 0.05), do **not** update sigmaHat.
- **Addresses:** Multi-trade-step noise; move-then-fade.
- **Slots:** 1 (stepTradeCount). Reset stepTradeCount when timestamp > lastTs; firstInStep = (stepTradeCount == 0); increment after use.
- **Risk:** Need to define step (timestamp change); same pattern as V13 on V11.

### B. pImplied only on V14

- **Idea:** Store prev bid and prev ask fee. Compute fee-used (last side hit), gamma = 1 − feeUsed, pImplied = isBuy ? spot×gamma : spot/gamma. Use **pImplied** (not spot) for ret and for pHat update when ret ≤ gate.
- **Addresses:** pHat lag and dir/surge reacting to toxic trade’s spot; cleaner price signal.
- **Slots:** 2 (prev bid, prev ask). No dirState, no stale, no trade boost—just pImplied.
- **Risk:** V8 regressed with pImplied bundled; isolation on V14 may help.

### C. Sigma×tox and cubic tox on V14 (vulnerable side)

- **Idea:** Add to vulnerable-side tox premium: `SIGMA_TOX_COEF * sigmaHat * toxEma` and `TOX_CUBIC_COEF * toxEma^3`. Same as YQ / V8; V14 currently has only linear + quad.
- **Addresses:** Sharper fee when we’re wrong and volatility is high.
- **Slots:** 0. No new state.
- **Risk:** Coefficients; may need to tune down other tox terms to avoid cap hit.

### D. Trade-aligned toxicity boost on V14

- **Idea:** If (isBuy && spot ≥ pHat) or (!isBuy && spot < pHat), add TRADE_TOX_BOOST × min(tradeRatio, cap) to that side’s fee (bid or ask). Cap the boost (e.g. 25 bps).
- **Addresses:** Undercharging the current trade when it’s toxic.
- **Slots:** 0.
- **Risk:** Can push fee toward cap; tune boost and cap.

### E. dirState on V14 (alone)

- **Idea:** One slot dirState (WAD = neutral). On new step: decay toward WAD by elapsed. On trade: if tradeRatio > threshold, push dirState up (buy) or down (sell) by size (capped). Fee skew: protect side (dirState side) gets +skew, attract side gets −skew; skew = f(dirDev, toxEma).
- **Addresses:** Flow-direction memory; protect side under pressure, attract other.
- **Slots:** 1 (dirState). Need _powWad and _decayCentered (or reuse from V12).
- **Risk:** V8 had dirState and regressed when bundled; tuning and isolation matter.

### F. Stale + attract on V14 (alone)

- **Idea:** staleShift = STALE_COEF × toxEma; attractShift = staleShift × ATTRACT_FRAC. If spot ≥ pHat: add staleShift to bid, subtract attractShift from ask (floor 0). Else: add staleShift to ask, subtract from bid.
- **Addresses:** Widen spread on vulnerable side; attract rebalancing on the other.
- **Slots:** 0.
- **Risk:** V8 had it and regressed; try alone on V14.

### G. Two regimes (threshold) on V14

- **Idea:** If sigmaHat < SIGMA_THRESH && toxEma < TOX_THRESH → calm: bidFee = askFee = FEE_CALM (e.g. 28 bps). Else → stressed: full V14 pipeline (additive base + tox + dir + surge + size), clamp 75.
- **Addresses:** Research “competitive in normal, elevated in stress”; explicit calm vs stressed.
- **Slots:** 0 (or reuse existing sigma/tox). Hysteresis optional.
- **Risk:** Threshold tuning; boundary effects.

### H. Conditional tail compression on V14

- **Idea:** Apply tail compression **only when** pre-compression fee > 75 bps. If fee ≤ 75, output fee (clamp 75). If fee > 75: out = 75 + slope×(fee − 75), then clamp 85.
- **Addresses:** V15’s full tail reduced fees in 25–75 band; conditional preserves V14 there and only softens 75–85.
- **Slots:** 0.
- **Risk:** Implementation detail; may still not help if sim doesn’t reward 75–85 range.

---

## Step 5 — Formulas & Pseudocode

### A. First-in-step (on V14)

```text
// New slot: SLOT_STEP_TRADE_COUNT (e.g. 5)
// On new step (timestamp > lastTs): stepTradeCount = 0 (after using it for lambda if we had it)
firstInStep = (stepTradeCount == 0)
pAlpha = firstInStep ? PHAT_ALPHA : PHAT_ALPHA_RETAIL   // 26e16 vs 5e16
if (ret <= gate) pHat = (1 - pAlpha)*pHat + pAlpha*pImplied  // or spot if no pImplied
if (firstInStep) sigmaHat = SIGMA_DECAY*sigmaHat + (1 - SIGMA_DECAY)*ret
// ... rest of fee pipeline ...
stepTradeCount++; if (stepTradeCount > STEP_COUNT_CAP) stepTradeCount = STEP_COUNT_CAP
// On new step (at top of afterSwap): after decay/reset, stepTradeCount = 0
```

### B. pImplied (no dirState/stale/boost)

```text
feeUsed = isBuy ? prevBid : prevAsk
gamma = feeUsed < WAD ? WAD - feeUsed : 0
pImplied = gamma == 0 ? spot : (isBuy ? wmul(spot, gamma) : wdiv(spot, gamma))
ret = pHat > 0 ? wdiv(abs(pImplied - pHat), pHat) : 0
// use pImplied in pHat update when ret <= gate
// store prevBid = bidFeeOut, prevAsk = askFeeOut at end
```

### C. Sigma×tox and cubic tox (add to vulnerable premium)

```text
toxPremium += wmul(SIGMA_TOX_COEF, wmul(sigmaHat, toxEma))
toxPremium += wmul(TOX_CUBIC_COEF, wmul(toxEma, wmul(toxEma, toxEma)))
// then apply to vulnerable side as now
```

### D. Trade-aligned boost

```text
tradeAligned = (isBuy && spot >= pHat) || (!isBuy && spot < pHat)
if (tradeAligned) {
  boost = wmul(TRADE_TOX_BOOST, min(tradeRatio, TRADE_RATIO_CAP))
  if (boost > CAP_TRADE_BOOST) boost = CAP_TRADE_BOOST
  if (isBuy) bidFee += boost; else askFee += boost
}
// then clamp
```

### E. Two regimes

```text
stressed = (sigmaHat >= SIGMA_THRESH) || (toxEma >= TOX_THRESH)
if (!stressed) return (FEE_CALM, FEE_CALM)
else compute full V14 pipeline, return (bidFee, askFee)
```

### F. Conditional tail (only above 75 bps)

```text
if (fee <= 75e14) return fee > MAX_FEE_CAP ? MAX_FEE_CAP : fee
excess = fee - 75e14
out = 75e14 + wmul(excess, slope)
return out > 85e14 ? 85e14 : out
```

---

## Step 6 — Simulation Blueprint

- **Inputs:** Same harness, 1000 sims; same or fixed seeds.
- **Metrics:** Edge (primary); fee distribution (mean, p90) by side; optional: cap-hit rate, fraction of steps with first-in-step.
- **Scenarios (each vs V14 = 380.13):**
  1. **V14 + pImplied only** (prev bid/ask, pImplied for pHat/ret; no other V8 levers).
  2. **V14 + sigma×tox + cubic tox** (add to vulnerable premium; tune coefs small at first).
  3. **V14 + trade-aligned boost** (TRADE_TOX_BOOST × tradeRatio, capped).
  4. **V14 + first-in-step** (stepTradeCount, dual alpha, sigma only first-in-step; no lambda/size).
  5. **V14 + dirState only** (one slot, decay, skew; no stale, no trade boost).
  6. **V14 + stale + attract only** (STALE_COEF × toxEma, attract fraction).
  7. **V14 + two regimes** (SIGMA_THRESH, TOX_THRESH, FEE_CALM; else full pipeline).
  8. **V14 + conditional tail** (compress only when fee > 75 bps, then clamp 85).
- **Criteria:** Edge ≥ 382 as first win; then 385+; avoid regressions (≥ 380).

---

## Step 7 — Recommendation

**Prioritized order (other levers):**

1. **pImplied only on V14 (V18)**  
   Lowest slot cost (2: prev bid, prev ask); directly improves price signal for pHat/ret and thus dir/surge. Add nothing else. If edge ≥ 382, keep; if not, we still have a cleaner baseline for next levers.

2. **Sigma×tox + cubic tox on V14 (V19 or same as V18 if pImplied helps)**  
   No new slots; add SIGMA_TOX_COEF and TOX_CUBIC_COEF to vulnerable-side tox. Tune small (e.g. 50e14, 15e14) so we don’t hit cap too often. Addresses “sharper when wrong and volatile.”

3. **Trade-aligned boost on V14 (V20 or stack on V18/V19)**  
   No new slots; add boost when current trade is toxic, capped. Quick to add and test.

4. **First-in-step on V14 (V21)**  
   One slot (stepTradeCount); dual alpha and sigma only on first-in-step. Reduces multi-trade-step noise. Can stack on pImplied (use pImplied in first-in-step pHat update).

5. **dirState alone on V14 (V22)**  
   One slot; flow-direction memory. Try after the above; V8’s regression may have been tuning or bundling.

6. **Stale + attract alone (V23)**  
   No slots; try after dirState. If both help, can combine.

7. **Two regimes (V24)**  
   Threshold switch calm vs stressed. More structural; try after signal/tox/boost levers.

8. **Conditional tail (V25)**  
   Only compress above 75 bps. Test if tail helps when it doesn’t shrink the 25–75 band.

**Summary:** We’re stuck at ~380 because cap/tail/cap-raise are already explored. The next levers are **signal and tox**: pImplied only, sigma×tox + cubic tox, trade-aligned boost, then first-in-step, then dirState/stale/regimes/conditional tail. Add one at a time on V14 and measure. Document each in `/docs` and version per workspace rules.

---

## References

- [2025-02-09-Sapient-V14-amm-fee-designer-analysis.md](2025-02-09-Sapient-V14-amm-fee-designer-analysis.md)
- [2025-02-09-Sapient-V15-amm-fee-designer-analysis.md](2025-02-09-Sapient-V15-amm-fee-designer-analysis.md)
- [2025-02-09-Sapient-audit-380-vs-526.md](2025-02-09-Sapient-audit-380-vs-526.md)
- [2025-02-09-YQ-extract-for-Sapient.md](2025-02-09-YQ-extract-for-Sapient.md)
- [SapientStrategyV13.sol](../amm-challenge/contracts/src/SapientStrategyV13.sol) — first-in-step implementation
- [SapientStrategyV8.sol](../amm-challenge/contracts/src/SapientStrategyV8.sol) — pImplied, dirState, stale+attract, trade boost
