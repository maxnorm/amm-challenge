# Sapient v5 — Same Edge as v4: Diagnosis & Redesign (AMM Fee Designer)

**Observed:** V5 (directionality + inventory-tox + surge) **Edge 374.54** — identical to V4 (toxicity + imbalance-floor + asym).  
**Goal:** Diagnose why V5 did not improve edge and propose a V6 that breaks above 374.54.

---

## Step 1 — Loss Diagnosis (Why V5 = V4 Edge)

### Mechanical reasons the two strategies can net the same

1. **Base fee in V5 is strictly lower (no symmetric toxicity)**  
   In V4, `rawFee = baseFee(vol, imb) + TOX_COEF*toxEma + TOX_QUAD*toxEma²` so both sides get a higher base. In V5 we removed that: rawFee = baseFee(vol, imb) only, then we add tox only to the *vulnerable* side. So in V5 the **non-vulnerable side is always just baseFee**. That side is hit by arb when spot > fair (arb sells X → bid) or spot < fair (arb buys X → ask). If that side is often hit, we’re charging less there than V4 did → **we give more edge to arb** on that side. The extra we charge on the vulnerable side (tox + 60% + dir + surge) can exactly compensate in expectation, yielding the same average edge.

2. **Directionality is small and noisy**  
   `dirPremium = min(ret * 200e14, 20e14)` (cap 20 bps). In a random walk, spot ≥ pHat about half the time, so we add 20 bps to ask half the time and to bid half the time. Net effect on edge is small. Moreover, **directionality uses pHat**, which lags in trends; when we’re wrong we’re not penalized much (only up to 20 bps), and when we’re right the cap limits gain.

3. **Surge fires only when ret > gate**  
   Gate = max(sigmaHat × 10, 3%). So surge (15 bps) applies only on large moves. If such moves are rare, surge adds little to total edge. If they’re common, both strategies might already be near the 100 bps cap on that side, so the extra 15 bps gets clamped away.

4. **Trade-aligned boost removed**  
   V4 added up to 18 bps × toxEma on the “aligned” side when toxEma ≥ 1%. That sometimes over-charged benign flow (hurting volume) but sometimes captured toxic flow. In V5 we removed it. So we **lost** some capture on toxic flow and **gained** volume on benign flow; the two effects can cancel.

**Summary:** V5 and V4 differ in where fees are applied (V5: toxicity and extra only on one side; V4: symmetric tox + trade-aligned boost). The simulation’s mix of arb vs retail and of “which side gets hit” can make these differences **average out** to the same edge. So we’re not “losing” in a simple sense — we’re **neutral** relative to V4. To **beat** 374.54 we need a change that is **unambiguously positive** in this setup (e.g. charge more when arb hits, without losing more retail than we gain).

---

## Step 2 — Adversarial Exploitation (if we stay at V5)

1. **Arb prefers the non-vulnerable side**  
   In V5 the non-vulnerable side has no toxicity and no asymmetry. When that side is the one that’s mispriced (e.g. spot > fair, arb sells X → bid), we charge only baseFee. Arb’s profit is higher than if we had a toxicity or directional premium on that side.

2. **Directionality can be faded**  
   We raise ask when spot ≥ pHat. If the next move is mean-reversion (spot drops), the next trade might be arb buying X (ask). We’ve raised ask, which is good. But if the next move is continuation, arb might sell X (bid). We didn’t raise bid, so we under-charge. So directionality helps only when the next move is in the same direction as (spot - pHat).

3. **Surge is one-shot**  
   A single large toxic trade pays at most base + dir + 15 bps surge. If the move is very profitable for the arb, 15 bps may be too small to capture much of it.

---

## Step 3 — Failure Modes

| Regime / condition     | V5 limitation                          | Effect                          |
|------------------------|----------------------------------------|---------------------------------|
| High arb on “cheap” side | Non-vulnerable side = baseFee only     | More arb profit → lower edge    |
| Rare gate breach       | Surge rarely applies                   | Little extra capture            |
| Random walk            | Directionality ~50/50 right/wrong     | Small net gain                  |
| High vol, both sides   | One side gets tox+asy, other base      | Asymmetric capture              |

---

## Step 4 — New Strategy Ideas (to Break Above 374.54)

**A. Restore a small symmetric toxicity to base**  
Add back a **modest** toxicity term to rawFee (e.g. half of V4: 12 bps linear, 30 bps quad) so the **non-vulnerable side** is not as cheap. We keep toxicity-on-vulnerable on top. Effect: we charge more on both sides when toxEma is high, reducing arb profit on the cheap side without fully reverting to V4’s over-charge.

**B. Stronger directionality**  
- Apply directionality only when **ret > threshold** (e.g. 0.5% in WAD) so we add premium only when we’re confident the move is meaningful.  
- Increase cap (e.g. 25–30 bps) so when we’re right we capture more.

**C. Larger surge on gate breach**  
Raise SURGE_BPS from 15 to 25 bps when ret > gate. Captures more from the large toxic move; if we’re already near cap we still clamp.

**D. Volatility-squared (LVR-style) term**  
Add a small term to rawFee proportional to sigmaHat² (capped) so in high-vol regimes the no-trade region widens and we lose less to arb. Formula: `rawFee += min(K_VOL2 * sigmaHat², CAP_VOL2)`.

**E. Asymmetry on the “next arb” side (no oracle)**  
We don’t have fair price. We can proxy “likely next arb direction” by: if spot < pHat (price below our fair estimate), next arb might buy X (ask); if spot > pHat, next arb might sell X (bid). So we already do this with directionality. To strengthen: **only** add directionality when ret is above a threshold (Idea B) and use a higher coefficient.

---

## Step 5 — Formulas & Pseudocode

**A. Small symmetric toxicity**
```
SYM_TOX_COEF = 12e14   // 12 bps per unit tox
SYM_TOX_QUAD = 30e14   // 30 bps per tox²
rawFee = baseFee(vol, imb) + SYM_TOX_COEF*toxEma + SYM_TOX_QUAD*toxEma²
// then floor, decay, cap; then add vulnerable-side tox + asym + dir + surge as in V5
```

**B. Thresholded, stronger directionality**
```
DIR_RET_THRESHOLD = 5e15   // 0.5% in WAD
CAP_DIR_BPS = 30e14        // 30 bps
if (ret >= DIR_RET_THRESHOLD) {
  dirPremium = min(ret * DIR_BPS_PER_UNIT_RET, CAP_DIR_BPS)
  if (spot >= pHat) askFee += dirPremium; else bidFee += dirPremium
}
```

**C. Larger surge**
```
SURGE_BPS = 25e14   // 25 bps when ret > gate
```

**D. Vol-squared (optional)**
```
K_VOL2 = 1e18      // scaling
CAP_VOL2 = 20e14   // cap 20 bps
rawFee += min(_wmul(K_VOL2, _wmul(sigmaHat, sigmaHat)), CAP_VOL2)
```

---

## Step 6 — Simulation Blueprint

- **Inputs:** Same 1000 sims, same baseline.  
- **Metrics:** Edge (primary), win rate vs baseline if reported, average fees (bid/ask).  
- **Scenarios:**  
  - V6-A: V5 + small symmetric tox (A).  
  - V6-B: V5 + thresholded stronger directionality (B).  
  - V6-C: V5 + larger surge (C).  
  - V6-full: A + B + C (and optionally D).  
- **Criteria:** Edge > 374.54; prefer stability (similar or better variance across seeds).

---

## Step 7 — Recommendation

**Priority for V6:**

1. **Restore small symmetric toxicity (A)** — Half of V4’s tox (12 bps linear, 30 bps quad) in rawFee. This raises the floor on the non-vulnerable side so we don’t leave as much on the table when arb hits that side.  
2. **Stronger, thresholded directionality (B)** — Apply dirPremium only when ret ≥ 0.5%, and cap at 30 bps. Reduces noise and increases capture when we’re confident.  
3. **Larger surge (C)** — SURGE_BPS = 25e14 when ret > gate.

**Implementation:** `amm-challenge/contracts/src/VIAFStrategyV6.sol` with the same structure as V5, plus:
- rawFee includes `SYM_TOX_COEF*toxEma + SYM_TOX_QUAD*toxEma²` (12 bps linear, 30 bps quad).
- Directionality: only if `ret >= DIR_RET_THRESHOLD` (0.5%), and `CAP_DIR_BPS = 30e14`.
- `SURGE_BPS = 25e14`.

Run (from `amm-challenge`):  
`amm-match run contracts/src/VIAFStrategyV6.sol --simulations 1000`  
Compare Edge to 374.54.
