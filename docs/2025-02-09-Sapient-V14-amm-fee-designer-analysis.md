# Sapient V14 — AMM Fee Designer Analysis (Edge 380.13 ≈ V7)

**Date:** 2025-02-09  
**Context:** V14 (low base + additive) ran 1000 sims → **Edge 380.13**. V7 (multiplicative base) → 380.14. The rewrite did not improve edge.  
**Skill:** amm-fee-designer — diagnosis, exploit vectors, failure modes, new ideas, formulas, simulation plan, recommendation.

---

## Step 1 — Loss Diagnosis (Why V14 Did Not Improve)

V14 is not “losing” versus V7; it is **neutral** (380.13 vs 380.14). The diagnosis is why the structural change did **not** move the needle.

### Mechanical reasons the additive base did not help

1. **Effective fee level is similar across regimes**  
   V7: base = 35 bps × (1 + K_VOL×vol)(1 + K_IMB×imb) + symTox. With typical vol/imb (e.g. 0.5–2%), the product stays in a range that, after floor and symTox, often lands in the high 20s–40s bps. V14: base = 8 + σ×15 + imb×100e14 + vol×15 + symTox. With sigma/vol in WAD ~1e16–2e16 and imbalance ~0.1–0.3, the additive terms also land in a similar range. So **average fee level and sensitivity** are close; the sim’s routing and arb behavior may be almost indifferent between the two.

2. **Downstream pipeline is identical and dominates in stressed regimes**  
   After base, both V7 and V14 apply the same tox premium (linear + quad), 60% asym, dir, surge, and size bump, then cap at 75 bps. In regimes where edge is made or lost (large moves, high tox), the **cap and these add-ons** bind. The difference between multiplicative and additive base is then a few bps before cap; the binding constraint is still the **75 bps cap** and the **same dir/surge/size logic**, so the two bases produce similar outcomes.

3. **Floor and decay are aligned**  
   Both use an imbalance floor and time decay toward that floor. V14 floor = BASE_LOW + FLOOR_IMB_SCALE×imb (500e14 same as V7). So in calm/stale regimes both strategies decay toward a similar floor; no structural advantage for V14 there.

4. **No new information or levers**  
   V14 did not add pImplied, first-in-step, tail compression, or activity terms. So we did not give the strategy new ways to discriminate toxic vs benign flow or to charge more in the worst regimes without overcharging in calm ones. The additive form alone does not change that.

**Summary:** The additive base is a different **form** (linear in sigma/imb/vol) but, at current tuning, produces similar **levels and dynamics** to V7. The 75 bps cap and identical downstream pipeline mean the strategy is still constrained in the same way. To improve edge we need either (a) changes that **shift** effective fees (e.g. lower in calm, higher in stress) in a way the sim rewards, or (b) **new levers** (tail compression, first-in-step, pImplied, cap raise, or activity with different design/tuning).

---

## Step 2 — Adversarial Exploitation (Still Relevant)

These apply to both V7 and V14; they explain the **ceiling** at ~380, not the V14 vs V7 tie.

1. **Cap arbitrage**  
   When true fee would exceed 75 bps we output 75. Arb keeps the margin we do not charge. Any strategy that shares this hard cap is exploitable the same way.

2. **Fade surge / directionality**  
   After a large move we add surge to one side; the other side is cheaper. Arb can trade the reversion at a discount. Dir/surge logic is unchanged in V14.

3. **Retail routing**  
   If our fee is often above the 30 bps normalizer in calm regimes (e.g. floor or base still >30 bps), retail routes away and we see more toxic flow on average. V14’s low base (8 bps) was meant to help here, but the floor (BASE_LOW + 500e14×imb) can still pull effective fee above 30 bps for non-trivial imbalance, so the benefit may be small.

4. **pHat lag and single alpha**  
   We update pHat with spot (no pImplied) and one alpha; sigma updates every trade. In multi-trade steps, a bot can move our quote then fade; we have no first-in-step logic to reduce that.

---

## Step 3 — Failure Modes

| Regime / condition       | Limitation (V7 and V14)              | Effect |
|--------------------------|--------------------------------------|--------|
| Near 75 bps cap          | Hard clip                             | Marginal value of surge/size/dir lost; arb keeps excess |
| Calm, low vol/imb        | Floor can still exceed 30 bps        | Retail may prefer normalizer; adverse selection |
| High tox / large moves   | Same dir/surge/size, same cap        | No extra structural edge in worst regimes |
| Multi-trade steps        | pHat/sigma every trade, no first-in-step | Noisier, exploitable (move then fade) |
| Post–surge reversion     | Other side cheaper                   | Arb trades reversion at lower fee |

---

## Step 4 — New Strategy Ideas (To Break 380)

### A. Tail compression instead of hard cap

- **Idea:** Above a knee (e.g. 5 bps), fee = knee + slope×(fee − knee); different slopes for protect vs attract; then clamp to MAX_FEE. Preserves gradient so we charge more when raw fee is higher without a hard clip.
- **Addresses:** Cap arbitrage; leaves less margin on the table when we would have quoted above 75 bps.
- **Risk:** More logic; slope tuning matters.

### B. First-in-step pHat/sigma (already in V13)

- **Idea:** Fast alpha for first trade in step, slow alpha for later trades; update sigma only on first-in-step. Reduces noise and exploitability in multi-trade steps.
- **Addresses:** Move-then-fade in same step; aligns with YQ.
- **Risk:** Needs step boundary (timestamp); may need to be combined with a base we like (V7 or V14).

### C. pImplied for pHat/ret (already in V8)

- **Idea:** Use fee-paid to back out implied price; update pHat and ret from that instead of spot. Cleaner signal when last trade was toxic.
- **Addresses:** pHat lag and dir/surge reacting to noisy spot.
- **Risk:** Requires storing prev bid/ask; V8 regressed when bundled with other levers—may need to add alone on V7 or V14.

### D. Cap raise (75 → 85 bps)

- **Idea:** Single constant change to MAX_FEE_CAP. When raw fee would be 80–85 bps we charge it instead of clipping at 75.
- **Addresses:** Cap binding in stressed regimes.
- **Risk:** If sim penalizes high fees (volume loss), edge can drop; needs a quick test.

### E. Regime-dependent base (two regimes)

- **Idea:** If sigma & tox below thresholds → flat low fee (e.g. 28 bps) to compete for retail. Else → full additive (or multiplicative) base + downstream. Explicit switch.
- **Addresses:** Calm vs stressed differentiation; research “two regimes.”
- **Risk:** Threshold and hysteresis tuning; boundary effects.

---

## Step 5 — Formulas & Pseudocode

### A. Tail compression (minimal)

```text
TAIL_KNEE = 5e14   // 5 bps
TAIL_SLOPE_PROTECT = 93e16   // 0.93
TAIL_SLOPE_ATTRACT = 955e15  // 0.955
// After computing bidFee, askFee (with protect/attract determined by dirState or spot vs pHat):
function compressTail(fee, slope) = fee <= TAIL_KNEE ? fee : TAIL_KNEE + (fee - TAIL_KNEE) * slope
bidFee = clamp(compressTail(bidFee, slope_bid))
askFee = clamp(compressTail(askFee, slope_ask))
```

### B. First-in-step pHat/sigma

```text
firstInStep = (stepTradeCount == 0)   // after new-step reset
pAlpha = firstInStep ? PHAT_ALPHA : PHAT_ALPHA_RETAIL  // e.g. 0.26 vs 0.05
if (ret <= gate) pHat = (1 - pAlpha)*pHat + pAlpha*pImplied
if (firstInStep) sigmaHat = SIGMA_DECAY*sigmaHat + (1 - SIGMA_DECAY)*ret
```

### C. Cap raise

```text
MAX_FEE_CAP = 85e14  // was 75e14
```

### D. Two regimes (conceptual)

```text
stressed = (sigmaHat > SIGMA_THRESH) || (toxEma > TOX_THRESH)
if (!stressed) bidFee = askFee = FEE_CALM  // e.g. 28e14
else compute full pipeline (base + tox + dir + surge + size), then clamp or tail compress
```

---

## Step 6 — Simulation Blueprint

- **Inputs:** Same harness, 1000 sims; fixed or varied seeds for comparability.
- **Metrics:** Edge (primary); fee distribution (mean, p90, cap-hit rate) by side; optional: by regime (calm vs active vs high-tox) if harness supports.
- **Scenarios:**
  1. **V14 + tail compression** (V14 base, replace hard cap with tail compression, then clamp 85 bps). Compare edge to V14 (380.13) and V7 (380.14).
  2. **V14 + cap 85 only** (no tail compression). Quick test whether cap was binding.
  3. **V7 + tail compression** (baseline V7, add tail compression). Isolate effect of tail compression.
  4. **V14 + first-in-step** (add stepTradeCount, dual alpha, sigma on first-in-step only). Compare to V14 and to V13 if available.
  5. **V14 + pImplied only** (store prev bid/ask, use pImplied for pHat/ret; no other V8 levers). Test whether cleaner price signal helps on additive base.
- **Criteria:** Edge ≥ 385 as first step; then target 390+; compare to YQ (~520) for remaining gap.

---

## Step 7 — Recommendation

**Prioritized next steps:**

1. **Tail compression (highest leverage)**  
   Add tail compression on top of **V14** (or V7). No new slots; only change how we map raw fee to final fee above the knee. This directly attacks cap arbitrage and may recover 2–5+ points if the sim rewards softer high-fee behavior. Implement as V15 (e.g. V14 + tail compression, clamp 85 bps).

2. **Cap raise (quick test)**  
   Run V14 with MAX_FEE_CAP = 85e14 only. If edge goes up, the 75 bps cap was binding; if it goes down, the sim penalizes higher fees. Informs whether to keep 75 or move to 85 in combination with tail compression.

3. **First-in-step on V14**  
   Add first-in-step pHat/sigma (and optionally pImplied) to V14. Reuse stepTradeCount if we add it for first-in-step; otherwise one extra slot. Reduces multi-trade-step noise and move-then-fade exploit. Can be V15 or V16 after tail compression.

4. **Keep V14 as base**  
   V14 did not regress and gives a cleaner additive structure for future tuning (e.g. regime switch, or different sigma/vol/imb coefs). Prefer iterating from V14 rather than reverting to V7 unless a test shows V7 strictly better in this harness.

**Summary:** V14’s additive base is **neutral** vs V7 because effective fee levels and the binding 75 bps cap (and identical downstream) dominate. The next structural change with the best evidence is **tail compression**; then **cap raise** (test) and **first-in-step** (and/or pImplied) on V14. Document results in `/docs` and version as V15+ per workspace rules.

---

## References

- [2025-02-09-Sapient-what-works-next-big-thing.md](2025-02-09-Sapient-what-works-next-big-thing.md)
- [2025-02-09-Sapient-audit-380-vs-526.md](2025-02-09-Sapient-audit-380-vs-526.md)
- [2025-02-09-Sapient-V14-rewrite-changelog.md](2025-02-09-Sapient-V14-rewrite-changelog.md)
- [docs/plans/2025-02-09-rewrite-low-base-additive-design.md](plans/2025-02-09-rewrite-low-base-additive-design.md)
