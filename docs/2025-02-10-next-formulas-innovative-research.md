# Next Formulas & Innovative Strategy Research

**Purpose:** Think outside the box — new formula directions, research-backed ideas, and **on-chain adaptive/ML-style** strategies that fit our constraints. We have **32 storage slots** (V34 uses 11 → **21 free**), no oracle, and per-trade feedback (trade size, side, reserves, our previous fee).

**Baseline:** V34 = 524.63. Many structural tweaks tied or regressed. Goal: break through with a different *kind* of strategy.

---

## 1. What the research suggests (critical summary)

### 1.1 Bandit market makers (Della Penna & Reid, arXiv:1112.0076)

- **Idea:** Combine cost-function AMMs with **bandit algorithms** to get **regret guarantees** vs best fee strategy in hindsight.
- **No oracle:** Bandit learns from observed outcomes (e.g. profit per trade).
- **On-chain angle:** We can’t run a full bandit *across* simulations (state resets each run). We **can** run a bandit **within** a single simulation: each trade we get an implicit “reward” (fee we just collected). So we maintain **K “arms”** (e.g. fee multipliers or fee profiles) and use **running average reward** per arm; we choose the next fee level with **ε-greedy** or **UCB** (optimistic initial values + count). With 32 slots we can afford **4–8 arms** (e.g. 2 slots per arm: running sum of reward, count) plus base state.

### 1.2 ZeroSwap (arXiv:2310.09413) — model-free, no oracle

- **Idea:** Data-driven market making that **estimates external price from order flow** and adapts; “zero-profit condition” balances loss to informed vs gain from uninformed.
- **No price oracle, no loss oracle.** Tracks external price via Bayesian-style updates from trades.
- **Our angle:** We already have **pHat** (fair price estimate) and **tox** (|spot − pHat|). ZeroSwap’s “adapt to trader behavior” is similar to our tox + dirState + stale/attract. The **new** idea: explicitly maintain **two running averages** — “reward when we looked toxic” vs “reward when we looked calm” — and **nudge one coefficient** (e.g. TOX_COEF) so we balance (e.g. shrink tox response when we’re overcharging in calm regimes). That’s a **light self-tuning** using 2–4 extra slots.

### 1.3 Exponential weights (Hedge) over fee “experts”

- **Idea:** Maintain **N “experts”** (e.g. N fee formulas or N fee multipliers). Each trade we **sample** an expert (or use weighted blend); we observe **reward** = fee collected; we update **weights** multiplicatively: `w_i := w_i * exp(-η * loss_i)` then renormalize.
- **On-chain:** N = 4 or 8. Store weights in slots (e.g. slots[11..14] for 4 experts). **Reward proxy:** fee collected last trade = `prevFee * notional` (we have prevBidFee/prevAskFee, isBuy, amountX/amountY). So we have a **loss** = −reward (or 1 − normalized_reward). Learning rate η fixed (constant). No need for complex math — just multiply weight by (WAD − η * loss) in WAD space and renormalize.
- **Blend:** Next fee = Σ (weight_i * fee_i) / Σ weight_i. So we compute 4 fees (e.g. same formula with 4 different BASE_FEE or TOX_COEF), blend by weights, return that fee; after trade, update weights from reward.

### 1.4 Asymmetric fee mimicking price direction (2024 fees study)

- **Idea:** “Dynamic fees that mimic **price directionality** through **asymmetric** fee choices” help mitigate toxic flow.
- **Our angle:** We already have bid ≠ ask (dirState, stale/attract). Go further: **when spot just moved up (ret > 0), charge more on the ask** (we’re behind); **when spot moved down, charge more on the bid**. So a **momentum-like** term: e.g. last return sign × asymmetric bump. We have `pImplied` and `pHat` from last trade so we can store **lastRetSign** (1 slot) and add a small **momentum fee** term that widens the side we’re lagging. One slot, one constant.

### 1.5 Regime switching with multiple “speeds” (use the 32 slots)

- **Idea:** We tried **one** sigma and **one** pHat_slow. With 21 free slots we can have:
  - **Sigma fast / sigma slow** (vol regime) — 1 extra slot.
  - **Lambda fast / lambda slow** (activity regime) — 1 extra slot.
  - **Multiple EMAs of tox** (e.g. tox_fast, tox_slow, tox_mid) to detect “tox spike” vs “baseline tox” — 2 extra slots.
  - **Short history of “fee that was used” and “outcome”** — e.g. last 4 trades: (fee_used, notional) to compute rolling “fee yield” and compare to a target; then nudge BASE_FEE or one coef up/down. That’s 4–8 slots for a tiny **gradient-free self-tuning** (e.g. if last 4 trades’ avg fee yield < target, bump BASE_FEE slightly; if > target, reduce).

### 1.6 Thompson sampling / UCB over discrete fee levels

- **Idea:** **K discrete fee levels** (e.g. 5 levels: 20 bps, 30 bps, 50 bps, 80 bps, 120 bps as “base” before tox/skew). Each trade we **choose** one level (e.g. by UCB: pick arm that maximizes `avg_reward + c*sqrt(ln T / n_i)`). We store for each arm: `sum_reward_i`, `count_i`. After trade we add reward to the arm we used.
- **On-chain:** K = 4 or 8. Slots: 2K for (sum, count) or 2K for (mean, count). Total 8–16 slots. Rest of fee = chosen base + same tox/skew/tail as V34. This is a **bandit over base fee level** inside the same formula.

---

## 2. Critical constraints (what we can and can’t do)

| Constraint | Implication |
|------------|-------------|
| **No oracle** | No external price, no volatility feed. We only have reserves, last trade, timestamp, and our own state. |
| **State resets each simulation** | We cannot learn *across* 1000 runs. Any “learning” must be **online within a single run** (one simulation = many trades). |
| **Per-trade info** | We have: isBuy, amountX, amountY, reserveX, reserveY, timestamp. We know **which fee was used** (prevBidFee or prevAskFee). So **reward proxy** = fee collected ≈ `wmul(prevFee, notional)` (e.g. in Y: amountY * prevFee in WAD). |
| **32 slots** | V34 uses 11. We have **21 free slots** for new state: multiple EMAs, bandit arms (sum + count per arm), expert weights, or a short history buffer. |
| **Gas / stack** | No change to Foundry config; keep logic in helpers to avoid stack-too-deep. |
| **One number per run** | The harness returns a single **Edge** over 1000 sims. So we can’t see per-trade reward in the harness; we *can* use a proxy inside the contract to drive bandit/EW. |

---

## 3. Innovative directions (prioritized)

### 3.1 **Bandit over fee multipliers (recommended first)**

- **Design:** K = 4 “fee multiplier” arms: e.g. 0.85, 1.0, 1.15, 1.3. Compute V34-style fMid and skew; then **final fee = clamp(fee × multiplier[arm])**. Choose arm by **ε-greedy**: with probability ε pick random arm; else pick arm with highest **running average reward**. Reward = `wmul(prevFee, amountY)` (or amountX) for the trade that just happened. Store: slots 11–14 = sum_reward per arm, slots 15–18 = count per arm (or pack 4 arms in 8 slots: 2 slots per arm = sum + count). After each trade: update sum and count for the arm we used; then choose next arm.
- **Why it could work:** The sim may have regimes where slightly higher or lower fees win; bandit explores and exploits within a run. No new “formula,” just a wrapper that scales the output and learns which scale is best.
- **Risk:** ε and initial values matter; wrong choice can regress. Start with ε small (e.g. 5%) and 4 arms.

### 3.2 **Exponential weights over 4 “experts” (Hedge)**

- **Design:** Four “experts” = same V34 formula with 4 different **BASE_FEE** (e.g. 2, 3, 4, 5 bps). Each trade compute 4 fees; blend by weights: `fee = Σ w_i * fee_i / Σ w_i`. Return blended fee. Reward = fee collected (from the fee we actually quoted last time — we used blended fee, so reward = wmul(prevBlendedFee, notional)). Loss = −reward (or max_reward − reward). Update: `w_i *= exp(-η * loss_i)`; we only have one blended outcome so we use **importance weighting** or assign the observed reward to all experts and use loss = −reward for each, then update with a single reward (simplified: all experts get same feedback; then w_i *= exp(-η * (1 - reward_normalized))). Simpler variant: **each trade we pick one expert at random with probability proportional to weight**, use that expert’s fee; update only that expert’s weight. Then we need 4 slots for weights (slots 11–14).
- **Why it could work:** Hedge has strong regret bounds; in practice it can adapt to the best BASE_FEE within a run.
- **Risk:** Tuning η and reward scale; possible stack depth if we compute 4 full fees.

### 3.3 **Momentum / last-move asymmetric fee (no bandit)**

- **Design:** Store **lastRetSign** (or last return in WAD) in one slot. After updating pHat we have ret = (pImplied − pHat)/pHat; set lastRetSign = +1 if ret > 0, −1 if ret < 0 (or store ret capped). Fee build: **if lastRetSign > 0** (price moved up), add small **MOMENTUM_COEF** to ask (we’re behind on ask); **if lastRetSign < 0**, add to bid. So we “chase” the last move asymmetrically. One slot, one or two constants. No ML.
- **Why it could work:** 2024 study suggests asymmetric fees that mimic direction help with toxic flow; we’re adding a direct “last move” term.
- **Risk:** Can overreact to noise; keep coef small.

### 3.4 **Dual sigma (vol regime) + dual lambda (activity regime)**

- **Design:** slots[11] = sigma_slow, slots[12] = lambda_slow. Fee bump when **sigma/sigma_slow > 1.1** (vol regime); fee bump or cut when **lambda/lambda_slow > 1.2** (activity regime). Two slots, two small additive terms. Combines “two-speed vol” and “two-speed activity” from the alternative-formulas doc.
- **Why it could work:** More regime information without bandit; uses 2 of 21 free slots.
- **Risk:** Thresholds might not match sim; try mild coefs first.

### 3.5 **Self-tuning TOX_COEF from reward (light)**

- **Design:** Maintain **reward_high_tox** (ema of fee collected when toxEma was above threshold) and **reward_low_tox** (ema when toxEma below). If reward_high_tox < reward_low_tox we’re overcharging in high-tox regimes → reduce TOX_COEF slightly (e.g. multiply by 0.99); else increase slightly. Store 2 slots (reward_high_tox, reward_low_tox) and maybe 1 slot for “current TOX_COEF” (scaled by WAD) that we update slowly. So we **adapt the toxicity sensitivity** within a run from observed fee collection.
- **Why it could work:** ZeroSwap-style “balance” between regimes; we use data to nudge one key coef.
- **Risk:** Slow to converge; might oscillate. Use very slow adaptation.

### 3.6 **Short history of (fee_used, notional) for gradient-free tuning**

- **Design:** Store last 4 “fee_used” and “notional” (e.g. 4 slots for fee_used, 4 for notional, or pack). Compute rolling **avg_fee_yield** = sum(fee_used * notional) / sum(notional). Compare to a **target** (e.g. 50 bps). If avg_fee_yield < target, **bump BASE_FEE** by 1 bps (capped); if above target, reduce. So we have a **discrete integrator** that moves BASE_FEE toward a target yield. Uses ~8 slots for history + 1 for “current BASE_FEE offset” (or we keep BASE_FEE constant and add an offset that we adapt). 
- **Why it could work:** Direct feedback: “we’re under-earning → raise base; over-earning → lower base.”
- **Risk:** Target is arbitrary; might chase noise. Use long averaging and small steps.

---

## 4. ML in our setting: what’s actually possible

- **No training across runs:** Each simulation starts fresh. So no “neural network trained on 1000 sims.”
- **Online learning within one run:** We get a **reward proxy** every trade (fee collected). We can:
  - **Multi-armed bandit:** Choose among K fee levels or K multipliers; update running average reward per arm; use ε-greedy or UCB. Implementable in Solidity with K×2 slots.
  - **Exponential weights (Hedge):** Maintain weights over N experts; each trade get reward; update weights multiplicatively. Implementable with N slots for weights; we need to either blend fees (compute N fees) or sample one expert (compute 1 fee, update one weight). Sampling is cheaper (stack depth).
  - **Simple gradient-free adaptation:** Two EMAs of reward (e.g. “when tox high” vs “when tox low”); nudge one coefficient. Implementable with 2–3 slots.
- **“ML” = any rule that uses observed reward to change behavior.** That’s bandit or Hedge in our context. No deep learning, no backprop — just arithmetic and comparisons.

---

## 5. Suggested order to try

| Priority | Idea | Slots added | Type | Risk | Notes |
|----------|------|-------------|------|------|-------|
| 1 | **Bandit over 4 fee multipliers** (0.85, 1.0, 1.15, 1.3) | 8 (4× sum, 4× count) | On-chain bandit | Medium | **V46:** [changelog](2025-02-10-Sapient-V46-bandit-fee-multipliers-changelog.md) |
| 2 | **Momentum asymmetric fee** (lastRetSign → bump ask or bid) | 1 | Formula | Low | **V47:** [changelog](2025-02-10-Sapient-V47-momentum-asymmetric-fee-changelog.md) |
| 3 | **Dual sigma + dual lambda** (vol + activity regime) | 2 | Formula | Low | **V48:** [changelog](2025-02-10-Sapient-V48-dual-sigma-lambda-changelog.md) |
| 4 | **Hedge over 4 BASE_FEE experts** (sample one per trade, update weight) | 4 | On-chain EW | Medium | |
| 5 | **Self-tuning TOX_COEF** (reward_high_tox vs reward_low_tox) | 2–3 | Light adaptation | Medium | |
| 6 | **Rolling fee-yield target** (nudge BASE_FEE from last 4 trades) | ~9 | Gradient-free tuning | Higher | |

---

## 6. References

- Bandit market makers: Della Penna & Reid, [arXiv:1112.0076](https://arxiv.org/abs/1112.0076)
- ZeroSwap (model-free, no oracle): [arXiv:2310.09413](https://arxiv.org/abs/2310.09413)
- Exponential weights / Hedge: standard online learning (e.g. Freund & Schapire)
- “Fees in AMMs: A quantitative study” (2024) — asymmetric fee, directionality
- Optimal dynamic fees (Baggiani et al.): linear in inventory, two regimes — [arXiv:2506.02869](https://arxiv.org/html/2506.02869v1)
- Our 32-slot base: [AMMStrategyBase.sol](../amm-challenge/contracts/src/AMMStrategyBase.sol) — `uint256[32] public slots`

---

## 7. Next step

**P1** = V46, **P2** = V47, **P3** = V48. Run `amm-match run contracts/src/SapientStrategyV48.sol --simulations 1000` and compare to 524.63. See [V46](2025-02-10-Sapient-V46-bandit-fee-multipliers-changelog.md), [V47](2025-02-10-Sapient-V47-momentum-asymmetric-fee-changelog.md), [V48](2025-02-10-Sapient-V48-dual-sigma-lambda-changelog.md) changelogs.
