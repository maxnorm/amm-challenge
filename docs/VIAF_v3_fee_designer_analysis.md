# AMM Fee Strategy Designer — VIAF v3 Analysis

**Strategy:** VIAF v3 (imbalance-floor + strong asym)  
**Current edge (1000 sims):** 374.54  
**Scope:** Diagnosis, exploit vectors, failure modes, new ideas, formulas, simulation blueprint, recommendation.

---

## Step 1 — Loss Diagnosis

### Mechanical weaknesses

1. **Volatility is backward-looking and per-step only**  
   Volatility is updated as `vol = α * priceCh + (1-α) * oldVol` with `α = 0.25`, and `priceCh` is the single-step absolute return. So:
   - The strategy reacts to *past* volatility; it does not anticipate regime shifts.
   - A single large trade dominates the next fee; there is no notion of “recent variance” or multi-step volatility, so fees can overshoot or undershoot around regime changes.
   - **Effect:** Lag in adapting to price movement — fees are sticky and can stay high after vol drops or stay low when vol has already spiked.

2. **Time-decay is coarse and floor-tied**  
   Decay is applied as `decay = steps * (1 - DECAY_FACTOR)` with `steps = timestamp - lastTs`. So:
   - One “step” of no trade and one step of 100 no-trades are treated very differently; the decay formula is linear in steps and can overshoot (capped at 1).
   - Decay pulls fee toward `imbFloor`, which itself depends on current imbalance. So when imbalance is high, the floor is high and fees cannot decay to a low level even in quiet periods — **inventory risk is not “released” when flow stops**.
   - **Effect:** High effective inventory risk and slow mean-reversion of fees; LPs may over-charge in calm periods or under-charge when imbalance persists.

3. **Single-rule asymmetry is purely inventory-based**  
   Asymmetry is “rich in Y → raise bid (AMM buys X); else raise ask.” So:
   - The strategy does not use *direction of last trade* or *flow toxicity*. A one-sided flow (e.g. informed selling of X) repeatedly pushes imbalance; the fee on the “vulnerable” side goes up, but the *other* side stays at base. Arbitrageurs can still choose the cheaper side when the move is over.
   - No distinction between “inventory drift from noise” vs “sustained toxic flow” — same 60% bump.
   - **Effect:** Susceptibility to arbitrage and toxic flow; predictable fee schedule by side.

### Summary

Losses/underperformance likely stem from: **lag in adapting to price/vol regime**, **inventory-driven floor preventing fee decay when flow stops**, and **one-dimensional asymmetry** that does not adapt to flow direction or toxicity, increasing susceptibility to arbitrage and toxic flow.

---

## Step 2 — Adversarial Exploitation

1. **Front-running large orders**  
   Fee is updated *after* the trade. A bot can observe a large pending order (e.g. via mempool or flow), trade on the cheap side first (before fee rises), then let the large order hit the newly raised fee. The strategy raises the “vulnerable” side (e.g. bid when rich in Y) but does not raise the side that is about to be hit by the large flow — so the first mover gets low fee, the AMM gets adverse selection.

2. **Imbalance + decay gaming**  
   After building imbalance (e.g. sell X until pool is rich in X), the fee on the ask (AMM sells X) goes up. The attacker stops trading. Decay is toward `imbFloor`, which is still high because imbalance is still high. So fee stays elevated. Attacker can then *reverse* trade in smaller chunks: first trades get the elevated fee, then as imbalance falls, `imbFloor` falls and fee can drop. Alternatively, a *second* actor can arb the now-misaligned pool at the still-high fee. So the first actor locks in a favorable state and the second can exploit the slow decay.

3. **Volatility spike then flatten**  
   One large trade creates a big `priceCh` and bumps `vol` and thus fee. Then quiet period: fee decays toward `imbFloor`. If imbalance is low, floor is near BASE_FEE and fee decays quickly. So an attacker can: create one big trade (or a few) to spike vol and fee, wait for decay (or for other flow to reduce vol), then trade at the temporarily low fee — **volatility is easy to trigger and then “forget,” so the strategy gives cheap execution after a self-induced vol spike**.

---

## Step 3 — Failure Mode Identification

| Regime / condition | Structural limitation | Effect |
|--------------------|------------------------|--------|
| **High volatility, fast reversals** | Vol is EWMA of single-step return; no distinction between sustained vol and one-off spike. Decay is step-based and floor-dependent. | Fee overshoots then decays; reversals can happen at wrong fee level. LP PnL and fee capture suboptimal. |
| **Low liquidity / thin book** | Same formula; no explicit liquidity or spread term. Imbalance can swing sharply with small trades. | Large price impact and imbalance moves; fee may be too low for the risk taken. |
| **One-sided toxic flow** | Asymmetry only by inventory (rich in Y vs X), not by trade direction or toxicity. | Informed flow repeatedly hits one side; fee on that side rises but the *next* trade can still be the same direction at a fee that was set for the *previous* state. |
| **Calm after imbalance** | Decay toward `imbFloor`; when imbalance is high, floor is high. | Fee cannot fall to base in calm periods; LPs may over-earn from noise traders and under-compensate when real risk appears. |
| **Rapid mean-reversion** | No notion of “recent direction” or momentum; only current reserves and one-step price change. | Fee does not stay elevated when price mean-reverts; arbs can trade round-trip at favorable average fee. |

---

## Step 4 — New Strategy Ideas

### Idea A — Volatility regime + inventory floor (refined)

- **Core:** Keep imbalance floor and asymmetry, but replace single-step vol with a **short-term variance proxy** (e.g. sum of squared returns over last N steps, or second EWMA of squared returns). Use **two vol regimes**: “low” vs “elevated”; fee jumps when crossing a threshold instead of scaling linearly with a noisy one-step vol.
- **Addresses:** Lag in adapting to price movement; overshoot/undershoot from one large trade; slow reaction to real regime change.
- **Parameters:** N or EWMA half-life for variance; regime threshold; base and elevated fee (or multipliers).

### Idea B — Direction- and toxicity-aware asymmetry

- **Core:** Keep current asymmetry as one component, but add a **direction term**: e.g. if last trade was “AMM bought X” (trader sold X), temporarily raise the *bid* (next AMM-buy-X) more than the ask, and vice versa. Optionally weight by trade size so large trades move the “last direction” more. No need for full toxicity score — just “last trade direction + size” as a proxy.
- **Addresses:** One-dimensional asymmetry; susceptibility to repeated one-sided flow; arbitrage on the “cheap” side.
- **Parameters:** Asymmetry weight for “inventory” vs “last direction”; size scaling; decay of “last direction” over steps.

### Idea C — Decay toward base with imbalance cap

- **Core:** Decay fee toward **BASE_FEE** (or a low floor), not toward `imbFloor`. Separately, **cap** the *maximum* fee by imbalance (e.g. fee cannot exceed `BASE_FEE + imbalance * FLOOR_IMB_SCALE`), so when imbalanced you can still raise fee, but when flow stops the fee is allowed to decay to base. So: “cap by imbalance, decay to base.”
- **Addresses:** Inventory floor preventing fee decay; slow mean-reversion; over-charging in calm periods.
- **Parameters:** Decay rate; cap formula (e.g. same FLOOR_IMB_SCALE as current floor).

---

## Step 5 — Formulas & Pseudocode

### Idea A — Regime volatility

**Definitions**

- `r_t = (spot_t - spot_{t-1}) / spot_{t-1}` (single-step return).
- `var_t = β * r_t^2 + (1 - β) * var_{t-1}` (EWMA variance), e.g. β = 0.3.
- `σ_t = sqrt(var_t)` (or use `var_t` directly to avoid sqrt on-chain).
- Regime: `elevated = (var_t > THRESHOLD_VAR)`.

**Fee**

- `vol_mult = elevated ? HIGH_MULT : 1`.
- `rawFee = BASE_FEE * (1 + K_IMB * imbalance) * vol_mult`.
- Then apply same imbalance floor and asymmetry as now (optional).

**Edge cases**

- First step: `var_0 = 0` → not elevated.
- Cap `vol_mult` and clamp final fee to [0, MAX_FEE_CAP].

---

### Idea B — Direction-aware asymmetry

**Definitions**

- `lastBuyX = true` if last trade was AMM bought X (trader sold X), else false.
- `lastSize = amountX` (or amountY in same unit) of last trade.
- Optional: `dirWeight = min(1, lastSize / SIZE_REF)` so large trades matter more.

**Asymmetry**

- Base fee from existing formula: `baseFee`.
- Inventory asymmetry as now: e.g. `richInY → bid = baseFee * (1 + ASYMM_IMB)`, ask = baseFee (and mirror).
- Direction bump: if `lastBuyX`, `bidFee *= (1 + ASYMM_DIR * dirWeight)`; else `askFee *= (1 + ASYMM_DIR * dirWeight)`.
- Combine: e.g. multiplicative on the side that is both “inventory-vulnerable” and “direction-vulnerable”; additive or multiplicative when only one applies (design choice).
- Decay: after T steps with no trade, reduce or zero out `lastSize` (or decay `dirWeight`) so direction effect fades.

**Constraints**

- Keep total fee ≤ MAX_FEE_CAP; avoid double-asymmetry blowing past cap.

---

### Idea C — Decay to base, cap by imbalance

**Current (conceptually)**

- `floor = BASE_FEE + imbalance * FLOOR_IMB_SCALE`
- Decay: `rawFee → floor + (1 - decay)(rawFee - floor)`

**New**

- `cap = BASE_FEE + imbalance * FLOOR_IMB_SCALE` (same as current floor; interpret as max when imbalanced).
- Decay: `rawFee → BASE_FEE + (1 - decay)(rawFee - BASE_FEE)` (decay toward BASE_FEE).
- After decay: `fee = min(fee, cap)` so when imbalanced you still cannot exceed the cap, but when flow stops fee can go down to BASE_FEE.

**Pseudocode**

```
rawFee = baseFee  // from vol + imbalance formula
cap = BASE_FEE + imbalance * FLOOR_IMB_SCALE
if trade.timestamp > lastTs && lastTs > 0:
  steps = trade.timestamp - lastTs
  decay = min(1, steps * (1 - DECAY_FACTOR))
  rawFee = BASE_FEE + (1 - decay) * (rawFee - BASE_FEE)
fee = min(rawFee, cap)
fee = min(fee, MAX_FEE_CAP)
// then apply asymmetry
```

---

## Step 6 — Simulation Blueprint

### Data inputs

- Order flow (or simulated trades): direction, size, timestamp.
- Reserve path: reserveX, reserveY after each trade.
- Optional: “informed” or “toxic” flag per trade (if simulator provides it).

### Metrics

| Metric | Purpose |
|--------|--------|
| LP PnL | Primary; compare to baseline and current VIAF v3. |
| Fee capture ratio | Fees collected / volume; ensure not over-penalizing flow. |
| Trader surplus | Welfare; avoid collapsing surplus with too-high fees. |
| Volatility sensitivity | PnL in high-vol vs low-vol segments; check regime behavior. |
| Drawdown / max DD | Risk; avoid strategies that occasionally blow up. |
| Asymmetry usage | % of volume on elevated vs base side; sanity check. |

### Scenarios

1. **Regime split:** Label steps by vol (e.g. low / med / high by percentile of `var_t` or |r|). Report LP PnL and fee capture per regime.
2. **Toxic flow:** Runs where a subset of trades is “informed” (e.g. trade before price moves). Compare fee earned on toxic vs non-toxic.
3. **Imbalance stress:** Initial large one-sided flow, then no trade for many steps. Compare fee path and PnL vs current (decay-to-floor) and decay-to-base.
4. **Arb / front-run:** Agent that can trade before/after large orders. Compare execution cost and LP PnL vs no arb.

### Evaluation criteria

- Beat current VIAF v3 edge (374.54) in same 1000-run setup.
- Improve or maintain LP PnL in high-vol and toxic-flow scenarios.
- No unacceptable drop in trader surplus (e.g. cap at X% reduction).

---

## Step 7 — Recommendation

**Priority order**

1. **Idea C (decay to base, cap by imbalance)** — Easiest change: same formula, only decay target and final min with cap. Low implementation risk; directly addresses “fee stuck high when flow stops.” Run same 1000 sims and compare edge and fee path after imbalance.
2. **Idea A (regime volatility)** — Medium effort: one more slot for `var_t`, threshold, and regime multiplier. Addresses vol lag and one-step noise. Test with same simulator; add regime buckets to the blueprint.
3. **Idea B (direction-aware asymmetry)** — Requires storing “last trade direction” and size (or a decayed proxy). Higher complexity; do after C and A if C/A show clear gain.

**Recommended next step**

Implement **Idea C** in `VIAFStrategy.sol` (decay toward `BASE_FEE`, then `fee = min(fee, imbFloor)` so cap = current floor). Re-run `amm-match run contracts/src/VIAFStrategy.sol --simulations 1000` and compare edge and, if available, per-regime PnL. If edge and stability improve, then add **Idea A** (regime vol) and optionally **Idea B** (direction asymmetry) in a second iteration.

---

*Document produced by AMM Fee Strategy Designer skill for VIAF v3.*
