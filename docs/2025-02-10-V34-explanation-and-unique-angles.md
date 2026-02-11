# V34 Strategy Explained + Unique Angles to Compete

**Context:** V34 (YQ baseline) scores **524.63** edge — in the leaderboard band. This doc (1) explains what the strategy does in one place, and (2) proposes **unique angles** so we can differentiate and compete instead of copying YQ.

---

## Part 1 — What V34 (YQ) Does, in Short

**Goal:** Set **bid fee** and **ask fee** (the next trade) using only reserves, the last trade, and a small **memory** (11 slots). No oracle; we infer “fair price,” “how wrong we are,” and “who’s been hitting us” from that.

**Flow each trade:**

1. **New step?** (`timestamp > lastTs`)  
   Decay direction, activity, size, toxicity by **elapsed time**; update **lambda** (trades-per-step) from last step’s count; reset step trade count.

2. **Fair price (pHat)**  
   From the last trade we compute **pImplied** (price after fee). If the move is small vs our **adaptive gate** (volatility-based), we blend pImplied into pHat. **First trade in the step** uses a faster blend and updates **sigma** (volatility); later trades in the same step use a slower blend and don’t update sigma.

3. **Toxicity**  
   How wrong is our pool price vs pHat? `tox = |spot - pHat|/pHat` (capped). We keep a fast EMA (**toxEma**) and use it as the main “we’re wrong” signal.

4. **Activity**  
   When trade size is above a threshold: update **dirState** (buy vs sell pressure), **actEma** (activity level), **sizeHat** (typical trade size). **lambdaHat** = smoothed trades-per-step. **flowSize** = lambdaHat × sizeHat.

5. **Fee build-up**  
   - **Base:** 3 bps + sigma + lambda + flowSize (no imbalance, no extra vol term).  
   - **Mid:** base + tox (linear + quad + cubic) + actEma + sigma×tox.  
   - **Skew:** from **dirState** — protect the side that’s been hit (higher fee), attract the other (lower).  
   - **Stale/attract:** if spot ≥ pHat, add fee to bid and subtract from ask; else add to ask, subtract from bid (by tox).  
   - **Trade-aligned boost:** if this trade was “toxic” (e.g. buy when spot ≥ pHat), add a boost to that side for the *next* trade.  
   - **Tail:** above 5 bps, compress with slope 0.93 (protect) / 0.955 (attract), then clamp to 10%.

**In one sentence:** Low base (3 bps), build fee from **activity** (λ, flowSize, actEma) and **toxicity** (linear/quad/cubic + σ×tox), use **pImplied** and **first-in-step** for a robust fair price, **dirState** for who to protect, **stale/attract** to widen the vulnerable side and discount the other, **tail compression** so fees don’t explode.

---

## Part 2 — Unique Angles (Think Outside the Box)

YQ and the leaderboard sit in a narrow band (~524–526). To **compete with a distinct angle**, we need ideas that (a) use information or structure YQ doesn’t, or (b) combine the same inputs in a different way, and (c) can be tested one at a time on top of V34.

Below are concrete angles; each can be tried as **one change** (e.g. V35, V36) and reverted if edge drops.

---

### 2.1 Reserve imbalance as a second “pressure” signal

**YQ:** Uses only **dirState** (flow direction) for protect/attract.  
**Idea:** Reserve imbalance (e.g. reserveY vs reserveX) tells us “who is long/short the pool.” Add a **small** imbalance term that *reinforces* or *softens* dirState — e.g. when imbalance and dirState agree (both say “sell pressure”), protect that side more; when they disagree, use a blend so we don’t overreact to flow alone.  
**Why it might help:** Sim might have regimes where flow direction and inventory get misaligned; a second signal could reduce mis-assignment.  
**Risk:** Double-counting direction; keep the imbalance coef small and test.

---

### 2.2 Regime: calm vs stressed

**YQ:** One pipeline; same formula in all regimes.  
**Idea:** Classify **calm** (low sigma, low tox) vs **stressed** (high sigma and/or high tox). In calm: slightly **lower** fee on the attract side (invite rebalancing); in stressed: **wider** spread (higher protect, same or steeper tail).  
**Why it might help:** In calm, we can afford to be more attractive; in stressed, we want to get paid for risk.  
**Risk:** Wrong thresholds or wrong sim regime distribution could hurt; need to tune.

---

### 2.3 Gate or alpha depends on trade size

**YQ:** Adaptive gate (sigma-based) and first-in-step alpha are size-agnostic.  
**Idea:** **Large** trades move pHat more (or less) than small ones. Options: (a) wider gate when trade size is large (don’t trust one big move for pHat), or (b) only update sigma when trade size is above a threshold (treat small trades as noise).  
**Why it might help:** One large toxic trade could be distorting pHat/sigma; size-dependent update could make the fair price more stable.  
**Risk:** Might under-react to real information in large trades.

---

### 2.4 “Time since last trade” (silence) as risk

**YQ:** Decay when we see a new step; we don’t explicitly treat “first trade after long silence” differently.  
**Idea:** When **elapsed** is large (long time with no trades), the *first* trade in the new step might be more likely arb. Add a **one-off** fee bump for that first trade (e.g. scale bid/ask by 1 + small coef×min(elapsed, cap)).  
**Why it might help:** After silence, our quote is staler; arbs might hit us first.  
**Risk:** Might overcharge retail that trades after a quiet period.

---

### 2.5 Toxic flow run (recent history of “wrong” trades)

**YQ:** We have trade-aligned boost for the *current* trade’s toxicity.  
**Idea:** Keep a short memory: “how many of the last N trades were toxic?” (e.g. buy above pHat / sell below). If **recent flow was mostly toxic**, add a fee boost (we’re in a run of adverse flow).  
**Why it might help:** One toxic trade gets a boost; a *sequence* of toxic trades might deserve a higher, persistent premium.  
**Risk:** Slots: need a compact encoding (e.g. running sum or tiny bitmask); might overfit.

---

### 2.6 Asymmetric decay by toxicity

**YQ:** dirState (and other state) decays by elapsed only; decay factors are fixed.  
**Idea:** When **tox is high**, decay **dirState** faster toward neutral (we might be wrong about who’s hitting us). So in stressed regimes we don’t carry stale direction as long.  
**Why it might help:** Reduces stubborn wrong-side protection when the world has shifted.  
**Risk:** Could lose useful direction signal in volatile but one-sided flow.

---

### 2.7 Two “speeds” of fair price (trend vs micro)

**YQ:** One pHat.  
**Idea:** Maintain **pHat_fast** (current) and **pHat_slow** (slower EMA). When they **diverge** (e.g. |pHat_fast - pHat_slow|/pHat_slow > threshold), we’re in a regime change → raise fee (or widen spread). Use pHat_fast for gate/tox, use the gap for an extra term.  
**Why it might help:** Regime changes are when we’re most at risk; the gap is a clean signal.  
**Risk:** One more slot and more logic; might be noisy.

---

### 2.8 Size-dependent attract discount

**YQ:** Stale/attract: subtract a fixed fraction of staleShift from the other side.  
**Idea:** Make the **attract** side discount **increase with trade size** (or with sizeHat): when the *next* trade is large and on the attract side, we discount more (we want that flow). So we compete for large rebalancing flow.  
**Why it might help:** Retail or rebalancers might be size-sensitive; we get more flow when we need it.  
**Risk:** Could be gamed if “large” is defined on current trade; might need to use sizeHat or similar.

---

### 2.9 Asymmetric cap (protect side can go higher)

**YQ:** Same MAX_FEE (10%) for both sides after tail.  
**Idea:** Allow **protect** side to have a higher effective cap (e.g. 12%) and **attract** side a lower cap (e.g. 8%) so we can squeeze more from the side we’re protecting while staying clearly cheaper on the attract side.  
**Why it might help:** More fee from arbs, clearer discount for desired flow.  
**Risk:** Harness might enforce a single MAX_FEE; need to check.

---

### 2.10 Variance of ret (stability of moves)

**YQ:** Sigma = smoothed |ret| (magnitude).  
**Idea:** Also track **variance** of ret over recent steps (e.g. E[ret²] - E[ret]² in a sliding window or EMA). When variance is **high**, moves are inconsistent → more uncertainty → add a fee term.  
**Why it might help:** Volatility of volatility might indicate regime shifts or unstable conditions.  
**Risk:** Needs extra state and might be redundant with sigma.

---

## Part 3 — Suggested order to try

1. **Low-risk, same structure:** Tune YQ constants (base, coefs, knee, slopes, decay) in small steps; see if we can nudge above 524.63 without any new idea.  
2. **One structural experiment:** Pick **one** of 2.1 (imbalance), 2.2 (calm/stressed), 2.4 (silence), or 2.6 (tox-dependent decay). Implement in V35, run 1000 sims, compare to V34.  
3. **If one wins:** Keep it and try a second idea (e.g. V36). If one loses, revert and try another.  
4. **Document each:** Short changelog per version; record edge and what changed.

---

## References

- [SapientStrategyV34.sol](../amm-challenge/contracts/src/SapientStrategyV34.sol) — current baseline (524.63).
- [2025-02-10-Sapient-V34-YQ-baseline-changelog.md](2025-02-10-Sapient-V34-YQ-baseline-changelog.md).
- [2025-02-10-Sapient-V23-vs-YQ-structural-comparison.md](2025-02-10-Sapient-V23-vs-YQ-structural-comparison.md).
- [AMM-fee-strategy-toddler-guide.md](AMM-fee-strategy-toddler-guide.md) — concept glossary.
