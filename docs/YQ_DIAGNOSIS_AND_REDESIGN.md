# YQStrategy: Deep Diagnosis & Redesign for AMM Challenge

**Strategy under review:** YQ (`strat/YQStrategy.sol`) — **current winning strategy (500+ edge)**  
**Platform:** afterSwap-only API; no fair price in `TradeInfo`; fee clamp [0, MAX_FEE] with MAX_FEE = 10% (WAD/10).

---

## Contract & Strategy Summary (In Depth)

### What the contract does

YQ maintains **11 slots** of state and returns **(bidFee, askFee)** after each trade. The fee is applied to the **next** trade (same structural lag as any afterSwap strategy).

**State (slots 0–10):**

| Slot | Meaning | Typical scale |
|------|---------|----------------|
| 0 | bid fee (WAD) | 3 bps–10% |
| 1 | ask fee (WAD) | 3 bps–10% |
| 2 | last timestamp (step index) | integer |
| 3 | dirState | [0, 2×WAD], WAD = neutral |
| 4 | actEma | trade-ratio activity (0–1) |
| 5 | pHat | internal “fair price” proxy (Y/X) |
| 6 | sigmaHat | volatility proxy (realized |Δp|/p) |
| 7 | lambdaHat | trades-per-step estimate |
| 8 | sizeHat | typical trade size vs reserve (0–1) |
| 9 | toxEma | toxicity (|spot − pHat|/pHat) |
| 10 | stepTradeCount | trades in current step (raw) |

**High-level flow in `afterSwap`:**

1. **Step boundary:** If `trade.timestamp > lastTs`, treat as new step: decay dirState, actEma, sizeHat, toxEma by elapsed time; update lambdaHat from stepTradeCount/elapsed; reset stepTradeCount.
2. **pHat (fair-price proxy):** From current reserves, spot = reserveY/reserveX. From the fee that was just used, infer implied price: pImplied = spot·γ (buy) or spot/γ (sell) with γ = 1 − fee. ret = |pImplied − pHat|/pHat. Only update pHat if ret ≤ adaptive gate (max(10·sigmaHat, 0.03)). Update sigmaHat on first-in-step using ret (capped at 10%).
3. **Direction / activity / size:** tradeRatio = amountY/reserveY (capped 20%). If tradeRatio > ~20 bps: push direction (buy → dirState up, sell → dirState down); blend actEma and sizeHat with very slow blend (0.985, 0.818) so they react slowly.
4. **Toxicity:** tox = |spot − pHat|/pHat (capped 20%); toxEma uses very fast blend (0.051 decay, 0.949 new) so toxicity tracks current mispricing quickly.
5. **Fee construction:** Base from sigma, lambda, flowSize (λ×size); add linear + quadratic + cubic toxicity, activity term, sigma×tox; then directional skew (dirDev, dirDev×tox); then stale-direction (spot vs pHat) and trade-aligned toxicity boost; finally asymmetric tail compression and clampFee.

So the **strategy** is: infer a fair price (pHat) from implied price with an adaptive gate, estimate volatility (sigmaHat), arrival rate (lambdaHat), and trade size (sizeHat), measure toxicity (toxEma) and direction (dirState), and set **asymmetric bid/ask fees** that rise with volatility, toxicity (with strong convexity), activity, and direction, with extra protection on the “stale” side and on trade-aligned toxic flow. Tail compression (0.93 protect, 0.955 attract) keeps the attract side slightly cheaper.

---

## 1. Why We Lose (When We Do)

### 1.1 Structural lag (fee applies to next trade)

- Fees are computed in `afterSwap` and apply to the **next** trade. The trade we just saw paid the **previous** fee.
- So we **never** charge the current trade; we only shape the next. Any reaction to toxicity, size, or direction is one step late for the trade that just happened.
- Consequence: the first arb in a step (or after a quiet period) often hits at a fee that was decayed or not yet elevated. We raise fees **after** the arb.

### 1.2 pHat is backward-looking and gated

- pHat is updated only when ret = |pImplied − pHat|/pHat ≤ gate (max(10·sigmaHat, 0.03)). So after a large move, ret can exceed the gate and we **don’t** update pHat. pHat then lags the true fair price.
- We use **first-in-step** α = 0.26 and **retail** α = 0.05 for blending pImplied into pHat. So pHat moves slowly, especially when we’re wrong (gate blocks updates). In fast-moving or trending regimes, pHat can stay wrong for several trades → we underestimate toxicity and undercharge.

### 1.3 Toxicity blend is fast; direction/activity/size are slow

- toxEma: TOX_BLEND_DECAY = 0.051 → ~95% weight on new tox. So toxicity reacts quickly to current mispricing.
- dirState: DIR_DECAY = 0.80 per step; push is capped (e.g. tradeRatio×2, max 25%). So direction builds slowly. After a single large arb, we may not flip dirState enough to fully protect the right side next time.
- actEma / sizeHat: ACT_BLEND_DECAY = 0.985, SIZE_BLEND_DECAY = 0.818. So “recent activity” and “recent size” decay slowly and may keep fees elevated **after** the burst, potentially overcharging retail, while the **first** large trade in a burst already happened at the old fee.

### 1.4 Convexity of losses vs fee income

- LP loss from one arb scales with **trade size × mispricing** (roughly linear in size, linear in |spot − fair| before fee). Fee income scales with **fee rate × size**. So for a given mispricing, one large arb can create more loss than many small fees can recoup if the fee on that trade was low.
- YQ uses cubic toxicity (TOX_CUBIC_COEF = 15000 bps) to push fees up sharply when tox is high. That helps **after** we’re already toxic; the arb that created the toxicity already traded at the previous fee. So we still have **timing** convexity: we pay most on the trade that just happened, and we charge the next one.

### 1.5 Step-boundary and lambda

- lambdaHat = trades per step (stepTradeCount / elapsed), blended with 0.99. So in a single step we only get one observation of “trades per step.” If the sim has one trade per step, lambdaHat is driven by 1/elapsed and can be noisy or slow to reflect bursty activity. So “arrival rate” may not be a strong leading indicator.

### 1.6 No fair price → mispricing is inferred

- We have no oracle. Mispricing is only via spot vs pHat. When the gate blocks pHat updates, we underestimate mispricing and thus toxicity. So in regimes where we’re repeatedly wrong (e.g. sustained trend), we can undercharge.

### 1.7 Summary table

| Cause | Effect |
|-------|--------|
| Fee set in afterSwap | Next trade pays; current (often arb) trade already executed at old fee. |
| pHat gate (ret > 10·σ or 3%) | pHat doesn’t update when we’re wrong → tox and fees lag. |
| Slow dirState / actEma / sizeHat | Asymmetry and activity-based fee build slowly; first hit is at old fee. |
| Fast toxEma | Toxicity tracks current mispricing; good for level, still one step late for the trade that caused it. |
| Lambda from step count | Noisy or slow in one-trade-per-step regimes; weak leading signal. |
| Tail compression (0.93/0.955) | Protects side slightly more; small effect vs large mispricing. |

---

## 2. How Traders Exploit Us

### 2.1 Arbitrageur playbook

1. **Observe:** Fair price (e.g. from external market) vs AMM spot. If |spot − fair| > fee, trade. We don’t see fair; we only see spot and pHat. If our pHat is stale (gate blocked update), tox and thus fee are low.
2. **First trade in step / after quiet:** Our fee may have decayed (dirState, actEma, sizeHat decay with elapsed time). Step boundary resets stepTradeCount and updates lambda only from that one step. So the first arb in a new step often gets a fee that hasn’t yet incorporated the new regime.
3. **Size:** We blend sizeHat slowly. A single large arb moves sizeHat only a bit; the **next** fee gets a modest flowSize bump. The large arb already paid the previous fee. So they “get in” at the old fee and we only raise for the next comer.
4. **Direction:** We push dirState by push = min(tradeRatio×2, 25%). So one 20% trade pushes by 25% (capped). If the arb does a 5% trade, push is 10%. So multiple small arbs can move dirState gradually while each pays a fee that hasn’t yet fully reflected the new direction. They can “chip away” at our inventory at fees that lag.

### 2.2 Predictable behavior

- **Stale-direction logic:** We add STALE_DIR_COEF×tox to the side where spot ≥ pHat (bid) or spot < pHat (ask), and subtract STALE_ATTRACT_FRAC×that from the other side. So when spot > pHat we’re “rich in Y” and we raise bid (correct). An arb who can observe reserves and infer our pHat (e.g. from past updates) knows which side we’re making expensive and can still hit if mispricing > fee.
- **Trade-aligned boost:** We add TRADE_TOX_BOOST×tradeRatio to bid (if buy and spot ≥ pHat) or ask (if sell and spot < pHat). So we charge more when the trade that just happened was “toxic” in our direction. Again, that trade already paid the old fee; we’re only raising for the next. No direct exploitation, but it doesn’t deter the current trade.
- **Decay:** When elapsed is large, we decay dirState (0.8^elapsed), actEma, sizeHat, toxEma. So after a few steps with no trade, our fees drift down. An arb who times trades to arrive after a quiet period gets a lower fee. So **predictable decay** is exploitable: hit when steps_since_last_trade is large.

### 2.3 Information asymmetry

- Arb sees **fair price** (in sim or external market). We only have **spot** and **pHat**. When the gate blocks pHat, we are wrong but don’t correct. So they know we’re mispriced; we may not fully reflect it in toxicity and fee.

---

## 3. Failure Modes

### 3.1 Regime: Fast mean-reversion of fair price

- Fair reverts quickly; spot moves only when someone trades. So we’re often mispriced. We update pHat only when ret ≤ gate; after a big move the gate may block. Then we raise tox and fee after the move. Next trade can be in the opposite direction (retail or arb the other way). We may overcharge retail (high fee from last move) and still get arbed when we’re wrong. **Result:** Mixed; can be negative edge if arb captures reversion and we overcharge retail.

### 3.2 Regime: Sustained one-sided drift (trend)

- Fair drifts one way; we get hit repeatedly on one side. pHat may lag (gate, slow α). dirState builds but slowly. We raise the “protect” side (e.g. bid when rich in Y), but the arb has already traded at the previous fee each time. So we’re **one step behind** on every arb. **Result:** Cumulative arb loss can dominate; fee income lags.

### 3.3 Regime: Volatility clustering (burst then calm)

- Burst: several arbs in a few steps. We raise sigmaHat, toxEma, and fees. By then, several arbs have already traded at lower fees. After the burst, we decay (dirState, actEma, sizeHat, toxEma with elapsed). If the next burst comes after many quiet steps, we’ve decayed a lot and the first arb of the new burst gets a low fee. **Result:** We pay in the burst; we don’t recoup enough in calm; we’re vulnerable at the start of the next burst.

### 3.4 Regime: One trade per step

- stepTradeCount is 0 at the start of each step; we get at most one trade per step. So lambdaHat = 1/elapsed when we have one trade, and 0 when we have none. Lambda is then very dependent on elapsed and may not reflect “burstiness” well. flowSize = lambdaHat×sizeHat may be noisy. **Result:** Fee may be less adaptive to true arrival rate.

### 3.5 Tail: Very large single trade

- One 20% (capped tradeRatio) trade: we push dirState by 25% (capped), blend sizeHat and actEma. The **next** fee gets the full effect. The 20% trade paid the **previous** fee. If that fee was e.g. 50 bps and mispricing was 5%, the arb captured ~4.5%. So we still have **one-step lag** on the worst trades.

### 3.6 Structural: All signals backward-looking

- pHat, sigmaHat, toxEma, dirState, actEma, sizeHat are all derived from **past** trades and reserves. We have no order flow or fair price. So we will always be at least one step late in adversarial environments.

---

## 4. Superior Design Ideas

### 4.1 Lead with imbalance, not just direction

- We don’t have fair price, so **reserve imbalance** is the cleanest proxy for “we’re wrong and someone will arb us.” Define e.g. imbalance = |reserveX − reserveY| / (reserveX + reserveY). Make fee **and** asymmetry depend strongly on imbalance, not only on dirState (which is driven by trade direction and decays). Idea: **imbalance floor** — don’t let fee decay below base + f(imbalance), so when we’re very imbalanced we stay defensive.

### 4.2 Imbalance-aware decay

- Decay toward **base + imbalance_floor(imbalance)** instead of toward a fixed base. So when we’re 20% imbalanced we don’t decay back to 3 bps; we decay toward e.g. 30 bps. Reduces “hit after quiet period” exploitation.

### 4.3 Faster reaction on the protect side (first trade in step)

- We already have firstInStep. Use it to apply a **one-step lookahead**: when we’re imbalanced, the next trade is likely an arb on the vulnerable side. So on step boundary (or when firstInStep and imbalanced), **pre-raise** the fee on the side that would rebalance us (e.g. raise bid when rich in Y) by a fixed bump or by a multiple of current tox, so the first trade of the new step doesn’t get the decayed fee. Implementation: e.g. when isNewStep && imbalance > threshold, set a floor for bid or ask from imbalance.

### 4.4 Weaker decay when toxic or imbalanced

- Don’t decay dirState, actEma, sizeHat, toxEma as aggressively when toxEma or imbalance is high. E.g. effective decay = DECAY^(elapsed) × (1 − k×toxEma) so in high-tox we decay slower. Keeps fees elevated when we’re still wrong.

### 4.5 Simplify and reduce overfitting

- Many constants (DIR_COEF, DIR_TOX_COEF, STALE_DIR_COEF, TRADE_TOX_BOOST, tail slopes, cubic coef, etc.) give a lot of knobs. Risk: overfitting to one sim path. Consider: (1) **Single main driver for asymmetry:** imbalance direction (rich in Y → bid high, rich in X → ask high). (2) **One toxicity term:** e.g. keep quadratic or cubic but drop one of linear/quad/cubic to reduce sensitivity to tuning. (3) **Drop or reduce** trade-aligned boost (it only affects next trade and is noisy).

### 4.6 Volatility as regime, not only level

- Use sigmaHat to **classify** regime (e.g. high vol vs low vol). In high vol: higher floor, stronger asymmetry, slower decay. In low vol: closer to base, symmetric. Reduces overreaction to single noisy moves while staying defensive in clearly volatile regimes.

### 4.7 pHat gate relaxation when very wrong

- When ret is very large (e.g. ret > 2×gate), consider **forcing** a partial pHat update (e.g. α larger) so we don’t stay wrong for many steps. Alternative: cap the **number of consecutive steps** where we don’t update pHat; after that, force an update. Reduces sustained lag in trending regimes.

---

## 5. Concrete Formula / Pseudocode

### 5.1 Notation

- spot = reserveY / reserveX  
- imbalance = |reserveX − reserveY| / (reserveX + reserveY)  
- richInY = (reserveY ≥ reserveX)  
- Keep: pHat, sigmaHat, toxEma, dirState, lambdaHat, sizeHat, actEma (or simplified subset).  
- New: imbalance_floor_bps = K_IMB_FLOOR × imbalance (e.g. 50 bps per 0.1 imbalance).  
- Decay target: fee_floor = BASE + imbalance_floor_bps (instead of BASE).  
- On step boundary: if imbalance > IMB_THRESH and richInY: bid_floor += PRE_RAISE_BPS; else if imbalance > IMB_THRESH and !richInY: ask_floor += PRE_RAISE_BPS.

### 5.2 Imbalance-aware floor and decay (add to YQ)

```text
// In afterSwap, after computing fMid and skew / stale / trade boost:

uint256 imb = wdiv(absDiff(trade.reserveX, trade.reserveY), trade.reserveX + trade.reserveY);
uint256 imbFloorBps = wmul(imb, 50 * BPS);   // e.g. 50 bps per 0.1 imb
uint256 feeFloor = BASE_FEE + imbFloorBps;

// When applying decay (on isNewStep): decay bidFee/askFee toward feeFloor, not BASE_FEE.
// I.e. after computing bidFee, askFee:
if (isNewStep && elapsed > 0) {
  // Only decay the part above the floor
  if (bidFee > feeFloor) bidFee = feeFloor + wmul(bidFee - feeFloor, _powWad(DECAY_IMB, elapsed));
  if (askFee > feeFloor) askFee = feeFloor + wmul(askFee - feeFloor, _powWad(DECAY_IMB, elapsed));
}

// Pre-raise on step boundary when imbalanced
if (isNewStep && imb > IMB_THRESH) {
  if (richInY) bidFee = bidFee + PRE_RAISE_BPS;
  else        askFee = askFee + PRE_RAISE_BPS;
}
```

### 5.3 Slower decay when toxic (optional)

```text
// When decaying dirState, actEma, sizeHat, toxEma:
uint256 toxFactor = WAD - wmul(TOX_DECAY_SLOW, toxEma);  // e.g. TOX_DECAY_SLOW = 0.2
uint256 effectiveDirDecay = wmul(DIR_DECAY, toxFactor);
dirState = _decayCentered(dirState, effectiveDirDecay, elapsed);
// Similarly for actEma, sizeHat, toxEma if desired.
```

### 5.4 Suggested constants (tuning required)

- K_IMB_FLOOR: 50–100 bps per 0.1 imbalance (in WAD terms: 0.005–0.01 × imbalance).  
- DECAY_IMB: 0.92–0.96 (decay toward floor).  
- IMB_THRESH: 0.1–0.2 (imbalance above which we pre-raise).  
- PRE_RAISE_BPS: 10–30 bps on the protect side at step boundary.  
- TOX_DECAY_SLOW: 0.1–0.2 so that when toxEma is high, effective decay is slower.

---

## 6. Backtest Blueprint

### 6.1 Core metrics

- **Cumulative edge** (total, retail, arb) — primary.  
- **LP PnL** (if provided).  
- **Fee capture ratio:** (fees collected) / (gross volume) vs (arb loss) / (volume). Target: fee capture covers arb loss.  
- **Drawdowns:** max peak-to-trough cumulative edge; max single-trade loss.  
- **Variance of edge per step** (or per 100 steps).

### 6.2 Conditioning

- **By regime:** low vol vs high vol (e.g. sigmaHat above/below median); trend vs mean-reversion (e.g. autocorrelation of fair price); balanced vs imbalanced (e.g. imbalance above/below 0.2).  
- **By trade type:** retail-only edge, arb-only edge, ratio retail/|arb|.  
- **By step position:** first trade in step vs later in step; steps since last trade (1 vs 2 vs 5+).  
- **By mispricing at trade time:** bin by |spot − fair| (if available in logs); compare fee and edge per bin.

### 6.3 Comparisons

- YQ (current) vs YQ + imbalance floor + pre-raise.  
- YQ vs YQ + slower decay when toxic.  
- YQ vs fixed 30 bps, fixed 100 bps.  
- Sensitivity: PRE_RAISE_BPS (0, 15, 30), IMB_THRESH (0.1, 0.2), DECAY_IMB (0.92, 0.96), K_IMB_FLOOR (50 bps, 100 bps per 0.1 imb).

### 6.4 Red flags

- Arb edge large negative, retail small positive → still being farmed.  
- Fee revenue << |arb loss| → reaction or floor too weak.  
- High variance of edge → overfitting or unstable.  
- Edge drops in “first trade in step” or “after long quiet” → decay/pre-raise not tuned.

---

## 7. If I Had To Win The Competition

### 7.1 Priorities

1. **Keep YQ’s strengths:** pHat + gate (reduces noise), cubic toxicity (strong convexity), directional and stale-direction asymmetry, tail compression. They already give 500+ edge.  
2. **Add imbalance as a first-class driver:** Imbalance floor so we don’t decay to base when imbalanced; optional pre-raise on the protect side at step boundary.  
3. **Decay toward floor, not base:** When we’re imbalanced, decay toward base + f(imbalance), not toward 3 bps. Reduces “arb after quiet” exploitation.  
4. **Optional: slower decay when toxic.** When toxEma is high, decay dirState/actEma/sizeHat/toxEma more slowly so we don’t drop fees right when we’re still wrong.  
5. **Tune in sim:** PRE_RAISE_BPS, IMB_THRESH, K_IMB_FLOOR, DECAY_IMB on the provided (or representative) paths. Condition metrics on regime and step position.  
6. **Simplify only if overfitting appears:** If edge is unstable across paths, consider reducing free parameters (e.g. one toxicity term, or drop trade-aligned boost) and rely more on imbalance + vol regime.

### 7.2 One paragraph

YQ wins by combining an internal fair-price proxy (pHat) with a gate, fast toxicity (toxEma), slow direction/activity/size, and strong convex fee (linear + quad + cubic tox, directional and stale-direction asymmetry, tail compression). We lose when we’re one step behind (fee applies to next trade), when pHat lags (gate blocks update), and when we decay too much after quiet steps so the first arb of the next burst gets a low fee. To improve: (1) add **imbalance-based fee floor** and **decay toward that floor**; (2) **pre-raise** the protect side at step boundary when imbalanced; (3) optionally **slow decay when toxic**; (4) keep the rest of YQ and tune new constants in sim. Validate with cumulative edge (total, retail, arb), fee capture vs arb loss, and regime- and step-position-conditioned metrics.

---

*Assumptions: fee applies to the next trade; TradeInfo has no fair price; MAX_FEE = 10% (no 100 bps cap). If the simulator uses different step semantics or provides fair price, the same ideas apply and some (e.g. pre-raise) can be refined.*
