# V7 Structural Brainstorm — Breaking the 400 Edge

**Date:** 2025-02-09  
**Goal:** Brainstorm structural changes to VIAF (V6, ~374 edge) to cross the 400 edge, using concept extraction from YQ (520 edge) and research — without copying YQ.

---

## 1. Current State: Why We're Stuck at ~374

V6 already applies:

- **Base:** 30 bps + vol×K_VOL + imb×K_IMB, symmetric tox (12 bps linear + 30 bps quad), imbalance floor, time decay, cap 75–100 bps.
- **Vulnerable side:** Tox premium (25 + 60×tox² bps) + 60% asymmetry.
- **Directionality:** Only when ret ≥ 0.5%; up to 30 bps on ask if spot ≥ pHat else bid.
- **Surge:** 25 bps on the side just hit when ret > adaptive gate.

From the v6 deep review, the main **structural** reasons we plateau:

1. **Cap binding** — Dir + surge + base + tox often sum to >100 bps on the vulnerable side; the cap clips the marginal gain on the worst flow.
2. **Dir and surge on the same leg** — When ret > gate we add both; they compete for the same cap budget.
3. **pHat lag in trends** — Dir uses spot ≥ pHat; when pHat lags, we often raise the wrong side (e.g. ask while bid gets hit).
4. **Symmetric tox is modest** — Non-vulnerable side stays relatively cheap at high tox; arb can still fade the surge.
5. **No trade-size or per-trade signal** — We don’t use `amountX`/`amountY` or step activity; one large toxic trade pays the same as many small ones.
6. **Surge is fixed and gate-only** — 25 bps regardless of how far ret is above the gate; no size- or impact-based scaling.

So the wall is **structural**: cap, overlapping mechanisms, no size/activity, and laggy directionality.

---

## 2. Concepts Extracted from YQ (No Copy — Ideas Only)

YQ sits at ~520 edge. Below are **concepts** we can reuse in our own way, not a clone.

### 2.1 pImplied for pHat and ret

- **Idea:** Use the **fee that was just paid** to back out an “implied” price:  
  γ = 1 − feeUsed, then pImplied = spot×γ (buy) or spot/γ (sell).  
  Use **pImplied** (not spot) when updating pHat and when computing ret for the gate.
- **Why it helps:** Reduces letting a single toxic trade move pHat; only “consistent with fee” moves get blended in. Our V6 uses **spot** for pHat update, so one big arb can drag pHat and make dir noisy.
- **Adoption:** Add a slot for “previous bid/ask fee” (or use stored fees). Compute pImplied from spot + feeUsed; use it in the gate condition and in pHat blend. Keeps our gate/sigma logic but with a cleaner price signal.

### 2.2 Persistent direction state (dirState)

- **Idea:** Maintain a **centered direction state** (e.g. WAD = neutral, above = more buys of X, below = more sells), updated by **trade direction and size**, decaying over **elapsed steps** (e.g. 0.8^elapsed).
- **Why it helps:** We currently infer “rich in Y” from reserves and dir from spot vs pHat only. A persistent flow-direction state reacts to *who has been hitting us* over time and decays when no one trades, so we protect the side that’s been under pressure.
- **Adoption:** Add 1–2 slots: dirState (and maybe a decay factor). On each trade, if trade size is above a threshold, push dirState up (buy) or down (sell) by an amount that depends on trade size. On new step, decay dirState toward WAD. Use dirState (distance from WAD) to skew bid vs ask in addition to (or instead of) our current spot≥pHat dir.

### 2.3 Activity, size, and flow (actEma, sizeHat, lambdaHat)

- **Idea:** Track **trade size relative to reserves** (e.g. tradeRatio = amountY/reserveY, capped), **smoothed** (sizeHat, actEma), and **trades per step** (lambdaHat = stepTradeCount/elapsed). Feed a “flow size” term (e.g. λ×size) into the base fee.
- **Why it helps:** We have no notion of “how big” or “how frequent” trades are. Large and/or frequent flow is where LVR and adverse selection are largest; charging more when flow is large/frequent targets the right trades.
- **Adoption:** We have `amountX`, `amountY`, `reserveX`, `reserveY`, `timestamp` in TradeInfo. Compute tradeRatio (e.g. amountY/reserveY or amountX/reserveX, capped); add slots for sizeHat, actEma, stepTradeCount, lastTs. On new step: decay sizeHat/actEma, update lambdaHat from count/elapsed, reset count. Add a small base term like K_FLOW×lambdaHat×sizeHat (or similar). Optionally add a **trade-size bump** on the side just hit: e.g. K_SIZE×tradeRatio (capped) to the leg that was used.

### 2.4 Cubic toxicity and sigma×tox

- **Idea:** Fee depends on toxicity with **linear + quadratic + cubic** terms, and a **sigma×tox** term.
- **Why it helps:** When we’re very wrong (high tox), fees should rise sharply; cubic does that. sigma×tox charges more when it’s both volatile and wrong.
- **Adoption:** We already have linear + quad on vulnerable side and symmetric linear+quad. Add: (1) a **cubic** term (e.g. TOX_CUBIC×toxEma³) on the vulnerable side and/or in the symmetric part; (2) a term **SIGMA_TOX_COEF×sigmaHat×toxEma** in the base or mid fee. Keeps our toxEma/sigmaHat semantics; only adds terms.

### 2.5 Stale-direction with “attract” discount

- **Idea:** On the **vulnerable** side (e.g. bid when spot ≥ pHat): add a fee term (e.g. STALE_DIR_COEF×tox). On the **other** side: **subtract** a smaller amount (e.g. STALE_ATTRACT_FRAC×that term) so the rebalancing side is explicitly cheaper.
- **Why it helps:** We already raise the vulnerable side; we don’t explicitly **lower** the other side. Doing both creates a clearer spread: protect one side, attract flow on the other.
- **Adoption:** After computing base + tox + asym, add “stale shift” = K_STALE×toxEma. Add to vulnerable side; subtract min(askFeeOrBidFee, attractFrac×staleShift) from the other (with a floor of 0). No new state; just a different split of the same idea.

### 2.6 Trade-aligned toxicity boost

- **Idea:** If the **current** trade was “toxic” in our model (e.g. buy when spot ≥ pHat, or sell when spot < pHat), add an **extra fee on that same side** for the **next** trade, scaled by **trade size** (e.g. TRADE_TOX_BOOST×tradeRatio).
- **Why it helps:** The trade that just happened already paid the old fee; the next one on that side might be similar (follow-up arb). Boosting that side by a size-scaled amount charges more when the last trade was large and toxic.
- **Adoption:** Boolean: tradeAligned = (isBuy && spot ≥ pHat) || (!isBuy && spot < pHat). If true, add K_TRADE_TOX×tradeRatio (capped) to bid (if buy) or ask (if sell). Uses existing tox/spot/pHat and TradeInfo; no new state.

### 2.7 Tail compression (knee + slope)

- **Idea:** Above a small “knee” (e.g. 5 bps), **compress** the fee: fee_compressed = knee + slope×(fee − knee). Use a **steeper** slope on the protect side (e.g. 0.93) and a **gentler** one on the attract side (e.g. 0.955) so the attract side stays relatively cheaper.
- **Why it helps:** Avoids blowing fees to 10% on small moves; keeps asymmetry without extreme values. Our 75–100 bps cap is a hard cut; tail compression is a smooth way to limit upside while preserving spread.
- **Adoption:** After computing bid/ask, apply a compression function per side (different slope for “protect” vs “attract”). Then clamp to [0, MAX_FEE]. Can replace or sit alongside our current cap.

### 2.8 Time-step–consistent decay

- **Idea:** When a **new step** is detected (timestamp > lastTs), decay state by **elapsed** steps: e.g. state_new = state_old × decay^elapsed (using a fixed decay factor and capping elapsed).
- **Why it helps:** Our V6 decay is “per step” with a fixed factor; YQ uses pow(decay, elapsed) so that 5 steps with no trade decay more than 1 step. More consistent with “time without flow.”
- **Adoption:** In afterSwap, if trade.timestamp > lastTs, compute elapsed = min(timestamp − lastTs, ELAPSED_CAP). For each decaying state (e.g. toxEma, or a new dirState), apply decay^elapsed instead of a single-step decay. Requires a small integer power in WAD (we can do a loop or fixed small max elapsed).

---

## 3. Structural Changes from Our Own Review + Research

From **Sapient-v6-edge-wall-deep-review** and **web** (dynamic fees, volatility/inventory sensitivity, LVR/toxicity):

### 3.1 Dir only when no surge (no overlap)

- **Idea:** Apply **directionality only when ret ≤ adaptiveGate**. When ret > gate, apply **surge only** (no dir on that trade). So dir and surge never both add to the same leg on the same trade.
- **Why:** Frees cap headroom for surge and removes double-penalty; dir is for “moderate” moves, surge for “shock” moves.

### 3.2 Scaled surge by breach size

- **Idea:** surge = SURGE_BASE + SURGE_COEF×(ret − gate), capped (e.g. 15–40 bps). The larger the breach, the larger the surge.
- **Why:** Captures more on the largest moves without overcharging small breaches.

### 3.3 Stronger symmetric tox at high toxEma

- **Idea:** When toxEma > threshold (e.g. 1.5%), add an extra symmetric term (e.g. SYM_HIGH_COEF×(toxEma − threshold)) so the non-vulnerable side isn’t as cheap in high-tox regimes.
- **Why:** Closes the arb gap on the “cheap” side when we’re already very wrong.

### 3.4 Trade-size bump (from TradeInfo)

- **Idea:** tradeRatio = amountY/reserveY (or amountX/reserveX) capped; add K_SIZE×tradeRatio (capped, e.g. 20 bps) to the **side that was just hit** (bid if buy, ask if sell).
- **Why:** We have the data; no new state; directly charges more for larger trades.

### 3.5 Volatility- and inventory-sensitive base (research alignment)

- **Idea:** Base fee already has vol and imbalance; ensure the **response** to volatility is strong enough (research suggests volatility-sensitive spreads mitigate adverse selection). Optionally add a small **inventory-linear** term (e.g. fee ∝ |imbalance|) if not already dominant.
- **Why:** Aligns with “optimal dynamic fees” and “volatility-responsive pricing” from literature; we already have the building blocks, may just need tuning.

---

## 4. Approaches (2–3 Options)

### Approach A — Minimal structural (low risk)

- **Changes:**  
  (1) Dir only when ret ≤ gate (no dir when surge fires).  
  (2) Scaled surge: surge = f(ret − gate) capped.  
  (3) Stronger symmetric tox above toxEma threshold.  
  (4) Trade-size bump on the side just hit (K_SIZE×tradeRatio).
- **New state:** None (or one slot for “prev fee” if we add pImplied later).  
- **Pros:** Addresses cap overlap and size; small code delta; easy to backtest.  
- **Cons:** No dirState, no pImplied, no tail compression; ceiling may remain.

### Approach B — Adopt selected YQ-style concepts (medium risk)

- **Changes:** Everything in A, plus:  
  (5) **pImplied** for pHat update and ret (store prev bid/ask fee; compute pImplied from feeUsed).  
  (6) **dirState**: one slot, centered at WAD, updated by direction×size, decay by elapsed. Use dirState to skew bid/ask in addition to spot vs pHat.  
  (7) **Trade-aligned toxicity boost**: add K_TRADE_TOX×tradeRatio to the side just hit when trade was “toxic” (buy & spot≥pHat or sell & spot<pHat).  
  (8) **Sigma×tox** and **cubic tox** term (vulnerable or symmetric).
- **New state:** prevBidFee, prevAskFee (or reuse fee output slots), dirState, and possibly stepTradeCount + lastTs if not already present.  
- **Pros:** Better price signal (pImplied), flow-direction memory (dirState), size-aware toxicity (trade boost, cubic, sigma×tox).  
- **Cons:** More slots and logic; need to avoid overfitting and keep gas/sim behavior predictable.

### Approach C — Full concept integration (higher risk)

- **Changes:** Everything in B, plus:  
  (9) **actEma / sizeHat / lambdaHat** and a **flow-size** base term.  
  (10) **Stale-direction with attract**: add to vulnerable side, subtract (with attract fraction) from the other.  
  (11) **Tail compression** (knee + slope) per side instead of or in addition to hard cap.  
  (12) **Time-step–consistent decay** (decay^elapsed) for toxEma and dirState.
- **New state:** actEma, sizeHat, lambdaHat, stepTradeCount, lastTs, dirState, pHat, sigmaHat, toxEma, prev fees.  
- **Pros:** Thematically closest to “best ideas” from YQ and research; maximum structural richness.  
- **Cons:** Many parameters and slots; harder to tune and debug; risk of regressions.

---

## 5. Recommendation

- **First implementation:** **Approach A** in a new **VIAFStrategyV7** (per versioning rule).  
  - Implement: dir only when ret ≤ gate; scaled surge; stronger sym-tox at high tox; trade-size bump.  
  - Run: `amm-match run contracts/src/VIAFStrategyV7.sol --simulations 1000` and compare edge to 374 and cap-hit rate.

- **If A crosses 400:** Keep V7 as the new baseline; optionally add **one** of pImplied or dirState (Approach B) in a V8 and re-test.

- **If A stays below 400:** Move to **Approach B**: add pImplied, dirState, trade-aligned boost, sigma×tox, and cubic tox. Re-run sims and tune.

- **Approach C** is for a later iteration (e.g. V8/V9) once A or B is stable and we have capacity to add flow-size, attract discount, tail compression, and elapsed decay without overwhelming the codebase.

---

## 6. Summary Table: Structural Levers

| Lever | Source | Effect |
|-------|--------|--------|
| Dir only when ret ≤ gate | V6 review | Frees cap for surge; no overlap |
| Scaled surge (ret − gate) | V6 review | More fee on large breaches |
| Stronger sym-tox at high tox | V6 review | Less cheap non-vulnerable side |
| Trade-size bump | V6 review + TradeInfo | Charge more for larger trades |
| pImplied for pHat/ret | YQ concept | Cleaner price signal; less lag |
| dirState (flow direction) | YQ concept | Persistent who’s-hitting-us memory |
| actEma / sizeHat / lambdaHat | YQ concept | Flow and activity in base fee |
| Cubic tox + sigma×tox | YQ concept | Sharper fee when very wrong + volatile |
| Stale + attract discount | YQ concept | Explicit attract side |
| Trade-aligned tox boost | YQ concept | Size-scaled boost on toxic side |
| Tail compression | YQ concept | Smooth cap; asymmetric slopes |
| Decay^elapsed | YQ concept | Time-consistent decay |

---

## Next Step

Which do you prefer for the **next** step?

1. **Implement Approach A** in `VIAFStrategyV7.sol` (dir only when ret≤gate, scaled surge, sym-tox high, size bump) and document in `/docs`.  
2. **Deep-dive one concept** (e.g. pImplied or dirState) with formulas and slot layout before coding.  
3. **Adjust the recommendation** (e.g. skip A and go straight to B, or add/remove a lever).

Once you pick, we can either write the design into `docs/plans/2025-02-09-V7-design.md` and then implement, or go straight to the V7 contract.
