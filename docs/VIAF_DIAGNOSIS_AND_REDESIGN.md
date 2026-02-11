# VIAF Strategy: Loss Diagnosis & Redesign

**Strategy under review:** VIAF v2 (Volatility + Imbalance Adaptive Fees) in `strat/VIAFStrategy.sol`  
**Simulation evidence:** Cumulative edge ≈ -8,207 (retail +7.26, arb -8,214.64). Strategy spot 1.096 Y/X vs fair 1.0 → ~9.6% mispricing; fees in sim 749 bps (if from another build) or capped 100 bps in code.

---

## 1. Why We Lose

### 1.1 Structural lag (fee timing)

- **Fees are set in `afterSwap`.** The fee returned is applied to the **next** trade. The trade we just saw was executed at the **previous** fee.
- So we are **always one trade behind**: by the time we raise fees in response to an arb, that arb has already traded at the old (lower) fee. We never charge the exploiter; we only charge the next comer.
- Consequence: volatility and imbalance react to **realized** damage, not to **incoming** flow. We are backward-looking by design.

### 1.2 No fair price → no mispricing signal

- `TradeInfo` has `reserveX`, `reserveY`, `amountX`, `amountY`, `isBuy`, `timestamp`. There is **no oracle/fair price**.
- We can compute only **spot** = reserveY/reserveX. We cannot compute **mispricing** = spot − fair. So we cannot directly say “we’re 9.6% rich in Y, spike the bid fee.”
- Imbalance (|reserveX − reserveY| / (reserveX + reserveY)) is a **proxy** for mispricing only when the pool is supposed to be balanced at fair = 1. When fair moves, the same reserves imply different mispricing. We are inferring “who will arb next” from reserves alone, without knowing where the market is.

### 1.3 Volatility is the arb’s footprint, not a predictor

- Volatility is EWMA of **realized** price change: `newVol = α × |Δprice|/lastPrice + (1−α) × oldVol`.
- After an arb, price has just moved → we get a high `priceChange` → we raise vol and thus fees. So we raise fees **because** an arb already traded. The next trade might be retail (we overcharge) or another arb (we’re still mispriced). We are not using vol to **predict** arb; we use it to **react** to past moves.
- In regimes where arb is frequent, vol stays high and we keep fees high, but we’ve already given away edge on each past arb. Convexity: **losses scale with trade size and mispricing; fee income scales with fee rate.** Once we’re 9.6% off, a single arb can do more damage than many steps of 30–100 bps fees can recoup.

### 1.4 Cap and asymmetry are too weak vs large mispricing

- Code caps at **MAX_FEE_CAP = 100 bps**. If the simulator allows higher (e.g. 749 bps in the screenshot), that may be another strategy. For VIAF as written, we **cannot** go above 100 bps.
- Arbitrage is profitable when **|spot − fair| > fee**. At 9.6% mispricing, even 100 bps doesn’t deter; the arb captures ~9.5% after fee. So the cap prevents us from ever pricing risk when we’re badly wrong.
- Asymmetry (raise bid when rich in Y, raise ask when rich in X) is directionally correct but implemented as a **multiplicative bump** (e.g. +30% IMBALANCE_ASYMM, +15% ASYMM_BOOST) on a base that’s already capped. So we still top out at 100 bps on the “protected” side. We need either **much** higher effective fees when imbalanced or a different mechanism (e.g. dynamic cap, or inventory penalty rather than fee).

### 1.5 Size sensitivity is one step late

- We bump fee when **this** trade was large (`sizeRatio = amountX / reserveX`). The **next** trade gets the higher fee. The large trade (often the arb) already happened at the old fee. So size sensitivity again **reacts** instead of **deters**.

### 1.6 Decay creates a predictable cycle

- With `DECAY_FACTOR = 0.95`, fees decay toward BASE_FEE over **time steps** (no trade). So: arb hits → we raise fee → a few steps pass with no trade → fee decays → next arb gets a lower fee. An adversarial sim can time arbs to arrive after decay, farming our pool when fee is low and mispricing is still present.

### 1.7 Summary of mechanical causes

| Cause | Effect |
|-------|--------|
| Fee set in afterSwap | Fee applies to next trade; we’re always one step behind. |
| No fair price in TradeInfo | We can’t measure or respond to mispricing directly. |
| Volatility = realized move | We raise fees after arb, not before. |
| 100 bps cap | We can’t charge enough when mispricing is large (e.g. 9.6%). |
| Asymmetry as % bump on capped base | Still capped; not enough when badly imbalanced. |
| Size bump on next fee | Large (arb) trade already executed at old fee. |
| Time decay | Fees drop between trades; arbs can wait and hit when fee is low. |

---

## 2. How Traders Exploit Us

### 2.1 Arbitrageur playbook

1. **Observe:** Fair price (e.g. 1.0) vs AMM spot (e.g. 1.096). Mispricing 9.6% >> fee (30–100 bps). Trade is profitable.
2. **Direction:** Spot > fair ⇒ AMM is expensive in X ⇒ arb **sells X** to AMM (AMM buys X). Our “raise bid when rich in Y” is correct in direction but too small and one trade late.
3. **Size:** Arb trades until marginal mispricing is near fee. Our size sensitivity raises the **next** fee; they’ve already taken size at the current fee.
4. **Timing:** If the sim has multiple steps between trades, arb can wait for decay: after a few no-trade steps our fee drifts back toward 30 bps, then arb hits again. So they exploit **predictable decay** and **lag**.

### 2.2 Predictable behavior they can use

- **Asymmetry is deterministic:** We always raise bid when reserveY ≥ reserveX and ask when reserveX > reserveY. So they know which side we’re “protecting” and that the other side is relatively cheaper; they can still hit the side that hurts us if the mispricing is large enough.
- **Volatility mean-reverts slowly:** After a big move, vol stays high for a while (EWMA). So they know we’ll keep fees elevated for several steps. They don’t need to front-run that; they just need to have already traded before we raised fees.
- **Decay is time-based:** If they can observe or infer “steps since last trade,” they can infer that our fee is decaying. Trade when fee has decayed and mispricing is still there.

### 2.3 What we don’t know (and they do)

- We don’t see **fair price**. They do (in the sim, they trade when |AMM_price − fair| > fee). So they have a direct mispricing signal; we only have reserves and past prices. **Information asymmetry** is in their favor.

---

## 3. Failure Modes

### 3.1 Regime: Fast mean-reversion of fair price

- Fair price reverts quickly; our spot is slow to follow (we only move when someone trades). So we’re often wrong (mispriced). We raise fees after each move (high vol), but the next move can be in the opposite direction (retail or arb the other way). We may overcharge retail and still get arbed when we’re wrong. **Result:** Low retail edge, high arb edge; cumulative edge negative.

### 3.2 Regime: Sustained drift (trend)

- Fair price drifts in one direction. We get repeatedly arbed on one side (e.g. AMM keeps buying X). Imbalance grows (e.g. rich in X). We raise ask (correct), but we’re capped and one step behind. Each arb trade already happened at the previous fee. **Result:** Large cumulative arb loss, small fee income.

### 3.3 Regime: Volatility clustering

- Bursts of moves. We raise vol and fees during the burst; by then, several arbs have already traded. After the burst, we decay. If the next burst comes after decay, we’re at low fee again. **Result:** We pay during the burst, don’t recoup enough in calm periods because we’ve decayed.

### 3.4 Structural: Backward-looking model

- Every signal (volatility, imbalance, size, last-trade direction) is **backward-looking**. We have no **forward-looking** or **leading** indicator (we don’t have fair price, order flow, or queue). So we will always be late in adversarial environments.

### 3.5 Tail events

- When mispricing is very large (e.g. 10%), a single arb can take a huge chunk of value. Our fee is bounded (e.g. 100 bps). So we **misprice tail risk**: we don’t charge enough in extreme imbalance. The cap is the main culprit.

---

## 4. Superior Design Ideas

### 4.1 Lead, don’t lag (within constraints)

- We **cannot** change the API to `beforeSwap` (it’s `afterSwap` only). So we **cannot** set the fee for the **current** trade. We can only optimize the **next** fee.
- We can still **anticipate who hits next**: e.g. if we’re rich in Y (spot high), the **next** exploiter is likely to sell X (AMM buys X) → we should **already** have raised **bid** fee. So asymmetry should be **strong** and **imbalance-driven**, not just a small bump. Idea: **imbalance-based fee floor** so that when |reserveX − reserveY| is large, we don’t decay below a floor that scales with imbalance.

### 4.2 Imbalance as the main driver (no fair price)

- Without fair price, **imbalance** is our best proxy for “we’re wrong and someone will arb us.” So:
  - **Fee should increase monotonically and strongly with imbalance**, not only via a 1x multiplier. E.g. fee = base + f(imbalance) with f(0)=0 and f(1) large (e.g. 200–500 bps if the platform allows).
  - **Decay should be imbalance-aware:** decay toward `BASE_FEE + imbalance_floor(imbalance)` instead of toward pure BASE_FEE. So when we’re very imbalanced, we don’t decay back to 30 bps; we stay elevated.

### 4.3 Volatility: use for regime, not for one-step reaction

- Use volatility to **classify regime** (calm vs active), not to spike fee after every move. E.g.:
  - **Calm (low vol):** fee closer to base, symmetric; attract retail.
  - **Active (high vol):** fee floor raised, stronger asymmetry. So we don’t overreact to every single trade (reducing noise), but we stay defensive in volatile regimes.

### 4.4 Asymmetry: make it large and imbalance-driven

- When **rich in Y** (reserveY ≥ reserveX): arbs sell X → we want **bid fee >> ask fee** (e.g. bid = 2–3× ask or use a formula). When **rich in X**: **ask >> bid**. So the side that “fixes” our inventory should be expensive; the other side can stay lower to attract flow that helps us. Implementation: **bidFee = base × (1 + k_bid × imbalance_direction)**, **askFee = base × (1 + k_ask × imbalance_direction)** with direction = +1 when rich in Y (raise bid), −1 when rich in X (raise ask), and k_bid/k_ask large enough (e.g. 0.5–1.0 in WAD terms) so we get 50–100% asymmetry, and **no cap on the vulnerable side** if the platform allows, or a higher cap.

### 4.5 Cap and floor

- If the platform allows: **raise the cap** for the side we’re protecting (e.g. up to 300–500 bps when heavily imbalanced). Or use **dynamic cap**: cap = min(MAX_FEE, base × (1 + c × imbalance)).
- **Floor:** don’t let fee decay below a floor that depends on recent vol or imbalance (e.g. floor = base + vol_term or base + imbalance_term).

### 4.6 Size: predictive, not reactive

- We can’t know the **next** trade size. We can use **recent** large trades to infer “we’re in a regime where large trades happen” and keep fee elevated (e.g. store “recent max size ratio” in a slot and use it to set a floor or multiplier for the next N steps). So size doesn’t change the fee for the trade that just happened; it keeps the **next** fees higher for a short window.

### 4.7 Simplify to reduce overfitting

- **Drop or reduce:** complex last-trade-direction logic (ASYMM_BOOST on lastWasBuy); it’s noisy and one step behind. **Keep:** imbalance-based asymmetry (rich in Y → high bid, rich in X → high ask), volatility regime (calm vs active), imbalance-aware decay.
- **Single source of truth for “who gets hit next”:** imbalance direction. That’s the only clean signal we have without fair price.

---

## 5. Concrete Formula / Pseudocode

### 5.1 Notation

- `spot = reserveY / reserveX`
- `imbalance = |reserveX - reserveY| / (reserveX + reserveY)` in [0, 1]
- `richInY = (reserveY >= reserveX)` (spot ≥ 1)
- `vol` = EWMA of |Δprice|/lastPrice (existing)
- Constants: `BASE = 30e14`, `K_IMB = 2e18` (imbalance sensitivity), `K_VOL = 15e18` (vol sensitivity), `FLOOR_IMB = 50e14` (50 bps per 0.1 imbalance), `CAP = 300e14` (300 bps if allowed else 100e14), `DECAY = 0.96`, `ALPHA = 0.25`

### 5.2 Fee formula (conceptual)

```
// 1) Base from vol and imbalance (multiplicative)
vol_factor = 1 + K_VOL * vol
imb_factor = 1 + K_IMB * imbalance
raw_fee = BASE * vol_factor * imb_factor

// 2) Imbalance-aware floor (so we don't decay to base when imbalanced)
imb_floor_bps = FLOOR_IMB * imbalance   // e.g. 50 bps per 0.1 imbalance
fee_floor = BASE + imb_floor_bps
raw_fee = max(raw_fee, fee_floor)

// 3) Decay toward fee_floor (not toward BASE)
if steps_since_last > 0 and raw_fee > fee_floor:
  decay = DECAY^steps_since_last
  raw_fee = fee_floor + (raw_fee - fee_floor) * decay
base_fee = clamp(raw_fee, fee_floor, CAP)

// 4) Asymmetry: raise fee on the side arbs hit
if richInY:
  bid_fee = min(CAP, base_fee * (1 + ASYMM))   // e.g. ASYMM = 0.6 => +60%
  ask_fee = base_fee
else:
  ask_fee = min(CAP, base_fee * (1 + ASYMM))
  bid_fee = base_fee

return (bid_fee, ask_fee)
```

### 5.3 Pseudocode (Solidity-like)

```solidity
// Constants
uint256 constant BASE = 30e14;
uint256 constant K_IMB = 2e18;
uint256 constant K_VOL = 15e18;
uint256 constant FLOOR_IMB_BPS = 50e14;  // 50 bps per 0.1 imbalance
uint256 constant CAP = 300e14;            // or 100e14 if platform cap is 100 bps
uint256 constant ASYMM = 60e16;           // 60% extra on vulnerable side
uint256 constant DECAY = 96e16;
uint256 constant ALPHA = 25e16;

function afterSwap(TradeInfo calldata t) external override returns (uint256 bidFee, uint256 askFee) {
  uint256 lastPrice = slots[SLOT_PRICE];
  uint256 oldVol = slots[SLOT_VOLATILITY];
  uint256 lastTs = slots[SLOT_TIMESTAMP];

  uint256 spot = wdiv(t.reserveY, t.reserveX);
  uint256 priceCh = wdiv(absDiff(spot, lastPrice), lastPrice);
  uint256 vol = wmul(ALPHA, priceCh) + wmul(ONE_WAD - ALPHA, oldVol);
  uint256 imb = wdiv(absDiff(t.reserveX, t.reserveY), t.reserveX + t.reserveY);

  uint256 volFactor = ONE_WAD + wmul(K_VOL, vol);
  uint256 imbFactor = ONE_WAD + wmul(K_IMB, imb);
  uint256 rawFee = wmul(BASE, wmul(volFactor, imbFactor));

  uint256 imbFloor = BASE + wmul(imb, FLOOR_IMB_BPS * 10);  // scale so 0.1 imb => 50 bps
  if (rawFee < imbFloor) rawFee = imbFloor;

  if (t.timestamp > lastTs && lastTs > 0 && rawFee > imbFloor) {
    uint256 steps = t.timestamp - lastTs;
    uint256 decay = wmul(steps, ONE_WAD - DECAY);
    if (decay > ONE_WAD) decay = ONE_WAD;
    rawFee = imbFloor + wmul(ONE_WAD - decay, rawFee - imbFloor);
  }
  uint256 baseFee = min(max(rawFee, imbFloor), CAP);

  bool richInY = t.reserveY >= t.reserveX;
  if (richInY) {
    bidFee = min(CAP, wmul(baseFee, ONE_WAD + ASYMM));
    askFee = baseFee;
  } else {
    askFee = min(CAP, wmul(baseFee, ONE_WAD + ASYMM));
    bidFee = baseFee;
  }

  slots[SLOT_PRICE] = spot;
  slots[SLOT_VOLATILITY] = vol;
  slots[SLOT_TIMESTAMP] = t.timestamp;
  return (clampFee(bidFee), clampFee(askFee));
}
```

(You’d need to implement `min`/`max` or use inline conditionals and match the project’s WAD helpers and slot indices.)

### 5.4 If the platform caps at 100 bps

- Keep **CAP = 100e14**. Then the main levers are: (1) **imbalance-aware decay** (don’t decay to 30 bps when imbalanced), (2) **strong asymmetry** so the vulnerable side is 100 bps and the other side is lower (e.g. 40–50 bps) to stay competitive on the “helpful” side, (3) **faster reaction** (higher ALPHA, higher K_IMB) so we hit 100 bps quickly when imbalance grows. We still cannot fully deter arb at 9.6% mispricing with 100 bps; the goal is to **reduce how often we’re that wrong** (e.g. by not decaying aggressively) and to **maximize retail capture** on the non-vulnerable side.

---

## 6. Backtest Blueprint

### 6.1 Core metrics

- **Cumulative edge** (total, retail, arb) — primary.
- **LP PnL** (or equivalent) if the sim provides it.
- **Fee capture ratio:** (fees collected) / (gross volume) vs (arb loss) / (volume). Target: fee capture covers arb loss and leaves positive edge.
- **Drawdowns:** max peak-to-trough in cumulative edge; max single-trade loss.
- **Variance of edge per step** (or per 100 steps): lower is more stable.

### 6.2 Conditioning

- **By regime:** low vol vs high vol (e.g. vol above/below median); trend vs mean-reversion (e.g. by autocorrelation of fair price); balanced vs imbalanced (e.g. |reserveX − reserveY| / (reserveX + reserveY) above/below 0.2).
- **By trade type:** retail-only cumulative edge; arb-only cumulative edge; ratio (retail edge / |arb edge|).
- **By mispricing at trade time:** bin trades by |spot − fair| (if available in logs) and compute edge and fee per bin. We want fee to scale with mispricing so that when mispricing is large, we at least charge more (even if we can’t fully deter).

### 6.3 What to compare

- VIAF v2 (current) vs fixed 30 bps vs fixed 100 bps.
- VIAF v2 vs redesigned (imbalance floor + strong asymmetry + imbalance-aware decay).
- Sensitivity: vary CAP (50 vs 100 vs 300 bps if allowed), ASYMM (0.3 vs 0.6 vs 1.0), DECAY (0.92 vs 0.96 vs 0.99), K_IMB (1 vs 2 vs 3).

### 6.4 Red flags

- Arb edge remains large and negative while retail edge is small positive → we’re still being farmed.
- Fee revenue << |arb loss| → fee level or cap is too low.
- Edge variance very high → strategy is unstable or overfitting to one path.

---

## 7. If I Had To Win The Competition

### 7.1 Priorities

1. **Imbalance is the main signal.** No fair price → reserves are all we have. Make fee and asymmetry **strongly** imbalance-driven; don’t decay toward base when imbalanced (imbalance-aware floor/decay).
2. **Asymmetry must be large.** The side that arbs hit (sell X when we’re rich in Y, buy X when we’re rich in X) should be at cap or close; the other side can be lower to attract flow that rebalances us.
3. **Don’t over-decay.** With afterSwap-only API, we’re already one step behind. If we decay aggressively, we’re at low fee right when the next arb arrives. Prefer **slower decay** or **decay toward an imbalance-dependent floor**, not toward 30 bps.
4. **Cap:** If the rules allow >100 bps, use a higher cap (e.g. 200–300 bps) on the vulnerable side when imbalance is high. If stuck at 100 bps, accept we can’t deter large mispricing and focus on (1) and (2) to minimize how often we’re badly wrong and to maximize retail on the other side.
5. **Simplify.** Remove or tone down last-trade-direction and size bumps; they’re lagging and noisy. One clear rule: “imbalance direction decides which side we protect and how high we go” is easier to tune and harder to overfit.

### 7.2 One paragraph

We lose because we set fee **after** the trade (so we’re always one step behind), we have **no fair price** (so we can’t see mispricing), and we **cap at 100 bps** while arbs profit when mispricing is much larger. To improve: (1) make **imbalance** the main driver and don’t decay toward base when imbalanced; (2) make **asymmetry** large (vulnerable side at or near cap, other side lower); (3) **slow or imbalance-aware decay**; (4) **raise cap** if allowed when imbalanced; (5) **drop** complex last-trade/size logic and rely on imbalance + vol regime. Validate with cumulative edge (total, retail, arb), fee capture vs arb loss, and regime-conditioned metrics; tune CAP, ASYMM, DECAY, and K_IMB in the sim.

---

*Assumptions: fee is applied to the next trade; TradeInfo has no fair price; platform may cap global fee at 100 bps. If the simulator or rules differ (e.g. beforeSwap, or fair price in callback), the same ideas apply but implementation can be simplified (e.g. use fair price directly for mispricing-based fee).*
