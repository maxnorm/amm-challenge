# Sapient V20 — AMM Fee Designer Diagnosis (380 vs 526)

**Date:** 2025-02-10  
**Strategy:** SapientStrategyV20.sol  
**Context:** Plateau at ~380 edge; leaderboard top ~526. Goal: identify core weaknesses and a path to improve (including full rewrite or new angle).

---

## Step 1 — Loss Diagnosis (Why We're Stuck at ~380)

### What V20 Actually Does

- **Base:** 8 bps + additive terms: `sigma×SIGMA_COEF`, `imbalance×IMB_COEF`, `vol×VOL_COEF`, symmetric tox (linear + quad + SYM_HIGH above 1.5%).
- **Floor:** `imbFloor = BASE_LOW + imbalance×FLOOR_IMB_SCALE`; decay toward floor when time advances (no trade).
- **Toxicity:** toxEma from capped ret; **vulnerable-side** premium (linear + quad); **trade-aligned boost** when current trade is toxic (buy when spot ≥ pHat or sell when spot < pHat), size-scaled, cap 25 bps.
- **Directionality:** only when ret ≤ gate and ret ≥ 0.5%; premium to the “wrong” side, cap 30 bps.
- **Surge:** when ret > gate, 15–40 bps to the trade side.
- **Size bump:** tradeRatio (capped 20%) × K_SIZE, cap 20 bps.
- **Cap:** hard 75 bps on all outputs.
- **State:** pHat, volatility, timestamp, sigmaHat, toxEma; **single** pHat alpha (0.26), **sigma updated every trade**.

### Three Core Mechanical Weaknesses

1. **No activity/flow in the base fee**  
   Base is built from **current** sigma, imbalance, vol, and tox only. There is no notion of “how many trades per step” or “recent flow size.” Top strategies (and YQ) encode **lambdaHat**, **sizeHat**, and **flowSize** (lambda×size) in the base. In high-activity bursts (many arb trades per step), we charge per trade but do not scale the base with intensity, so we **underprice burst toxicity** relative to strategies that do.

2. **Single alpha, sigma every trade (no first-in-step)**  
   We update pHat and sigmaHat on **every** trade. In multi-trade steps, the “fair price” and volatility therefore move with each hit. That makes us **noisier** and easier to exploit: e.g. “move us then fade” — first trade moves pHat/sigma, later trades get a different fee on the reversion. Top strategies (and YQ) use **first-in-step** logic: fast alpha and sigma update only on the first trade in a step; later trades in the same step use a slow alpha and do not update sigma. We lack that, so we **overreact to noise within a step** and **under-differentiate** first-mover toxicity.

3. **Hard cap instead of tail compression**  
   We clamp every fee at 75 bps. When the “true” fee would be 90 or 100 bps, we leave margin on the table and **cap arbitrage** is possible. Top strategies use **tail compression** (e.g. above a knee, fee = knee + slope×(fee − knee), then clamp), preserving gradient and charging more in the tail without a hard ceiling. We **clip marginal value** in high-stress regimes.

### Why This Explains the 380 vs 526 Gap

- **~146 points** is too large to fix with coefficient tweaks. The leaderboard reverse-engineering showed top strategies use:
  - **Multi-regime** (hi/disc/cap/endcap/latedisc) and **windowed features** (cross5, feW10, cand).
  - **Tail and time handling** (tail2c220, endcap33, latedisc16).
- We already have: low base (8 bps), additive build-up, toxicity, dir, surge, size, trade-aligned boost. What we **don’t** have:
  - **Activity/flow in base** (no lambda/size/flowSize).
  - **First-in-step** (single alpha, sigma every trade).
  - **Tail compression** (hard 75 bps cap).
  - **Explicit regime switch** (e.g. “calm = flat low fee, stress = full pipeline”).
  - **Time/episode awareness** (e.g. late-sim discount or endcap).

So the plateau is **structural**: we’re in a flat region of strategy space because we haven’t added the **structural** levers the sim (and top scores) reward.

---

## Step 2 — Adversarial Exploitation

1. **Cap arbitrage**  
   When true fee would exceed 75 bps, we output 75 bps. Arbitrageurs get marginal trades at a capped price; we leave profit on the table. **Tail compression** would reduce this.

2. **Move-then-fade (multi-trade step)**  
   In a step with multiple trades, we update pHat and sigma every time. A bot can: (1) move price with a first trade, (2) let us raise fees on that side, (3) fade on the next trade(s) at a fee that’s still based on updated state. Our **every-trade sigma** and single alpha make this pattern cheaper than for strategies that only update sigma on first-in-step and use a slow alpha for the rest.

3. **Activity burst under-pricing**  
   We have no lambda/size/flow in base. A burst of many small-to-medium toxic trades in one step is charged per trade but not with an “intensity” premium. So **high-activity toxic flow** is systematically under-priced vs strategies that include lambdaHat and flowSize.

4. **Retail routing in calm**  
   If in calm regimes our fee (8 bps + sigma + imb + vol + symTox) often sits above the normalizer (e.g. 30 bps), retail routes away. We then see a higher share of flow when we’re already stressed (more toxic on average) → **adverse selection**. A **two-regime** design (very low flat fee in calm, full pipeline in stress) could keep calm-regime fee lower and attract more benign flow.

5. **Trade-aligned boost predictability**  
   We add a boost when (buy & spot ≥ pHat) or (sell & spot < pHat). That’s a clear rule; sophisticated flow can anticipate when we’ll charge the boost and time size or split trades. **Regime-based** or **multi-feature** toxicity (e.g. combined with activity/crossing signals) would be harder to game than a single binary condition.

---

## Step 3 — Failure Modes

| Regime / condition              | Limitation in V20                         | Effect |
|---------------------------------|-------------------------------------------|--------|
| High activity (many trades/step)| No lambdaHat, sizeHat, flowSize in base  | Undercharge; arb bursts cheap |
| Calm, low vol/imb               | Additive terms can still push fee up      | Risk of retail routing if > normalizer |
| Near / above 75 bps             | Hard clip                                 | Cap arbitrage; lost marginal fee |
| Multi-trade steps               | Same pHat/sigma update for all trades     | Noisy; move-then-fade exploit |
| Late simulation                 | No time/episode logic                     | No endcap/latedisc-style protection or discount |
| Very large single trade         | Size bump cap 20 bps, trade ratio cap 20% | Tail of size distribution under-priced vs “tail2c” style |

---

## Step 4 — New Strategy Ideas

### A. First-in-step + dual alpha (structural, high impact)

- **Idea:** Treat “step” as timestamp change. On **first trade in step**: use current PHAT_ALPHA (0.26), update sigmaHat. On **later trades in same step**: use a slow PHAT_ALPHA_RETAIL (e.g. 0.05), **do not** update sigmaHat.
- **Addresses:** Noisy multi-trade steps; move-then-fade; aligns with YQ and leaderboard “cross5”/windowed logic (short-horizon differentiation).
- **Slots:** One: `stepTradeCount` (or infer first-in-step from timestamp + stored lastTs and a step trade counter reset on timestamp change).

### B. Activity/flow in base (structural, high impact)

- **Idea:** Add **lambdaHat** (trades per step, EWMA), **sizeHat** (smoothed trade size), and in base add `LAMBDA_COEF×lambdaHat` and `FLOW_SIZE_COEF×lambdaHat×sizeHat`.
- **Addresses:** Under-pricing of high-activity and flow intensity; aligns with YQ and with “feW10”-style windowed flow.
- **Slots:** lambdaHat, stepTradeCount (shared with A), sizeHat (or reuse one slot with careful encoding).

### C. Two regimes: calm vs stress (structural)

- **Idea:** If sigma and tox below thresholds → **calm**: output a **flat low fee** (e.g. 10–15 bps) for both sides. Else → **stress**: run full V20 pipeline (base + tox + dir + surge + size + trade boost), then apply cap or tail compression.
- **Addresses:** Retail routing in calm; threshold-type behavior (competitive in normal, elevated in high vol); matches “disc”/“hi” style naming on leaderboard.
- **Slots:** None if thresholds are computed from existing sigma/tox.

### D. Tail compression instead of hard cap (structural)

- **Idea:** Above a knee (e.g. 5 bps), fee = knee + slope×(fee − knee); different slopes for protect vs attract if desired; then clamp to MAX_FEE (10%).
- **Addresses:** Cap arbitrage; preserves gradient in the tail; aligns with “cap”/“endcap”/“tail” style handling.
- **Slots:** None (pure function of computed fee).

### E. Time/episode awareness (new angle)

- **Idea:** Use `trade.timestamp` (simulation step index). Near end of a known horizon (e.g. timestamp > T_END − W), apply **late discount** (reduce fee to unwind inventory) or **endcap** (stricter cap to avoid last-minute blow-ups). If horizon unknown, use a simple rule (e.g. if timestamp is very high relative to a running max, treat as “late”).
- **Addresses:** End-of-sim inventory risk and tail behavior; aligns with “latedisc”/“endcap” from leaderboard.
- **Slots:** Possibly one for “maxTimestampSeen” or use a constant T_END if the sim exposes it.

### F. Full rewrite: “Leaderboard-style” minimal core (new angle)

- **Idea:** Start from a **minimal** core that only has the structures that leaderboard names suggest: (1) **windowed volatility** (e.g. 5–10 step window), (2) **regime switch** (calm = low flat, stress = build-up), (3) **tail handling** (compression or endcap), (4) **optional late discount**. Drop or simplify: single “cross” or “candle” style signal instead of many separate levers; fewer coefficients; one clear “hi” and one “disc” band.
- **Addresses:** Risk that we’re at a **local optimum** of the current family (V14+ levers). A clean sheet with regime + tail + time might find a different basin that scores higher.
- **Trade-off:** More implementation and tuning; slot budget must be respected.

---

## Step 5 — Formulas & Pseudocode

### A. First-in-step + dual alpha

```text
// Slot: stepTradeCount (or step index). On timestamp change: stepTradeCount = 0.
firstInStep = (timestamp != lastTs);
if (firstInStep) stepTradeCount = 0;
stepTradeCount += 1;

alpha = firstInStep ? PHAT_ALPHA : PHAT_ALPHA_RETAIL;   // e.g. 0.26 vs 0.05
if (ret <= adaptiveGate) {
    pHat = (ONE_WAD - alpha) * pHat + alpha * pImplied;  // or spot if no pImplied
}
if (firstInStep) {
    sigmaHat = SIGMA_DECAY * sigmaHat + (ONE_WAD - SIGMA_DECAY) * ret;
}
// toxEma can stay every-trade or also first-in-step; same for vol.
```

### B. Activity/flow in base

```text
// On new step (timestamp > lastTs):
if (timestamp > lastTs) {
    elapsed = min(timestamp - lastTs, ELAPSED_CAP);
    if (stepTradeCount > 0 && elapsed > 0) {
        lambdaInst = (stepTradeCount * ONE_WAD) / elapsed;
        if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
        lambdaHat = LAMBDA_DECAY * lambdaHat + (ONE_WAD - LAMBDA_DECAY) * lambdaInst;
    }
    sizeHat = sizeHat * powWad(SIZE_DECAY, elapsed);
    stepTradeCount = 0;
}
stepTradeCount += 1;
if (tradeRatio > SIGNAL_THRESHOLD) {
    sizeHat = SIZE_BLEND * sizeHat + (ONE_WAD - SIZE_BLEND) * tradeRatio;
    if (sizeHat > ONE_WAD) sizeHat = ONE_WAD;
}
// Base:
fBase = BASE_LOW + SIGMA_COEF*sigmaHat + IMB_COEF*imbalance + VOL_COEF*vol
      + SYM_TOX_TERM(toxEma)
      + LAMBDA_COEF * lambdaHat
      + FLOW_SIZE_COEF * lambdaHat * sizeHat;
```

### C. Two regimes (calm vs stress)

```text
calm = (sigmaHat <= SIGMA_CALM) && (toxEma <= TOX_CALM);
if (calm) {
    bidFee = askFee = FEE_CALM;   // e.g. 12e14 (12 bps)
    // Optionally still update state (pHat, sigma, toxEma) for next step
} else {
    // Full pipeline: rawFee, tox premium, dir, surge, size, trade boost
    // then tail compression and clamp
}
```

### D. Tail compression

```text
function compressTail(fee, knee, slope) {
    if (fee <= knee) return fee;
    return knee + (fee - knee) * slope / ONE_WAD;
}
// After computing bidFee, askFee (before final clamp):
bidFee = min(MAX_FEE, compressTail(bidFee, TAIL_KNEE, TAIL_SLOPE_BID));
askFee = min(MAX_FEE, compressTail(askFee, TAIL_KNEE, TAIL_SLOPE_ASK));
```

### E. Late discount / endcap (conceptual)

```text
// If we had a known sim length T_END:
late = (timestamp >= T_END - LATE_WINDOW);
if (late) {
    fee = fee * (ONE_WAD - LATE_DISC) / ONE_WAD;   // e.g. reduce 10%
    // or: cap = min(cap, ENDCAP);   // stricter cap near end
}
```

### F. Minimal “leaderboard-style” core (sketch)

```text
// State: pHat, sigmaHat, vol (windowed or EMA), stepTradeCount, timestamp.
// Optional: lambdaHat, sizeHat.
// 1) Classify regime: calm = (sigma < t1 && vol < t2); stress = !calm.
// 2) calm: bidFee = askFee = FEE_LO (e.g. 10 bps).
// 3) stress: raw = BASE + a*sigma + b*imb + c*vol + d*tox;
//    apply asymmetry (vulnerable side +premium);
//    fee = compressTail(raw, KNEE, SLOPE); clamp to MAX_FEE.
// 4) Optional: first-in-step sigma; activity term in raw when stress.
// 5) Optional: if timestamp near end, apply latedisc or endcap.
```

---

## Step 6 — Simulation Blueprint

- **Inputs:** Same harness as today; 1000 sims; fixed or varied seeds for comparability.
- **Metrics:**
  - **Edge** (primary).
  - Fee distribution (mean, p90, cap-hit rate) by side (bid/ask).
  - By regime: calm (low sigma/tox) vs active vs high-tox (if harness or logs allow).
  - Optional: retail vs arb edge if reported.
- **Scenarios:**
  1. **Baseline:** V20 (confirm 380).
  2. **V21 — First-in-step only:** Add stepTradeCount, dual alpha, sigma only on first-in-step; no activity terms. Measure edge.
  3. **V22 — First-in-step + activity/flow:** Add lambdaHat, sizeHat, LAMBDA_COEF and FLOW_SIZE_COEF in base. Measure edge.
  4. **V23 — Two regimes:** V20 (or V21) + calm/stress switch; FEE_CALM and thresholds tuned. Measure edge.
  5. **V24 — Tail compression:** Replace hard 75 bps cap with knee + slope, same pipeline. Measure edge.
  6. **Combinations:** e.g. V21 + tail compression; V21 + two regimes.
  7. **Full rewrite:** Minimal leaderboard-style (regime + tail + optional late); measure edge.
- **Criteria:** Edge ≥ 400 as first milestone; then 450+; compare to 526 to gauge remaining gap.

---

## Step 7 — Recommendation

### Core weakness (why we can’t break above 380)

The **core** weakness is **structural**, not coefficient-sized:

1. **No activity/flow in base** → we underprice high-activity toxic flow.
2. **No first-in-step** → we’re noisier and exploitable in multi-trade steps (move-then-fade).
3. **Hard cap** → we leave margin on the table in the tail (cap arbitrage).

Fixing **only** coefficients or adding one more small lever (as in V18–V20) keeps us in the same flat region; the sim and leaderboard suggest the gap is closed by **regime differentiation**, **flow/activity**, **first-in-step**, and **tail/time** handling.

### Prioritized path

1. **First-in-step + dual alpha (V21)**  
   - **Why first:** One extra slot (stepTradeCount), clear logic, directly targets move-then-fade and multi-trade noise; aligns with YQ and leaderboard “cross”/windowed behavior.  
   - **Risk:** Low. If edge doesn’t move, we still learn that first-in-step alone isn’t enough in this sim.

2. **Tail compression (V24 or same branch as V21)**  
   - **Why second:** No new state; drop-in replacement for hard cap; addresses cap arbitrage.  
   - **Risk:** Low. Tune knee (e.g. 5 bps) and slope (e.g. 0.92–0.96) conservatively.

3. **Two regimes (V23)**  
   - **Why third:** No new slots if we use existing sigma/tox; addresses retail routing and threshold-type behavior; matches “disc”/“hi” meta.  
   - **Risk:** Medium (threshold and FEE_CALM tuning).

4. **Activity/flow in base (V22)**  
   - **Why fourth:** Highest structural impact but more slots and constants (lambdaHat, sizeHat, stepTradeCount). Do after first-in-step so stepTradeCount is shared.  
   - **Risk:** Slot and stack discipline; tune LAMBDA_COEF and FLOW_SIZE_COEF small at first.

5. **Full rewrite (new angle)**  
   - **When:** If V21 + tail + regime + activity still leave us far from 450+. Then try a **minimal** leaderboard-style design: regime switch, windowed vol, tail compression, optional late discount, fewer levers and clearer “calm vs stress” behavior.  
   - **Goal:** Escape the current local optimum and see if a different structure reaches a higher basin.

### Summary table

| Weakness / gap to 526        | Fix                          | Priority |
|-----------------------------|------------------------------|----------|
| Multi-trade noise; move-fade| First-in-step + dual alpha   | 1 (V21)  |
| Cap arbitrage; tail margin  | Tail compression            | 2 (V24)  |
| Retail routing; calm vs stress | Two regimes (calm/stress) | 3 (V23)  |
| Activity burst under-pricing| lambdaHat + sizeHat in base  | 4 (V22)  |
| Local optimum; different basin | Full rewrite (minimal regime+tail+time) | 5 (if needed) |

---

## References

- [2025-02-09-Sapient-audit-380-vs-526.md](2025-02-09-Sapient-audit-380-vs-526.md) — Structural gaps vs YQ; exploit vectors; failure modes.
- [2025-02-09-Sapient-why-380-plateau.md](2025-02-09-Sapient-why-380-plateau.md) — Why V14+ levers don’t move edge.
- [2025-02-09-YQ-extract-for-Sapient.md](2025-02-09-YQ-extract-for-Sapient.md) — YQ patterns: lambda, sizeHat, tail compression, first-in-step.
- Leaderboard reverse-engineering (previous report): top strategy name suggests multi-regime, windowed features (cross5, feW10), tail and time handling (tail2c220, endcap33, latedisc16).

---

## Changelog

- **2025-02-10:** Full amm-fee-designer run on V20: loss diagnosis (no activity/flow, no first-in-step, hard cap); exploit vectors; failure modes; ideas A–F including full rewrite; formulas and pseudocode; simulation blueprint; recommendation (V21 → tail → two regimes → activity → rewrite if needed).
