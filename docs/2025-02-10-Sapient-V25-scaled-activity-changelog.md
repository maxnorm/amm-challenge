# Sapient V25 — Scaled activity coefficients

**Date:** 2025-02-10  
**Purpose:** Recover from V24 edge collapse (40.30) by scaling down FLOW_SIZE_COEF and ACT_COEF so activity adds ~5–20 bps total instead of hundreds. Logic unchanged from V24; only the two activity coefficients are reduced.

**Reference:** [2025-02-10-V24-edge-40-investigation.md](2025-02-10-V24-edge-40-investigation.md).

---

## 1. Changes vs V24

| Constant | V24 (YQ) | V25 (scaled) | Approx. effect |
|----------|----------|--------------|----------------|
| LAMBDA_COEF | 12e14 | 12e14 | unchanged (~1 bps) |
| FLOW_SIZE_COEF | 4842e14 | **300e14** | ~16× smaller; init flowSize ~5 bps |
| ACT_COEF | 91843e14 | **500e14** | ~184× smaller; 1% actEma → 5 bps |

**Target:** Activity (lambda + flowSize + actEma) adds on the order of **~6–20 bps** (init ~6 bps; with actEma 1–2%, up to ~16 bps) so the rest of the fee (sigma, imb, vol, symTox, dir, surge, tail) can still differentiate and we don’t peg at 75 bps on every trade.

---

## 2. How to run and compare

From `amm-challenge`:

```bash
amm-match run contracts/src/SapientStrategyV25.sol --simulations 1000
```

Compare edge to:

- **V23** (~380) — no activity in base
- **V24** (40.30) — full YQ activity coefs
- **V25** — scaled activity; expect edge to recover toward V23, and possibly improve if activity helps in this sim

---

## 3. Result: V25 edge stayed 40.30

V25 (scaled FLOW_SIZE + ACT only) gave **Edge: 40.30** — same as V24. **LAMBDA_COEF** was still 12e14, so when lambdaHat → 5 (many trades per step), we add **60 bps** from lambda alone and stay pegged at 75 bps. So we need to scale **LAMBDA_COEF** too → **V26** (LAMBDA_COEF = 2e14, max 10 bps from lambda).

---

## 4. If edge recovers (V26 or later)

- If **≈ V23 (~380):** Activity at this scale is neutral; try slightly higher coefs for a small gain.
- If **> V23:** Scaled activity helps; tune further.
- If **< V23 but > 40:** Activity still hurts; consider even smaller coefs or a cap on total activity add.
