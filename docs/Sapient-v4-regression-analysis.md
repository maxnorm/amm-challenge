# Sapient v4 Regression Analysis (AMM Fee Designer)

**Observed:** Sapient v4 (toxicity + imbalance-floor + asym) **Edge 342.07** vs v3 **374.54** (−32.5).  
**Goal:** Diagnose why v4 underperforms v3 and recommend fixes.

---

## Step 1 — Loss Diagnosis (Why v4 Loses vs v3)

1. **Over-charging benign flow with toxicity**  
   Toxicity is `|spot - pHat|/pHat`; pHat updates only when return is within the adaptive gate. In choppy or mean-reverting markets, spot often deviates from pHat, so `toxEma` stays elevated. The add-on `TOX_COEF * toxEma + TOX_QUAD * toxEma^2` then applies on *every* trade. Retail flow that causes normal bounce gets charged as if toxic → less volume and lower LP edge.

2. **Trade-aligned boost is too broad**  
   `tradeAligned = (isBuy && spot >= oldPHat) || (!isBuy && spot < oldPHat)` — in a random walk about half of trades satisfy this by chance. The boost is applied on the *next* period’s fee for that side, so we often raise fee on the side that will then get hit by reverting (benign) flow, hurting LPs.

3. **Higher fee cap (150 bps) with additive toxicity**  
   Cap was raised from 100 to 150 bps so toxicity could add. When base+vol+imb+tox pushes fee into 100–150 bps, we charge more than v3. Higher fees reduce volume and can shift flow to arbitrage; net LP PnL can drop even if we “capture more” per toxic trade.

4. **Double penalty for the same regime**  
   We add both (a) a base toxicity term (linear + quadratic) and (b) a trade-aligned boost. For the same move we may over-price and then face mean reversion on the boosted side, losing the next trade.

5. **pHat lags in trends**  
   In trending markets, spot repeatedly leaves the gate, so pHat updates rarely. `tox` stays high for many steps and we charge elevated toxicity fees for a long time, often on subsequent benign or reverting flow.

**Summary:** v4 loses vs v3 because it over-applies toxicity (and boost) to benign flow and uses a higher cap, reducing volume and mis-pricing the reverting side.

---

## Step 2 — Adversarial Exploitation

1. **Fade the boosted side**  
   After a trade-aligned buy we raise bid. If the next flow is mean-reverting (sells), the AMM pays on the side we just made more expensive; arb can structure flow to trade when we’ve over-raised one side.

2. **Volume reduction**  
   Higher average fees (toxicity + 150 bps cap) reduce optimal size for retail; less volume → less total fee capture.

3. **Gate and toxicity gaming**  
   One large move pushes spot far from pHat; subsequent small trades within the gate pull pHat toward the new level while tox remains high. Adversary can keep toxicity premium elevated without being clearly “toxic” every step.

---

## Step 3 — Failure Modes

| Regime              | v4 behavior |
|--------------------|-------------|
| Choppy / mean-revert | tox high; over-charge; trade-aligned often true by chance → boost on wrong side. |
| Trending           | pHat lags; tox high for many steps; over-charge on benign follow-up flow. |
| Low vol            | Gate tight; pHat may track spot; tox can be low (ok) or under-state real toxicity. |
| High vol           | Toxicity add-on and boost can help, but if cap and coefs are too high, volume drop dominates. |

---

## Step 4 — New Strategy Ideas (to Beat v3)

**A. Revert cap and soften toxicity (conservative v4)**  
- Set `MAX_FEE_CAP = 100e14` again.  
- Reduce `TOX_COEF` and `TOX_QUAD_COEF` so toxicity is a modest add-on (e.g. 25 bps linear, 60 bps quad).  
- **Addresses:** Over-charging and volume loss from 150 bps and strong tox terms.

**B. Thresholded trade-aligned boost**  
- Apply boost only when `toxEma >= TOX_THRESHOLD` (e.g. 1% or 2% in WAD).  
- **Addresses:** Boost applied on benign “aligned” trades by chance.

**C. Remove trade-aligned boost**  
- Keep only the base toxicity add-on (linear + quadratic), drop the boost.  
- **Addresses:** Double penalty and mis-pricing of the reverting side.

**D. Asymmetry on toxicity (inventory-based)**  
- Add toxicity premium mainly to the *vulnerable* side (rich in Y → more tox on bid; else on ask) instead of the side that was just hit.  
- **Addresses:** Raising the wrong side after a trade.

---

## Step 5 — Formulas & Pseudocode

**A. Conservative v4**
```
MAX_FEE_CAP = 100e14
TOX_COEF = 25e14    // was 50
TOX_QUAD_COEF = 60e14  // was 120
// optional: TRADE_TOX_BOOST = 0 or thresholded
```

**B. Thresholded boost**
```
TOX_THRESHOLD = 1e16   // 1% in WAD
if (tradeAligned && toxEma >= TOX_THRESHOLD) {
    boost = TRADE_TOX_BOOST * toxEma
    // apply to bid or ask
}
```

**C. Drop boost**
```
// Delete the "Trade-aligned toxicity boost" block; keep only rawFee toxicity add-on.
```

**D. Inventory-toxicity asymmetry**
```
// After baseFee and asymmetry:
toxPremium = TOX_COEF * toxEma + TOX_QUAD * toxEma^2  // already in rawFee
// Optional: add extra toxPremium only to vulnerable side (e.g. richInY -> bidFee += extraTox)
```

---

## Step 6 — Simulation Blueprint

- **Inputs:** Same 1000 sims as current.  
- **Metrics:** Edge (primary), fee capture ratio, any volatility split if available.  
- **Scenarios:**  
  - Baseline: v3 (374.54), current v4 (342.07).  
  - v4-A: cap 100 bps, TOX_COEF 25e14, TOX_QUAD 60e14.  
  - v4-B: v4-A + thresholded boost (toxEma >= 1%).  
  - v4-C: v4-A + no boost.  
- **Criteria:** Edge > 374.54; prefer stability (no large drawdown increase).

---

## Step 7 — Recommendation

**Priority order:**

1. **Revert cap to 100 bps** and **reduce toxicity coefficients** (Concept A: TOX_COEF 25e14, TOX_QUAD 60e14). Re-run 1000 sims. If Edge recovers toward or above 374.54, the regression was mainly over-charging and cap.

2. **Threshold the trade-aligned boost** (Concept B): apply boost only when `toxEma >= 1e16` (1%). If Edge improves further, keep it; else try removing the boost (Concept C).

3. **If still below v3,** try **inventory-based toxicity asymmetry** (Concept D) instead of trade-aligned boost, or soften the gate (e.g. higher MIN_GATE or lower GATE_SIGMA_MULT) so pHat tracks spot more and tox is spikier rather than persistently high.

**Concrete next step:** Implement v4-conservative (100 bps cap, lower TOX_COEF/TOX_QUAD, optional thresholded or removed boost), then run `amm-match run contracts/src/VIAFStrategy.sol --simulations 1000` and compare Edge to 374.54.
