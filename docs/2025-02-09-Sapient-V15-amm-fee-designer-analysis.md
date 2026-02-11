# Sapient V15 — AMM Fee Designer Analysis (Edge 380.02, Slight Regression)

**Date:** 2025-02-09  
**Context:** V15 (V14 + tail compression, cap 85 bps) ran 1000 sims → **Edge 380.02**. V14 → 380.13, V7 → 380.14. Tail compression slightly **reduced** edge.  
**Skill:** amm-fee-designer — diagnosis, exploit vectors, failure modes, new ideas, formulas, simulation plan, recommendation.

---

## Step 1 — Loss Diagnosis (Why V15 Regressed vs V14)

V15 is not “losing” in absolute terms but **regressed** by ~0.11 edge (380.02 vs 380.13). The cause is how tail compression interacts with the fee range we actually observe.

### Mechanical reasons tail compression hurt

1. **Compression lowers fees in the 75–85 bps range**  
   In V14 the pipeline is clamped at 75 bps, so whenever raw fee would be 75–100+ we output **75**. In V15 we clamp at 85, so pre-compression fees can be up to 85. Then we apply: `fee_out = 5 + slope × (fee − 5)`. For **protect** (slope 0.93): a pre-compression fee of **75** becomes `5 + 0.93 × 70 = 70.1` bps. So in the exact range where V14 was outputting **75**, V15 outputs **~70**. We are **charging less** in the high-fee regime. The sim likely earns edge when we charge 75 in stressed moments; compressing 75 down to 70 gives margin back to arb/retail and reduces our edge.

2. **Same compression applied to both sides**  
   We compress every fee above the knee (5 bps). So fees in the 30–75 bps range (where we’re already competitive) also get compressed: e.g. 40 bps → `5 + 0.93 × 35 ≈ 37.55`. That slightly lowers revenue across the board. The benefit of tail compression (preserving gradient above a high knee) only helps if we **first** let raw fees go above the old cap (75), then compress and clamp. In our implementation we compress the **entire** tail above 5 bps, so we shrink fees that were already at or below 75.

3. **Protect/attract by imbalance only**  
   V15 has no dirState; we use `reserveY >= reserveX` → bid protect, ask attract. That can mis-identify the “pressure” side relative to flow direction (YQ uses dirState). Mis-assignment means we sometimes apply the steeper slope (0.93) to the wrong side, slightly worsening the fee mix. The effect is likely small; the main effect is (1)–(2).

4. **Cap 85 vs 75**  
   Raising the cap to 85 allows higher **pre-compression** fees, but compression then pulls them down. So effective max is ~79–82 bps (e.g. 85 → 5 + 0.93×80 = 79.4). We do charge more than 75 in the very tail, but for the bulk of “high but not extreme” cases (75–85) we charge **less** than V14’s flat 75. Net effect: small regression.

**Summary:** Tail compression was applied **above a low knee (5 bps)** to **all** fees. That reduces fees in the 25–85 bps range relative to V14’s hard cap at 75. So we give back margin exactly where we were making edge. To make tail compression help we need either (a) **compress only above the old cap** (e.g. fee > 75 → compress then clamp 85), or (b) **higher knee** so we don’t compress the 25–75 bps band, or (c) **steeper slopes** so 85 stays near 85 and we don’t shrink 75 as much.

---

## Step 2 — Adversarial Exploitation (V15)

1. **Compression as discount**  
   When we would have quoted 75 (V14), we now quote ~70 (V15). Arb and toxic flow get the same execution at a **lower** fee in those regimes. That directly reduces our edge.

2. **Fade after surge still applies**  
   Surge adds to one side; the other side is cheaper. Compression doesn’t change that; reversion is still attractive.

3. **No dirState**  
   Protect/attract is based only on reserves. Flow can be one-sided for a while without changing reserves much (e.g. many small hits). We may apply protect/attract slopes suboptimally.

4. **Retail routing**  
   Slightly lower fees in the 30–70 bps range (from compressing above 5 bps) could shift a bit more volume our way, but the sim’s edge may be more sensitive to **high-fee** capture than to marginal retail share; the net we observed is a small loss.

---

## Step 3 — Failure Modes (V15)

| Regime / condition        | V15 limitation                          | Effect |
|---------------------------|------------------------------------------|--------|
| Pre-compression fee 75–85 | Compressed to ~70–79                    | We charge less than V14’s 75 → edge down |
| Fee 25–75                 | Compressed above knee 5                 | Slight fee reduction across the board |
| Protect/attract           | Based on reserves only (no dirState)    | Possible mis-assignment of slopes |
| Post–surge reversion      | Unchanged from V14                      | Arb still trades reversion at lower fee |

---

## Step 4 — New Strategy Ideas (To Recover and Break 380)

### A. Tail compression only above old cap (conditional compression)

- **Idea:** Apply tail compression **only when** pre-compression fee > 75 bps. If fee ≤ 75, output fee unchanged (or clamp at 75). If fee > 75, set fee_compressed = 75 + slope × (fee − 75), then clamp at 85. So we preserve V14 behavior in the 0–75 range and only “soften” the tail above 75.
- **Addresses:** Avoids reducing fees in the 25–75 band; keeps gradient above 75.
- **Formula:** `if (fee <= 75e14) return fee > MAX_75 ? 75e14 : fee; else return clamp(75e14 + slope*(fee - 75e14), 85e14);` with MAX_75 = 75e14.

### B. Higher knee (e.g. 50 bps)

- **Idea:** Keep tail compression but set TAIL_KNEE = 50e14 (50 bps). Then only fees above 50 bps are compressed. Fees in 25–50 bps are unchanged; 50–85 get compressed (e.g. 75 → 50 + 0.93×25 = 73.25). So we don’t pull 75 down to 70.
- **Addresses:** Stops compressing the “normal” high range where we make edge.
- **Risk:** Knee at 50 may be too high for the “attract” side; tune.

### C. Steeper slopes (e.g. 0.98 protect, 0.99 attract)

- **Idea:** Use slopes closer to 1 so that 85 → ~83 and 75 → ~74. We keep most of the fee level and only slightly soften the very tail.
- **Addresses:** Less fee give-back in 75–85 range.
- **Risk:** Less “compression” benefit; may behave like a soft cap near 85.

### D. Revert to V14 and try first-in-step or pImplied

- **Idea:** Drop tail compression for now; keep V14 (380.13). Add **first-in-step** pHat/sigma (as in V13) or **pImplied** alone on V14 to improve signal quality and reduce move-then-fade.
- **Addresses:** Different lever; doesn’t rely on tail compression in this harness.
- **Risk:** First-in-step / pImplied may need tuning; V8 regressed when many levers were bundled.

### E. Tail compression on V7 instead of V14

- **Idea:** Apply the same tail logic (with conditional compression above 75 or higher knee) on **V7** (multiplicative base). Test if the sim rewards tail compression more when the base is V7’s.
- **Addresses:** Isolate base (V7 vs V14) × tail compression interaction.
- **Risk:** Two variables; need A/B comparison.

---

## Step 5 — Formulas & Pseudocode

### A. Conditional compression (only above 75 bps)

```text
uint256 constant OLD_CAP = 75e14;  // don't compress below this
uint256 constant TAIL_KNEE_HIGH = 75e14;

function _compressTailAboveOldCap(uint256 fee, uint256 slope) internal pure returns (uint256) {
    if (fee <= OLD_CAP) return fee > MAX_FEE_CAP ? MAX_FEE_CAP : fee;  // or clamp to 75
    // fee > 75: compress the excess above 75
    uint256 excess = fee - OLD_CAP;
    uint256 compressedExcess = _wmul(excess, slope);
    uint256 out = OLD_CAP + compressedExcess;
    return out > MAX_FEE_CAP ? MAX_FEE_CAP : out;
}
// Then clamp to 85. So output in [0, 85], and we never go below 75 when raw was > 75.
```

### B. Higher knee (50 bps)

```text
TAIL_KNEE = 50e14;
// Rest unchanged. Then 75 → 50 + 0.93*25 = 73.25; 85 → 50 + 0.93*35 = 82.55.
```

### C. Steeper slopes

```text
TAIL_SLOPE_PROTECT = 98e16;  // 0.98
TAIL_SLOPE_ATTRACT = 99e16;  // 0.99
// 75 → 5 + 0.98*70 = 73.6; 85 → 5 + 0.98*80 = 83.4.
```

---

## Step 6 — Simulation Blueprint

- **Inputs:** Same harness, 1000 sims; same seeds for comparability.
- **Metrics:** Edge (primary); fee distribution (mean, p90, p99) by side; fraction of trades where fee ∈ (70, 75], (75, 85], > 85.
- **Scenarios:**
  1. **V15 conditional:** V14 base + tail compression **only when** fee > 75 bps (formula A), clamp 85. Compare to V14 (380.13) and V15 (380.02).
  2. **V15 high knee:** V15 with TAIL_KNEE = 50e14, same slopes. Compare to V14 and V15.
  3. **V15 steeper slopes:** V15 with slopes 0.98 / 0.99. Compare to V14 and V15.
  4. **V14 + first-in-step:** Add first-in-step pHat/sigma to V14 (no tail). Compare to V14.
- **Criteria:** Recover edge ≥ 380.13; target ≥ 385.

---

## Step 7 — Recommendation

**Prioritized next steps:**

1. **Conditional tail compression (only above 75 bps)**  
   Implement formula A in a new variant (e.g. V16): apply tail compression only when pre-compression fee > 75 bps; otherwise leave fee unchanged (and clamp at 75 for consistency). Then clamp final output at 85. This preserves V14’s revenue in the 0–75 range and only softens 75–85. Run 1000 sims; if edge ≥ 380.13, tail compression is useful when applied only above the old cap.

2. **If conditional compression still regresses**  
   Try **higher knee** (50 bps) or **steeper slopes** (0.98/0.99) on V15 and re-run. If all tail variants regress, **revert to V14** as baseline and prioritize **first-in-step** or **pImplied** (single lever) instead of tail compression for this harness.

3. **Document**  
   Record V15 result (380.02) and the conditional/high-knee/steep-slope results in `/docs` and in the V15 changelog so we know tail compression’s effect in this sim.

**Summary:** V15’s regression comes from compressing **all** fees above 5 bps, which **lowers** fees in the 25–85 bps range relative to V14’s 75 bps cap. The next structural change to try is **tail compression only above 75 bps** (conditional compression); if that doesn’t help, keep V14 and try first-in-step or pImplied.

---

## References

- [2025-02-09-Sapient-V15-tail-compression-changelog.md](2025-02-09-Sapient-V15-tail-compression-changelog.md)
- [2025-02-09-Sapient-V14-amm-fee-designer-analysis.md](2025-02-09-Sapient-V14-amm-fee-designer-analysis.md)
- [2025-02-09-Sapient-V12-changelog.md](2025-02-09-Sapient-V12-changelog.md) — V12 uses dirState for protect/attract.
