# From Scratch: Leaderboard + YQ Reverse-Engineering and New Strategy Design

**Date:** 2025-02-10  
**Purpose:** Reverse-engineer the [AMM Challenge](https://www.ammchallenge.com/) leaderboard and the YQ reference strategy to define a clean starting point for a new strategy build. Current Sapient V33 edge ~40; leaderboard top ~526.

---

## Part 1 — Leaderboard Reverse-Engineering

### What the competition is

- **Goal:** Design a **fee strategy** for an AMM that faces both **arbitrage bots** and **retail traders**.
- **Score:** **Average edge** over **1000 simulations** with **randomized parameters** (robustness matters).
- **Interface:** Implement `afterInitialize(initialX, initialY)` and `afterSwap(trade)`; return `(bidFee, askFee)` in WAD (1e14 = 1 bps). Fees apply to the **next** trade.
- **Constraints:** 32 storage slots, no config changes (foundry.toml etc. fixed).

### Leaderboard snapshot (from ammchallenge.com)

| Rank | Strategy              | Avg Edge | Note        |
|------|------------------------|----------|-------------|
| #1   | New CLIZA.ai Soon!     | +526.39  |             |
| #2   | v2110                  | +526.24  |             |
| #3   | overfit                | +524.74  |             |
| #4   | AE154                  | +524.63  |             |
| #5   | PARADIGMFARMINGINFERENCE | +524.48 |          |
| …    | …                      | ~524+    | Top 10      |

**Takeaways:**

- **Target edge band:** ~524–526. Our current best (Sapient V23 ~380, V33 ~40) is far below; we need a structural rethink, not only tuning.
- **Robustness:** 1000 sims with randomized params → strategy must work across regimes (calm, volatile, one-sided flow).
- **Fee level:** Docs and YQ suggest “competitive in normal” (e.g. ~30 bps) and elevated when wrong/volatile; overcharging (e.g. pegged at 75 bps) drives flow away and collapses edge.

---

## Part 2 — YQ Strategy Reverse-Engineering

**Source:** [YQStrategy.sol](../amm-challenge/contracts/src/refs/YQStrategy.sol) (repo: https://github.com/jiayaoqijia/amm-challenge-yq). Observed edge in our env: **~520**.

### Slot layout (11 slots used)

| Slot | Content        | Role |
|------|----------------|------|
| 0    | prev bid fee   | pImplied |
| 1    | prev ask fee   | pImplied |
| 2    | last timestamp | New-step, elapsed |
| 3    | dirState       | Flow direction (WAD = neutral) |
| 4    | actEma         | Activity (trade size blend) |
| 5    | pHat           | Fair price EWMA |
| 6    | sigmaHat       | Volatility (gate + sigma×tox) |
| 7    | lambdaHat      | Trades-per-step |
| 8    | sizeHat        | Smoothed trade size |
| 9    | toxEma         | Toxicity EMA |
| 10   | stepTradeCount | First-in-step, lambda |

### Formula (conceptual)

1. **Base (fBase)**  
   `BASE_FEE (3 bps) + SIGMA_COEF×sigmaHat + LAMBDA_COEF×lambdaHat + FLOW_SIZE_COEF×(lambdaHat×sizeHat)`  
   No imbalance, no vol, no symmetric tox in this layer.

2. **Mid (fMid)**  
   `fBase + TOX_COEF×tox + TOX_QUAD_COEF×tox² + ACT_COEF×actEma + SIGMA_TOX_COEF×sigmaHat×tox + TOX_CUBIC_COEF×tox³`

3. **Direction (dirState)**  
   `dirDev = |dirState - WAD|`, `sellPressure = (dirState >= WAD)`  
   `skew = DIR_COEF×dirDev + DIR_TOX_COEF×dirDev×tox`  
   Protect side: fMid + skew; attract side: fMid - skew.

4. **Stale / attract**  
   `staleShift = STALE_DIR_COEF×tox`; attract = staleShift × STALE_ATTRACT_FRAC subtracted from the other side (floor 0).  
   If spot ≥ pHat: bid += stale, ask -= attract; else ask += stale, bid -= attract.

5. **Trade-aligned boost**  
   If (isBuy && spot ≥ pHat) or (!isBuy && spot < pHat): add TRADE_TOX_BOOST×tradeRatio to bid or ask.

6. **Tail compression**  
   Above knee (e.g. 5 bps): fee → knee + slope×(fee - knee). Slope protect (e.g. 0.93) vs attract (e.g. 0.955). Then clamp to MAX_FEE.

### Critical design choices in YQ

- **pImplied for pHat/ret:** Uses fee-adjusted price so one toxic trade doesn’t drag fair value.
- **First-in-step:** Faster pHat blend and **sigma update only on first trade in step**; retail alpha (slower) otherwise.
- **Step-based decay:** On `timestamp > lastTs`, decay dirState, actEma, sizeHat, toxEma, and update lambda from stepTradeCount/elapsed; no per-trade decay of those.
- **Single asymmetry source for “who to protect”:** dirState (+ stale/attract). No ret-based dir premium, no surge, no imbalance-based protect/attract.
- **Low base, build-up only:** 3 bps + sigma + lambda + flowSize in base; all tox/activity in mid. So “normal” can stay near 30 bps; high activity/tox pushes fee up without a high floor.

---

## Part 3 — Why Sapient Diverged and Regressed

- **V23 (~380):** Different base: 8 bps + sigma + **imbalance + vol + symmetric tox** + vulnerable-side tox + ret-based dir + surge + tail by **reserve imbalance**. No activity (λ, flowSize, actEma), no pImplied, no first-in-step, no dirState, no stale/attract.
- **V24 (40.30):** We **added** YQ-style activity (lambda, flowSize, actEma) **on top of** V23’s base. YQ’s coefficients (e.g. FLOW_SIZE_COEF, ACT_COEF) are sized for a base that has **only** 3 bps + sigma + lambda + flowSize. Our base already had imb/vol/symTox → raw fee often 100–500+ bps → clamp to 75 bps on almost every trade → we look “max fee” always → flow leaves, edge collapses.

**Lesson:** You cannot paste YQ’s activity layer onto a different base. Either use **YQ’s base formula** (no imb/vol/symTox in base) or scale activity coefficients way down and accept that we’re not really “YQ-like” in structure.

---

## Part 4 — Where to Start From Scratch

**Principle:** Start from a **minimal YQ-aligned core** (same structural choices as YQ), then add or tune **one lever at a time** and measure edge after each step.

### Phase 0 — Minimal YQ clone (baseline)

- **Base:** 3 bps + sigma + lambda + flowSize only (no imbalance, no vol, no symTox in base).
- **Mid:** fBase + tox (linear + quad) + actEma + sigma×tox + cubic tox.
- **Asymmetry:** dirState skew only (no ret-based dir, no surge). Tail protect/attract by dirState. Stale/attract by spot vs pHat.
- **Price/sigma:** pImplied for ret and pHat update; adaptive gate; first-in-step alpha and sigma update only on first-in-step.
- **Decay:** Step-based (elapsed); _powWad and _decayCentered for dirState, actEma, sizeHat, toxEma, lambda.
- **Trade-aligned boost:** Optional from day one (YQ has it).
- **Tail:** Knee + slope (protect/attract) then clamp to MAX_FEE (10%).
- **Slots:** Same layout as YQ (prev bid/ask, lastTs, dirState, actEma, pHat, sigmaHat, lambdaHat, sizeHat, toxEma, stepTradeCount).

**Deliverable:** One contract (e.g. `SapientStrategyV34.sol` or a new name) that is a **close copy of YQ** (same formula and slot layout, constants copy-pasted). Run 1000 sims; expect edge in the same ballpark as YQ (~520) if the harness matches. This is our **reference baseline** for “from scratch”.

### Phase 1 — Incremental changes (one at a time)

After Phase 0 is validated:

1. **Tune constants** (base, coefs, knee, slopes, decay) in small steps; re-run 1000 sims each time.
2. **Add or substitute one structural idea** per iteration (e.g. a small imbalance term in base, or a different tail rule), then revert if edge drops.
3. **Never** stack a full “other strategy” (e.g. our old imb/vol/symTox base) under YQ’s activity coefs without rescaling or removing the other base.

### Phase 2 — Documentation and versioning

- Each new variant is a **new contract file** with suffix Vx (per workspace versioning rule).
- All changes and results documented under `/docs` (per workspace rule).

---

## Part 5 — Summary Table: YQ vs Sapient (what to adopt from scratch)

| Concept              | YQ | Sapient legacy | From-scratch start |
|----------------------|----|-----------------|---------------------|
| Base level           | 3 bps | 8 bps         | **3 bps** |
| Base drivers         | sigma, lambda, flowSize | sigma, imb, vol, symTox | **sigma, lambda, flowSize only** |
| pImplied             | Yes | No             | **Yes** |
| First-in-step        | Yes (pHat alpha, sigma) | No | **Yes** |
| Activity in base     | λ, flowSize, actEma | None (or stacked wrongly) | **Yes, YQ layout** |
| Step-based decay    | Yes | Partial        | **Yes** |
| dirState             | Yes (skew + tail) | No | **Yes** |
| Stale/attract        | Yes | No             | **Yes** |
| sigma×tox, cubic tox | Yes | No             | **Yes** |
| Tail                 | knee + slope, by dirState | knee + slope, by imbalance | **By dirState** |
| Imbalance/vol in base | No | Yes            | **No** (can add later, carefully) |
| Ret-based dir / surge | No | Yes            | **No** (keep single asymmetry source) |

---

## References

- [AMM Challenge](https://www.ammchallenge.com/) — leaderboard and rules
- [YQStrategy.sol](../amm-challenge/contracts/src/refs/YQStrategy.sol) — reference implementation
- [2025-02-10-Sapient-V23-vs-YQ-structural-comparison.md](2025-02-10-Sapient-V23-vs-YQ-structural-comparison.md)
- [2025-02-09-YQ-extract-for-Sapient.md](2025-02-09-YQ-extract-for-Sapient.md)
- [YQ_STRATEGY_EXPLAINED.md](YQ_STRATEGY_EXPLAINED.md)
- [2025-02-10-V24-edge-40-investigation.md](2025-02-10-V24-edge-40-investigation.md)
