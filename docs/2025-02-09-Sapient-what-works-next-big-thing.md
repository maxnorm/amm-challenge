# Sapient: What’s Working, What’s Not, and the Next Big Thing

**Date:** 2025-02-09  
**Context:** V7 → V13 progression; best observed edge ~380 (V7); top score ~526 (YQ ~520).  
**Goal:** Diagnose what works vs what doesn’t, then identify how to drastically improve edge — including a possible rewrite.

---

## 1. Loss Diagnosis — What’s Working vs Not

### Observed edge progression

| Version | Edge (1000 sims) | Main change |
|--------|------------------|-------------|
| V7     | **380.14**       | Dir only when ret ≤ gate, scaled surge, sym-tox high, size bump, 75 bps cap |
| V8     | 378.99           | + cap 85, pImplied, sigma×tox, cubic tox, trade boost, stale+attract, dirState |
| V10    | 365.83           | + lambdaHat, sizeHat, flow in base (V10 = V8 + activity/flow) |
| V11    | (not reported)   | V10 with flow terms tuned down + flow term cap 12 bps |
| V12    | (not reported)   | V8 + tail compression instead of hard cap |
| V13    | (not reported)   | V11 + first-in-step pHat/sigma |

### What’s working

1. **V7’s core formula**  
   Base 35 bps × (1 + K_VOL×vol)(1 + K_IMB×imb), symmetric tox (linear + quad + SYM_HIGH above 1.5%), vulnerable-side tox (linear + quad + sigma×tox + cubic), floor by imbalance, decay when stale. This structure is the only one that has delivered ~380 so far.

2. **Directionality only when ret ≤ gate**  
   Dir premium (and no overlap with surge) avoids double-penalizing the same move and gives surge headroom. This was a clear gain from V6 → V7.

3. **Scaled surge (15–40 bps)**  
   Surge by (ret − gate) instead of fixed bump helps in large moves without overcharging small ones.

4. **Trade-size bump (capped)**  
   Extra fee on the side hit, by trade size vs reserves (capped), captures some flow size without the complexity of full lambda/size state — and didn’t regress.

5. **75 bps cap (in V7)**  
   The audit argued 75 bps was binding; but when we raised the cap (V8) and added many levers, edge went down. So “cap too low” may be secondary to “other levers mis-tuned or wrong for the sim.”

### What’s not working (mechanical)

1. **Bundling many YQ levers (V8)**  
   Adding cap 85, pImplied, sigma×tox, cubic tox, trade-aligned boost, stale+attract, and dirState in one step **reduced** edge. So either:
   - at least one of these levers is mis-tuned or harmful in this sim, or  
   - the sim mix doesn’t reward this combination as implemented.

2. **Activity/flow in base (V10)**  
   Adding lambdaHat, sizeHat, and flow terms (LAMBDA_COEF, FLOW_SIZE_COEF) in the base fee caused a **large** regression (380 → 365). V11 tries to repair with smaller coefs and a 12 bps cap on the flow term; we don’t yet know if that recovers edge.

3. **High base (35 bps) in calm regimes**  
   Research and YQ suggest: in “normal” conditions fees should stay competitive (e.g. ~30 bps) to keep retail; we start at 35 bps and multiply by vol×imb. In calm regimes we may be above the normalizer often → retail routes away, we see more toxic flow on average (adverse selection).

4. **Hard cap vs tail compression**  
   We still use a single hard cap (75 or 85 bps). When the raw fee would be 90–100 bps, we output the cap and lose gradient; YQ uses tail compression (knee + slope above knee) then clamp. V12 implements tail compression but we don’t have its edge number yet.

5. **Unmeasured impact of first-in-step (V13)**  
   V13 adds first-in-step pHat/sigma (dual alpha, sigma only on first trade in step). The idea is sound (less noise in multi-trade steps); we don’t know if it helps or hurts in this harness.

**Summary:** The only configuration that has **proven** ~380 is V7. Every structural add (V8, V10) has so far regressed. The “next big thing” either has to fix the way we use those adds (tuning, order, or subset) or change the **base structure** (e.g. low base + additive build-up, or explicit regime switch).

---

## 2. Adversarial Exploitation (Still Relevant)

1. **Cap arbitrage**  
   When true fee would be above our cap, we output the cap. Arb keeps the margin we didn’t charge. Tail compression (V12) is meant to soften this.

2. **Fade surge / dirState**  
   After we add surge or dirState skew to one side, the other side is cheaper. Arb can trade the reversion at a discount. If dirState/stale are mis-tuned (V8 regression), this fade is easier.

3. **Activity timing**  
   In V7 we don’t charge for “how many trades per step.” In V10 we did (lambda/size) and regressed; in V11 we capped and reduced. So either we’re still under-pricing burst activity, or the way we added activity was wrong (e.g. in base with wrong sign or scale).

4. **Retail routing**  
   If our fee is often above the normalizer in calm regimes (35 bps base + factors), we get less benign flow and more toxic flow on average.

5. **First-trade-in-step (if we don’t use it well)**  
   If we update pHat/sigma on every trade (V7–V11), a bot can move us then fade in the same step. V13’s first-in-step is meant to reduce that; we need to measure.

---

## 3. Failure Modes by Regime

| Regime / condition        | Limitation                          | Effect |
|---------------------------|-------------------------------------|--------|
| Calm, low vol/imb         | Base 35 bps + factors               | Fee often above normalizer → retail routes away |
| High activity (bursts)    | V7: no lambda/size; V10: we added and regressed | Either under-pricing bursts or wrong formula |
| Near cap                  | Hard clip                           | Marginal value of surge/size/dir lost |
| Multi-trade steps         | pHat/sigma every trade (pre-V13)    | Noisier, exploitable (move then fade) |
| Post–surge / post–dirState| Reversion on other side             | Lower fee on reversion trade |

---

## 4. Next Big Thing — Three Directions

### A. Measure and prune (iterate from V7)

- **Idea:** Treat V7 as the baseline. Run V11, V12, V13 to get edge numbers. Then add **one** structural change at a time: e.g. V7 + tail compression only; V7 + first-in-step only; V7 + cap 85 only. Keep only what improves edge.
- **Pros:** Low risk; uses what we know works (V7).  
- **Cons:** May only recover to ~380–390; unlikely to close a 140+ point gap to 526 by pruning alone.

### B. Rewrite: low base + additive build-up (YQ-style base)

- **Idea:** Replace the current “35 bps × vol × imb + sym-tox + floor” with a **low base** (e.g. 3–10 bps) and **additive** terms: sigma, vol, imbalance, then sym-tox, then vulnerable-side terms. Goal: calm-regime fee ~25–35 bps to compete for retail; stressed regime fee rises by adding terms.
- **Formula (conceptual):**
  - `fBase = BASE_LOW + SIGMA_COEF*sigmaHat + IMB_COEF*imbalance + VOL_COEF*vol`
  - `fBase += symTox(toxEma)` (linear + quad + high threshold)
  - Floor and optional decay as now. Then add vulnerable-side tox, dir, surge, size bump, tail compression, etc.
- **Pros:** Aligns with research (“competitive in normal, elevated in high vol”) and YQ’s structure; addresses “base too high in calm.”  
- **Cons:** Large change; full re-tune; may need to drop or simplify some of the current terms to stay within stack/slots.

### C. Rewrite: explicit two regimes (threshold-type)

- **Idea:** Define two regimes from volatility/toxicity (e.g. “calm” when sigma & tox below thresholds, “stressed” otherwise). In **calm**: fee = low, flat (e.g. 28–32 bps) to attract flow. In **stressed**: fee = current-style formula (vol, imb, tox, dir, surge, size). Switch with hysteresis if needed.
- **Formula (conceptual):**
  - `stressed = (sigmaHat > SIGMA_THRESH) || (toxEma > TOX_THRESH)`
  - `if (!stressed) bidFee = askFee = FEE_CALM` (or tiny spread)
  - `else` use full pipeline (base × vol × imb + tox + dir + surge + size), then tail compression, clamp.
- **Pros:** Matches “two regimes” from research; clear separation of “compete for retail” vs “protect from arb.”  
- **Cons:** Threshold tuning and hysteresis; possible instability at the boundary.

---

## 5. Formulas & Pseudocode (Option B — Low Base Additive)

```text
// Constants: BASE_LOW (e.g. 5e14 = 5 bps), SIGMA_COEF, IMB_COEF, VOL_COEF (all in bps per WAD)
// Slots: same as current (pHat, sigma, vol, toxEma, dirState, prev bid/ask, lambdaHat, sizeHat if kept)

fBase = BASE_LOW
fBase += SIGMA_COEF * sigmaHat
fBase += IMB_COEF * imbalance
fBase += VOL_COEF * vol
fBase += symTox(toxEma)   // linear + quad + SYM_HIGH as now
if (fBase < imbFloor) fBase = imbFloor
// Optional: decay when stale (timestamp > lastTs) as now

// Then: vulnerable-side tox (linear, quad, sigma×tox, cubic), asym, dir, surge, size, tail compress, clamp
// Same pipeline as current after "base" is computed.
```

**Edge cases:**  
- `sigmaHat` or `vol` zero at init → fBase = BASE_LOW + IMB_COEF*imb; tune IMB_COEF so calm-regime fee ~30 bps.  
- Cap total base (e.g. max 60 bps) before adding vulnerable-side terms if needed to avoid stack/deep issues.

---

## 6. Simulation Blueprint (For Any Next Step)

- **Inputs:** Same harness, 1000 sims; same or varied seeds for comparability.  
- **Metrics:** Edge (primary); fee distribution (mean, p90, cap-hit rate) by side; by regime if possible (calm vs active vs high-tox).  
- **Scenarios:**
  1. Run V11, V12, V13 and record edge vs V7 (380.14) and V8 (378.99).  
  2. If rewriting (B or C): implement minimal version (e.g. B with same dir/surge/size as V7, no flow terms at first), run vs V7.  
  3. Add one lever at a time (tail compression, first-in-step, cap) and measure.  
- **Criteria:** Edge ≥ 400 as first milestone; then 450+; compare to YQ (520) for remaining gap.

---

## 7. Recommendation (Prioritized)

1. **Get numbers for V11, V12, V13**  
   Without them we don’t know if “tuned flow,” “tail compression,” or “first-in-step” help. If V12 > V7, tail compression is a keeper. If V13 > V11, first-in-step is a keeper.

2. **If pruning recovers to ~385 but not 400+**  
   Treat the “next big thing” as a **structural change to the base**: either **B (low base + additive)** or **C (two regimes)**. Prefer B first (fewer regime-boundary issues); implement with same dir/surge/size/tail as current, then tune BASE_LOW and additive coefs so calm fee ~28–32 bps.

3. **If you prefer to rewrite from scratch**  
   Start from **B** with minimal state: pHat, sigmaHat, toxEma, prev bid/ask, optional dirState. Omit lambdaHat/sizeHat initially. Add tail compression and first-in-step once the base formula is stable. Document as a new strategy line (e.g. SapientV14 or a new name) and keep V7/V11 as reference.

---

## 8. One Question (Brainstorming)

To choose the next step and how far to go (iterate vs rewrite), one thing we need to know:

**Do you have (or can you run and share) the edge numbers for V11, V12, and V13?**  

- If **yes** — we can decide whether to double down on “tuned flow + first-in-step” (V11/V13) or “tail compression” (V12), or conclude that none beat V7 and push toward a rewrite (B or C).  
- If **no** — the safest next move is to run those three and then decide; the “next big thing” could still be a rewrite (B or C) in parallel once we know the baseline.

---

## References

- [2025-02-09-Sapient-audit-380-vs-526.md](2025-02-09-Sapient-audit-380-vs-526.md)
- [2025-02-09-Sapient-V7-under-400-analysis.md](2025-02-09-Sapient-V7-under-400-analysis.md)
- [2025-02-09-YQ-extract-for-Sapient.md](2025-02-09-YQ-extract-for-Sapient.md)
- [2025-02-09-Sapient-V11-tune-changelog.md](2025-02-09-Sapient-V11-tune-changelog.md)
- [2025-02-09-Sapient-V12-changelog.md](2025-02-09-Sapient-V12-changelog.md)
- [2025-02-09-Sapient-V13-first-in-step-changelog.md](2025-02-09-Sapient-V13-first-in-step-changelog.md)
