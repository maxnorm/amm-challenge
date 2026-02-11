# Sapient v5 — Research-Backed Redesign to Boost Edge

**Current:** Sapient v4 (VIAFStrategy.sol) — Edge **374.54** (1000 sims).  
**Goal:** Apply findings from top AMM fee papers to propose and implement changes that **boost edge drastically** while staying on-chain tractable.

---

## Part A — Top Papers Summary (Online Research)

### 1. Alexander & Fritz (2024) — "Fees in AMMs: A quantitative study" (arXiv:2406.12417)

- **Finding:** "We identify **dynamical fees that mimic the directionality of the price** due to **asymmetric fee choices** as a promising avenue to mitigate losses to toxic flow."
- **Implication:** Asymmetry should follow **price direction**, not only inventory. When price has moved up (spot > fair), charge more on the side that would be hit by continuation (e.g. ask / AMM sells X); when price moved down, charge more on bid.
- **Mechanics:** Model arbitrage dynamics; fee choices affect value retention; map to random-walk with reward schemes.

### 2. Adams, Moallemi, Reynolds, Robinson (2024) — "am-AMM: An Auction-Managed AMM" (arXiv:2403.03367)

- **Finding:** Dynamic fees set by a pool manager that adapt to (a) retail orderflow price sensitivity and (b) arbitrage opportunities reduce LVR and maximize revenue; equilibrium liquidity can be higher than fixed-fee AMMs.
- **Implication:** Fee should **adapt to who is trading** (informed vs uninformed) and to **recent market conditions**. We cannot run an auction, but we can approximate: **surge fees on large moves** (cap events) and **asymmetric response to trade direction**.

### 3. Milionis et al. (2023) — LVR and fee model

- **Finding:** Trading fees **rescale arbitrage profits** by the fraction of time profitable opportunities exist — a "no-trade region" around AMM price. LVR (frictionless) ∝ **σ²** (volatility squared).
- **Implication:** Fee should scale with **volatility** (we have this) and ideally with **variance** (σ²) to create the right no-trade region; also **faster reaction** to vol reduces window for arb.

### 4. Uniswap v4 / Aegis-style dynamic fees

- **Approaches:** (a) **Oracle-based:** fee from deviation of pool price vs external price. (b) **Momentum-based:** asymmetric fees from recent price history. (c) **Volatility-based:** base fee + surge on extreme moves (e.g. Aegis: BaseFee + SurgeFee on "cap events").
- **Implication:** Combine **volatility base**, **directionality (momentum) asymmetry**, and **surge on gate breach** (large move = cap event).

---

## Part B — Step 1: Loss Diagnosis (Why v4 Tops at ~374)

1. **Asymmetry is only inventory-based**  
   We raise bid when rich in Y and ask when rich in X. Papers say **directionality** matters: we should charge more on the side that *continues* the price move (e.g. price up → ask premium). v4 does not use (spot − pHat) sign for asymmetry.

2. **Toxicity is applied uniformly**  
   Toxicity add-on (linear + quadratic) and trade-aligned boost apply to both sides or to the "aligned" side. Research suggests concentrating **toxicity premium on the vulnerable side** (where informed flow hits) reduces mis-pricing of the other side and preserves volume.

3. **No explicit "surge" on toxic moves**  
   When spot leaves the gate (ret > adaptiveGate), we treat it as toxic but only through toxEma. A **one-off surge** on the side that was just hit (cap event) could capture more from that move without keeping base fee elevated for many steps.

4. **pHat lags in trends**  
   When price trends, pHat updates rarely → tox stays high for long → we over-charge subsequent flow. Optional improvement: allow pHat to catch up faster when we've been outside gate (trending regime).

---

## Part C — Step 2: Adversarial Exploitation (if we don’t change)

1. **Fade the non-vulnerable side** — Arb trades the side we didn’t raise; inventory asymmetry alone doesn’t use direction.
2. **Volume drop from uniform toxicity** — Over-charging both sides reduces flow and total fee capture.
3. **No surge on big move** — One large toxic trade pays only the current fee; we could capture more with a short-lived surge.

---

## Part D — Step 3: Failure Modes

| Regime        | v4 limitation                          | Effect                          |
|---------------|----------------------------------------|---------------------------------|
| Trending      | pHat lags; tox high for many steps     | Over-charge benign follow-up   |
| Choppy        | Trade-aligned boost often wrong        | Boost on reverting side         |
| Large toxic   | No surge; only toxEma                  | Under-capture on the big move   |
| Directional   | Asymmetry only by inventory           | Wrong side priced high          |

---

## Part E — Step 4 & 5: New Strategy Ideas and Formulas

### Idea 1 — Directionality-mimicking asymmetry (Alexander & Fritz)

- **Core:** Asymmetric fees that **mimic price direction**. If spot > pHat (price moved up), add a **premium on the ask** (AMM sells X); if spot < pHat, add premium on the **bid**. So we charge more on the side that would be hit if the move continues.
- **Formula (WAD):**
  - `dirPremium = ASYMM_DIR * |spot - pHat| / pHat` (capped).
  - If `spot >= pHat`: `askFee += dirPremium`, else `bidFee += dirPremium`.
- **Parameters:** `ASYMM_DIR` (e.g. 0.15–0.25 in WAD for 15–25% extra on that side), cap on `dirPremium` (e.g. 20 bps).

### Idea 2 — Toxicity on vulnerable side only (inventory-toxicity)

- **Core:** Apply the toxicity add-on (linear + quadratic in toxEma) **only to the vulnerable side**: rich in Y → add to **bid**; rich in X → add to **ask**. Base fee (vol + imb + floor) stays symmetric; only the toxicity premium is one-sided.
- **Formula:**  
  - `toxPremium = TOX_COEF * toxEma + TOX_QUAD_COEF * toxEma²`.  
  - If `reserveY >= reserveX`: `bidFee += toxPremium`; else `askFee += toxPremium`.  
  - No separate trade-aligned boost; avoids double penalty and wrong-side raise.

### Idea 3 — Surge on gate breach (Aegis-style cap event)

- **Core:** When **ret > adaptiveGate** (this trade was a "large move" relative to sigma), add a **surge fee** to the side that was just hit (isBuy → bid, !isBuy → ask). Surge decays over no-trade steps so it doesn’t persist.
- **Formula:**
  - If `ret > adaptiveGate`: `surge = SURGE_BPS` (e.g. 15e14 = 15 bps).
  - Apply surge to `bidFee` if `trade.isBuy`, else to `askFee`.
  - Store `surgeAmount` in a slot; each step with no trade: `surgeAmount = surgeAmount * SURGE_DECAY` (e.g. 0.9). Apply current surgeAmount to the *same* side as when it was set (store `surgeOnBid` bool or derive from last trade).
- **Simplification:** Apply surge only on the *current* trade’s side (one-shot), no decay state — i.e. when gate is breached, add SURGE_BPS to that side for this step only. Easier and still captures the event.

### Idea 4 (Optional) — Volatility-squared term (LVR)

- **Core:** LVR ∝ σ²; add a small fee term ∝ sigmaHat² to widen the no-trade region in high-vol regimes.
- **Formula:** `fee += K_VOL2 * sigmaHat²` (capped). More gas; can be added in a later version if needed.

---

## Part F — Step 6: Simulation Blueprint

- **Inputs:** Same as now (1000 sims, same harness).
- **Metrics:** Edge (primary), fee capture ratio, drawdown if available.
- **Scenarios:**
  - Baseline: v4 (374.54).
  - V5-A: Directionality asymmetry only.
  - V5-B: Inventory-toxicity only (tox on vulnerable side, no trade-aligned boost).
  - V5-C: Surge on gate breach only (one-shot).
  - V5-full: Directionality + inventory-toxicity + surge.
- **Criteria:** Edge > 374.54; aim for **drastic** improvement (e.g. > 400); check stability across runs.

---

## Part G — Step 7: Recommendation

**Priority for V5:**

1. **Directionality-mimicking asymmetry** — Implement premium on ask when spot ≥ pHat, on bid when spot < pHat (capped). This directly implements Alexander & Fritz’s "asymmetric fee choices that mimic the directionality of the price."
2. **Toxicity on vulnerable side only** — Move toxicity add-on from base (symmetric) to **vulnerable side only** (rich in Y → bid; else ask). Remove trade-aligned boost to avoid wrong-side raise.
3. **Surge on gate breach** — When ret > adaptiveGate, add a one-shot surge (e.g. 10–15 bps) to the side that was just hit. No extra slot if we do one-shot.

**Concrete implementation:** New file **VIAFStrategyV5.sol** (per versioning rule) with:

- Same base as v4: BASE_FEE, vol, imbalance, floor, decay, cap 100 bps, pHat/sigma/toxEma.
- **Replace** single-rule inventory asymmetry + trade-aligned boost with:
  - **Directionality:** dirPremium from (spot − pHat), apply to ask if spot ≥ pHat else to bid.
  - **Inventory asymmetry:** keep 60% on vulnerable side (rich in Y → bid, else ask).
  - **Toxicity:** apply toxPremium only to vulnerable side (same as inventory).
  - **Surge:** if ret > adaptiveGate, add SURGE_BPS to bid if isBuy else to ask (one-shot).

**Implementation:** `amm-challenge/contracts/src/VIAFStrategyV5.sol`

Run (from `amm-challenge` with your venv):  
`amm-match run contracts/src/VIAFStrategyV5.sol --simulations 1000`  
Compare Edge to 374.54 (v4 baseline).

---

## References

- Alexander, A., Fritz, L. (2024). *Fees in AMMs: A quantitative study*. arXiv:2406.12417.
- Adams, A., Moallemi, C.C., Reynolds, S., Robinson, D. (2024). *am-AMM: An Auction-Managed Automated Market Maker*. arXiv:2403.03367.
- Milionis, J., et al. (2023). *LVR and fee model* (fee rescaling, no-trade region). arXiv/moallemi.com.
- Uniswap v4 Dynamic Fees; Aegis DFM (BaseFee + SurgeFee).
