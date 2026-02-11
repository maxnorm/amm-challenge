# Constant Tuning Plan for V34 (AMM Fee Designer)

**Baseline:** SapientStrategyV34, Edge = 524.63. Goal: close gap to ~526 via constant fine-tuning only (no new logic).

---

## Step 1 — Why We’re Slightly Behind (Diagnosis)

1. **Fee level vs. flow mix** — The harness rewards a specific trade-off between average fee level and fee *distribution* across regimes. Our constants may be slightly mis-calibrated for the sim’s mix of calm vs. volatile vs. toxic steps.
2. **Tail compression vs. cap hits** — If we compress the tail too much (high TAIL_KNEE / low TAIL_SLOPE_*), we leave money on the table in stressed regimes; if too little, we hit the 10% cap more often and lose flow. Small shifts can move edge.
3. **Toxicity response curvature** — TOX_COEF, TOX_QUAD_COEF, TOX_CUBIC_COEF and SIGMA_TOX_COEF together set how fast fees rise with toxicity. Slight over- or under-response in the mid-tox range can shift edge without changing structure.

---

## Step 2 — Exploit / Failure Modes (Relevant to Tuning)

- **Arbitrage in calm regimes:** If BASE or lambda/flow terms are too high, we lose flow when volatility is low; if too low, we under-earn.
- **Toxic flow under-pricing:** If tox terms are too low, we don’t charge enough when spot deviates from pHat; if too high, we over-charge and lose volume.
- **Direction skew mis-calibration:** DIR_COEF / DIR_TOX_COEF / STALE_* control bid–ask spread under inventory pressure. Wrong balance can lose on rebalancing flow or on informed flow.

---

## Step 3 — Constants to Tune (Grouped by Role)

| Group | Constants | Role | Tuning direction (to try) |
|-------|-----------|------|---------------------------|
| **Base & volatility** | BASE_FEE, SIGMA_COEF | Floor and vol sensitivity | BASE ±1 BPS; SIGMA_COEF ±5% |
| **Flow / activity** | LAMBDA_COEF, FLOW_SIZE_COEF, ACT_COEF | Response to arrival rate and size | ±5–10% one at a time |
| **Toxicity** | TOX_COEF, TOX_QUAD_COEF, TOX_CUBIC_COEF, SIGMA_TOX_COEF | Linear/quad/cubic tox and σ×tox | ±5–10% one at a time |
| **Direction / stale** | DIR_COEF, DIR_TOX_COEF, STALE_DIR_COEF, STALE_ATTRACT_FRAC | Inventory and stale-price asymmetry | ±5% one at a time |
| **Tail** | TAIL_KNEE, TAIL_SLOPE_PROTECT, TAIL_SLOPE_ATTRACT | Compression above knee, asymmetry | TAIL_KNEE ±50 BPS; slopes ±1% |
| **Decays** | PHAT_ALPHA, TOX_BLEND_DECAY, SIGMA_DECAY | How fast we adapt to new info | ±3–5% (small steps) |
| **Other** | TRADE_TOX_BOOST, GATE_SIGMA_MULT, MIN_GATE | Trade-aligned boost, pHat gate | ±5–10% |

---

## Step 4 — Formulas (V34 Snippet) and Tuning Math

Fee construction in V34 (conceptually):

```
fBase = BASE_FEE + SIGMA_COEF*σ̂ + LAMBDA_COEF*λ̂ + FLOW_SIZE_COEF*(λ̂*sizeHat)
fMid  = fBase + TOX_COEF*tox + TOX_QUAD_COEF*tox² + ACT_COEF*actEma
         + SIGMA_TOX_COEF*σ̂*tox + TOX_CUBIC_COEF*tox³
skew  = DIR_COEF*dirDev + DIR_TOX_COEF*dirDev*tox
bid/ask = fMid ± skew (+ stale shift + trade-tox boost), then tail compress, then clamp
```

**Tuning rule (one constant per version):**

- Pick one constant `C`, current value `C0`.
- New value: `C_new = C0 * (1 + δ)` with `δ ∈ { +0.05, -0.05 }` (or ±0.10 for coefs that are “clearly in the middle”).
- For BPS constants (e.g. BASE_FEE): use additive steps: `C_new = C0 + Δ` with `Δ` e.g. ±1 BPS or ±50 BPS for TAIL_KNEE.
- Run: `amm-match run contracts/src/SapientStrategyVXX.sol --simulations 1000`.
- If edge > 524.63, keep and try another constant from the same or next group; if edge < 524.63, revert and try the opposite sign or next constant.

**Pseudocode (per run):**

```
1. Copy V34 → new file SapientStrategyV42.sol (or next version).
2. Change exactly one constant:
   - either C_new = C0 * 1.05 or C0 * 0.95 (for WAD coefs),
   - or C_new = C0 + 1*BPS or C0 - 1*BPS (for BASE_FEE),
   - or C_new = C0 + 50*BPS or C0 - 50*BPS (for TAIL_KNEE).
3. amm-match run contracts/src/SapientStrategyV42.sol --simulations 1000
4. Record edge; if improved, set new baseline and repeat from (1) with another constant.
```

---

## Step 5 — Suggested Order of Tuning (Prioritized)

1. **TAIL_KNEE / TAIL_SLOPE_*** — They directly control how much fee we capture near the cap; small changes often move edge.
2. **TOX_QUAD_COEF and TOX_COEF** — Mid-range toxicity is where most flow lives; curvature here is sensitive.
3. **FLOW_SIZE_COEF and LAMBDA_COEF** — Drive response to busy steps; sim may reward slightly more or less aggressiveness.
4. **SIGMA_COEF and BASE_FEE** — Overall level; try BASE_FEE ±1 BPS then SIGMA_COEF ±5%.
5. **DIR_COEF, DIR_TOX_COEF, STALE_DIR_COEF** — Asymmetry; one at a time, ±5%.
6. **Decays (PHAT_ALPHA, TOX_BLEND_DECAY)** — Slower/faster adaptation; ±3% first.

---

## Step 6 — Simulation Blueprint for Tuning

- **Input:** Same as current (amm-match, 1000 sims).
- **Metric:** Edge (primary). Optionally log avg fee, cap-hit rate, or fee-by-regime if the harness exposes them.
- **Scenarios:** No need to change; the default 1000-run distribution is the benchmark.
- **Criteria:**
  - Improvement: edge > 524.63. Adopt as new baseline and document in `/docs`.
  - Regression: edge < 524.63. Revert constant and try next candidate or opposite sign.
  - Tie (524.63): treat as no improvement; try next constant.

---

## Step 7 — Recommendation

- **First moves:** Create **V42** with a single change: e.g. **TAIL_KNEE** from 500 BPS to **450 BPS** (less compression below knee → more fee above). Run 1000 sims. If edge improves, try **TAIL_SLOPE_PROTECT** 0.93 → 0.94 (steeper protect side). If TAIL_KNEE 450 regresses, try **550 BPS** instead.
- **Next:** **TOX_QUAD_COEF** 11700 → 12300 BPS (+5%) in a new version; if that regresses, try 11100 BPS (−5%). Then **FLOW_SIZE_COEF** ±5%.
- **Rule:** One constant per version, small steps (±5–10% or ±1 BPS for BASE_FEE), always compare to 524.63 (or current best). Document each run in `/docs` with version, constant changed, value, and edge.

This keeps the strategy structure fixed and systematically explores the constant manifold for a better edge.
