# VIAF Strategy Improvement Analysis (AMM Fee Designer)

**Context:** VIAF v3 Edge 374.54 (1000 sims) vs YQ Edge 524.63. Goal: close the gap by adopting concepts from YQ (inspiration only), applied to VIAF’s structure.

---

## Step 1 — Loss Diagnosis

**Why VIAF is underperforming (mechanical weaknesses):**

1. **No toxicity signal**  
   Volatility is `|spot - lastPrice|/lastPrice` — it measures *price move size*, not *how informed/adversarial* the trade is. Arbitrageurs and informed flow move price *away from* a fair reference; VIAF has no “fair price” (e.g. filtered `pHat`). So it cannot charge more when the trade is toxic (large deviation from fair) and less when it’s benign.

2. **Asymmetry is inventory-only, no flow direction**  
   Asymmetry is purely “rich in Y → raise bid; else raise ask”. There is no notion of *recent buy vs sell pressure* (direction state). Fast one-sided flow can move inventory and then reverse; VIAF raises one side only after inventory has already moved, so it lags and can mis-price the next trade.

3. **No trade-size or trade-rate adjustment**  
   Fee does not depend on `amountX/amountY` or on how many trades occurred in the step. Large trades and bursty activity carry more adverse selection; YQ uses `sizeHat`, `lambdaHat`, and `flowSize` to scale fees. VIAF treats a tiny and a large trade the same after the fact.

4. **Decay is time-based only**  
   Decay toward the imbalance floor uses `steps = timestamp - lastTs`. There is no per-step “reset” or different behavior for the first trade in a step vs follow-ups, so the fee cannot react differently to the first hit vs retail flow in the same step.

5. **Single volatility series**  
   One EWMA on absolute price change mixes all directions. There is no “stale direction” or “trade-aligned” boost (e.g. charge more when the trade is in the direction of the move), which YQ uses to capture more edge from toxic flow.

**Summary:** Losses come from (a) lag in adapting to *who* is trading (no toxicity), (b) asymmetry driven only by inventory (no flow direction), (c) no size/activity scaling, and (d) no first-trade vs same-step differentiation.

---

## Step 2 — Adversarial Exploitation

1. **Arb front-running**  
   Arb sees imbalance and knows VIAF will raise the vulnerable side. They can trade *before* the next large order, paying the current (lower) fee, then the victim pays the raised fee. VIAF’s asymmetry is predictable from reserves alone.

2. **Toxic flow at “fair” volatility**  
   Informed trader can move price a lot in one trade. Volatility EWMA smooths this, so the next fee update is moderate. The strategy does not separately punish *this trade’s* deviation from a fair price, so toxic flow gets undercharged.

3. **Size splitting / timing**  
   Same economic size can be split into many small trades or one large trade. VIAF does not use trade size or step trade count, so large toxic size can be executed without triggering a size-based fee bump.

4. **Directional grinding**  
   Repeated buys (or sells) move inventory and volatility slowly. VIAF raises fees via imbalance and vol, but the *side* of the fee rise is only from current inventory. A flow that will reverse can get in at the current side and out later when the other side is raised.

---

## Step 3 — Failure Modes

| Regime              | Limitation |
|---------------------|------------|
| High volatility     | Vol EWMA lags; no per-trade “toxicity” spike, so fees don’t spike enough on the toxic trade. |
| Low liquidity       | Imbalance and vol can be noisy; no filtered fair price → overreaction to noise or underreaction to real toxicity. |
| Bursty flow         | No lambda/size/flow-size term; bursty informed flow is undercharged. |
| Mean reversion      | Asymmetry flips with inventory; no direction memory, so reverting flow can be mis-priced. |
| Choppy / two-sided  | Single vol series and binary asymmetry may over-raise both sides or oscillate without capturing flow direction. |

---

## Step 4 — New Strategy Ideas

**Concept A — Toxicity from filtered price (YQ-inspired)**  
- Maintain a filtered “fair” price `pHat` (e.g. EWMA of spot, or only update when `|spot - pHat|/pHat` is below a gate).  
- Define toxicity as `tox = |spot - pHat|/pHat` (capped).  
- Add a fee term that increases in `tox` (e.g. linear + quadratic, or cubic for strong punishment of very toxic flow).  
- **Addresses:** undercharging informed flow, no notion of “this trade is far from fair”.

**Concept B — Direction state + skew (YQ-inspired)**  
- Keep a direction state `dirState` (e.g. centered at WAD: above = sell pressure, below = buy pressure), updated by trade direction and size (e.g. trade ratio = amountY/reserveY).  
- Skew bid/ask by `dirState`: e.g. sell pressure → raise bid, lower ask (and vice versa).  
- **Addresses:** asymmetry based only on inventory; adds flow-direction memory.

**Concept C — Trade-size and trade-rate (YQ-inspired)**  
- Use `tradeRatio = amountY / reserveY` (capped) and optionally step trade count for a “lambda” (trades per step).  
- Blend into size and activity EMAs; add a fee term like `base + coef_size * sizeHat + coef_lambda * lambdaHat` or `flowSize = lambda * size`.  
- **Addresses:** no differentiation between small and large trades, or quiet vs busy steps.

**Concept D — Stale-direction / trade-aligned boost (YQ-inspired)**  
- If `spot >= pHat`, treat as “price moved up” → raise bid a bit, lower ask (or vice versa).  
- Optionally: if the *current* trade direction aligns with the move (e.g. buy when spot >= pHat), add a one-off boost to the side that was just hit.  
- **Addresses:** capturing more edge on the side that’s being hit by toxic flow.

**Concept E — Keep VIAF core, add toxicity + one flow signal**  
- Keep: imbalance floor, decay toward floor, vol factor, single-rule asymmetry from inventory.  
- Add: (1) filtered price `pHat` and toxicity `tox`; (2) one extra signal: either direction state *or* trade-size/activity (to stay within slot/compute budget).  
- Fee: `rawFee = base * volFactor * imbFactor + toxCoef * tox + toxQuad * tox^2`, then apply existing floor, decay, and asymmetry.  
- **Addresses:** biggest gap (no toxicity) with minimal structural change and tractable on-chain cost.

---

## Step 5 — Formulas & Pseudocode

### 5.1 Toxicity (Concept A / E)

- **State:** `pHat` (WAD), `sigmaHat` (WAD) for adaptive gate.  
- **Update (after trade):**  
  - `spot = reserveY / reserveX` (or last price if no reserves).  
  - `ret = |pImplied - pHat|/pHat` where `pImplied` can be spot for simplicity, or derived from fee and isBuy.  
  - Optional gate: only update `pHat` if `ret <= gate` (e.g. `gate = max(minGate, sigmaHat * mult)`).  
  - `pHat = (1 - alpha) * pHat + alpha * pImplied` (or spot); `sigmaHat = (1 - alpha_sigma) * sigmaHat + alpha_sigma * ret`.  
- **Toxicity:**  
  - `tox = |spot - pHat|/pHat`, cap e.g. at 20%.  
  - `toxEma = (1 - alpha_tox) * toxEma + alpha_tox * tox`.  
- **Fee term:**  
  - `f_tox = toxCoef * toxEma + toxQuadCoef * toxEma^2` (optional cubic: `+ toxCubicCoef * toxEma^3`).

### 5.2 Direction state (Concept B)

- **State:** `dirState` in [0, 2*WAD], WAD = neutral.  
- **Update:**  
  - `tradeRatio = amountY / reserveY`, capped (e.g. 20%).  
  - If `tradeRatio > threshold`: if buy then `dirState += push` (cap at 2*WAD), else `dirState = max(0, dirState - push)`.  
- **Decay:** each new step: `dirState` decays toward WAD (e.g. `dirState = WAD + decay^(elapsed) * (dirState - WAD)`).  
- **Skew:**  
  - `dirDev = |dirState - WAD|`, `sellPressure = (dirState >= WAD)`.  
  - If sellPressure: `bidFee = mid + skew`, `askFee = mid - skew`; else swap.  
  - `skew = dirCoef * dirDev` (optional: `+ dirToxCoef * dirDev * tox`).

### 5.3 Trade-size / flow (Concept C)

- **State:** `sizeHat`, `lambdaHat` (optional).  
- **Update:**  
  - `tradeRatio = amountY / reserveY` (capped).  
  - `sizeHat = decay * sizeHat + (1 - decay) * tradeRatio`.  
  - If new step: `lambdaInst = stepTradeCount / elapsed`, `lambdaHat = decay * lambdaHat + (1 - decay) * lambdaInst`.  
- **Fee:**  
  - `flowSize = lambdaHat * sizeHat`;  
  - `f_base += flowSizeCoef * flowSize` and/or `f_base += lambdaCoef * lambdaHat`.

### 5.4 VIAF v4 sketch (Concept E — minimal add-on)

- **Slots:** Reuse SLOT_PRICE as `pHat`, SLOT_VOLATILITY as `vol` (or repurpose one for `toxEma`), add slots for `sigmaHat`, `toxEma`, keep SLOT_TIMESTAMP. So: price→pHat, vol, timestamp, sigmaHat, toxEma (e.g. 5 slots).  
- **After swap:**  
  1. Compute `spot`, `vol` (current vol EWMA update).  
  2. `ret = |spot - pHat|/pHat`; optional gate to update `pHat`; update `sigmaHat`.  
  3. `pHat = alpha * spot + (1-alpha)*pHat` (or gated).  
  4. `tox = min(cap, |spot - pHat|/pHat)`; `toxEma = alpha_tox * tox + (1-alpha_tox)*toxEma`.  
  5. Imbalance and vol factor as now; **add** `f_tox = toxCoef * toxEma + toxQuad * toxEma^2`.  
  6. `rawFee = base * volFactor * imbFactor + f_tox`; apply imbalance floor, decay, cap.  
  7. Asymmetry as now (richInY → bid up, else ask up).  
- **Parameters:** e.g. `toxCoef = 50e14`, `toxQuad = 200e14`, `alpha_tox = 0.1`, `toxCap = 0.2e18`; gate optional for v4.

---

## Step 6 — Simulation Blueprint

- **Inputs:** Same as challenge (trade stream: isBuy, amountX, amountY, timestamp, reserveX, reserveY).  
- **Metrics:**  
  - LP PnL (primary).  
  - Fee capture ratio (fees collected / volume).  
  - Trader surplus (for stability).  
  - Volatility sensitivity (PnL in high vs low vol regimes).  
  - Drawdown / max DD.  
- **Scenarios:**  
  - Baseline (same 1000 sims as current).  
  - Regime split: low / medium / high vol (e.g. by sigmaHat or by realized vol in the run).  
  - Toxic injection: add synthetic “informed” trades (large size, direction aligned with next move) and compare fee capture vs VIAF v3.  
- **Criteria:**  
  - VIAF v4 Edge (1000 sims) > VIAF v3 (374.54); target closer to 450+ then tune toward 500+.  
  - No material increase in drawdown; fee capture ratio should increase in toxic subsamples.

---

## Step 7 — Recommendation

**Prioritized recommendation: Concept E (VIAF + toxicity), then optionally B (direction).**

- **Reasoning:**  
  - The largest mechanical gap is **no toxicity**; adding a filtered price and a toxicity term is the highest impact per extra state.  
  - It fits VIAF’s structure (same imbalance/vol/floor/decay/asymmetry), uses a small number of extra slots (pHat can replace or sit beside “last price”, plus sigmaHat and toxEma), and is on-chain tractable.  
  - Direction state (Concept B) and trade-size (Concept C) are natural next steps if slot budget allows; YQ’s tail compression and trade-aligned boost can be later refinements.

**Concrete next step:** Implement **VIAF v4** with:  
1. `pHat` (filtered price) and optional gate; `sigmaHat` for gate.  
2. `tox = min(toxCap, |spot - pHat|/pHat)`; `toxEma`.  
3. Fee add-on: `f_tox = toxCoef * toxEma + toxQuad * toxEma^2`.  
4. Keep existing imbalance floor, decay, vol factor, and single-rule asymmetry.  
5. Run 1000 sims; tune toxCoef, toxQuad, alpha_tox, toxCap to maximize Edge without breaking stability.

---

*Document generated following the AMM Fee Designer skill. Implementation: VIAFStrategy v4 in contracts.*
