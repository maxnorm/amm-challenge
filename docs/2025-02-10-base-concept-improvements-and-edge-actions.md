# Base-Concept Improvements and Edge Actions

**Context:** Based on [2025-02-10-improve-edge-from-V34.md](2025-02-10-improve-edge-from-V34.md) and related findings. V34 = 524.63 edge; leaderboard ~526. No structural variant has beaten V34; several tied or regressed.

This doc answers: **What can we do to improve our edge, and what changes to our base concept could help?**

---

## 1. What the data tells us

- **Structural experiments (V35–V43):** None beat V34. Ties: V39 (tox-dependent decay), V40 (silence risk), V43 (two-speed pHat). Regressions: V35 (imbalance skew), V36–V38 (calm/stressed), V41 (gate by size), **V42 (toxic flow run, large drop to 507)**.
- **Implications:**
  - **Imbalance** as a direct skew term hurt (V35); **toxic run** memory hurt a lot (V42). Avoid heavy reuse of these ideas.
  - **Calm/stressed** and **gate by size** slightly hurt; thresholds or sim mix may be wrong.
  - **Ties** add complexity without gain so far — but they might help when **combined** or when **constants** are tuned around them.

---

## 2. Changes to the base concept that could help

### 2.1 Size-dependent attract (angle 2.8) — **not yet tried**

- **Idea:** Increase the **attract-side discount** when the *next* trade is expected to be large. Use **sizeHat** (or similar) so the discount scales with typical size, not the current trade (reduces gaming).
- **Why it could help:** Competes for large rebalancing flow; the sim may reward winning that flow. V34 uses a fixed attract fraction; making it size-aware is a small, targeted change.
- **Risk:** If the coef is too large, we give away too much on large attract-side trades. Keep the size term small and test one version (e.g. V44).

### 2.2 Constant tuning (no new logic)

- **Idea:** Keep V34 structure; only change **one constant per version** in small steps (±5–10% or ±1 BPS). Priority order (from [2025-02-10-constant-tuning-plan-V34.md](2025-02-10-constant-tuning-plan-V34.md)): TAIL_KNEE / TAIL_SLOPE_* → TOX_QUAD_COEF, TOX_COEF → FLOW_SIZE_COEF, LAMBDA_COEF → SIGMA_COEF, BASE_FEE → DIR/STALE → decays.
- **Why it could help:** The gap to 526 is small; the sim may simply favor a slightly different calibration (fee level, tail compression, toxicity curvature, or cap-hit rate).
- **Risk:** Low. Revert any constant that regresses.

### 2.3 Combine two “tie” features

- **Idea:** V39, V40, V43 all tied V34. Try **one** version that combines two of them (e.g. **silence risk + two-speed pHat**). Sometimes 1+1 > 1 if the sim rewards both “first-trade-after-silence” and “regime-change” awareness.
- **Why it could help:** Ties mean no harm alone; together they might capture more regime information and nudge edge up.
- **Risk:** More state and logic; if both are marginally useful, combination could overfit or confuse. Try one combo (e.g. V44 or V45), single run.

### 2.4 Reserve imbalance as a **light** second signal (angle 2.1, revised)

- **Idea:** Do **not** add imbalance as a direct skew term (that was V35 and hurt). Instead: use imbalance only to **modulate** dirState — e.g. when imbalance and dirState agree, use dirState as-is; when they disagree, **damp** dirState slightly (we’re less sure). Keep the effect small (one extra coef, low weight).
- **Why it could help:** A second, independent signal might reduce wrong-side protection when inventory and flow disagree.
- **Risk:** Still “imbalance”; if the sim doesn’t reward it, we get another neutral or slight regression. Prefer trying **2.8** and **constant tuning** first.

### 2.5 Asymmetric cap (angle 2.9)

- **Idea:** Allow **protect** side a higher effective cap (e.g. 12%) and **attract** side a lower cap (e.g. 8%) so we squeeze more from the side we’re protecting while staying cheaper on the attract side.
- **Why it could help:** More fee from adverse flow, clearer discount for desired flow.
- **Risk:** The harness may enforce a **single** MAX_FEE for both sides. **Check the harness/spec first**; only implement if allowed.

### 2.6 Diagnose *where* we lose

- **Idea:** Inspect **how the sim computes edge** and **which scenario types** (e.g. calm vs volatile vs toxic-heavy steps) drive the gap to 526. If possible, log or infer: average fee, cap-hit rate, fee-by-regime.
- **Why it could help:** Tells us whether to push **tail/tox** (more fee in stressed regimes), **base/lambda** (level vs activity), or **attract/protect** (spread shape). Directs both constant tuning and structural experiments.
- **Risk:** None; this is diagnostic. May require reading harness code or adding temporary logging.

---

## 3. What to avoid (from findings)

- **Heavy imbalance term in the fee** — V35 regressed; keep imbalance out of the main skew or use it only as a very small modulator (2.4).
- **Toxic flow run (recent N toxic count)** — V42 dropped to 507; the encoding or the idea doesn’t fit the sim. Don’t retry without a clearly different, minimal design.
- **Calm/stressed thresholds** — V36–V38 all regressed; current thresholds (σ, tox) don’t match the sim. Only retry with a clear hypothesis (e.g. from diagnostics) and different thresholds.
- **Gate by size (update gate/alpha by trade size)** — V41 regressed; size-dependent trust of pImplied hurt. Skip unless we have evidence the sim rewards it.

---

## 4. Suggested order of action

1. **Constant tuning (first)**  
   Use the next version number (e.g. V44) for **one** constant change from the tuning plan (e.g. TAIL_KNEE 500 → 450 BPS). Run 1000 sims. If edge > 524.63, adopt as new baseline and continue with the next constant; if not, revert and try opposite sign or next constant. Document each in `/docs`.

2. **Size-dependent attract (2.8)**  
   Implement in a new version (e.g. V45 if V44 is used for tuning). Use **sizeHat** to scale the attract discount; keep the extra coef small. One version, one run. If it wins, keep; if it regresses, revert.

3. **Optional: combine two ties**  
   One version (e.g. V46) with e.g. silence risk + two-speed pHat. Single run vs current baseline.

4. **Diagnostics**  
   When possible: inspect sim edge computation and scenario mix; optionally log avg fee, cap-hit rate. Use results to prioritize which constants or angles to try next.

5. **Asymmetric cap (2.9)**  
   Only after checking harness: if allowed, try one version with protect cap > attract cap.

6. **Light imbalance modulation (2.1 revised)**  
   Only if 2.8 and constant tuning don’t move the needle; implement as a small damp when imbalance and dirState disagree.

---

## 5. Summary table

| Action | Type | Risk | When |
|--------|------|------|------|
| Constant tuning (one const/version) | Calibration | Low | First |
| Size-dependent attract (sizeHat) | Base concept (2.8) | Low–medium | Second |
| Combine two ties (e.g. silence + two-speed pHat) | Base concept | Medium | Optional |
| Diagnose sim (edge, scenarios, fee/cap) | Diagnostic | None | When possible |
| Asymmetric cap | Base concept (2.9) | Check harness | If allowed |
| Light imbalance modulation | Base concept (2.1) | Medium | If others don’t help |

---

## 6. References

- [2025-02-10-improve-edge-from-V34.md](2025-02-10-improve-edge-from-V34.md) — current state and next steps
- [2025-02-10-constant-tuning-plan-V34.md](2025-02-10-constant-tuning-plan-V34.md) — constants, order, and procedure
- [2025-02-10-V34-explanation-and-unique-angles.md](2025-02-10-V34-explanation-and-unique-angles.md) — base concept and angles 2.1–2.10
- [2025-02-10-param-tuning-procedural-plan.md](2025-02-10-param-tuning-procedural-plan.md) — procedural tuning log (version numbering may need to align with V44+)
