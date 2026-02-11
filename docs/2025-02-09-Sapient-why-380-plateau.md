# Why We Plateau at 380.13

**Date:** 2025-02-09  
**Fact:** V14, V18 (pImplied only), V19 (sigma×tox + cubic), and V20 (trade-aligned boost) all report **Edge: 380.13** in 1000 sims. Isolated levers on the V14 baseline have not moved the needle.

---

## 1. What 380.13 Likely Means

- **Same number every time** suggests either:
  - **Deterministic sim:** Fixed seeds and our strategies are similar enough that the *rounded* edge is identical (small differences get rounded to 380.13), or
  - **Flat region:** We’re in a part of “strategy space” where the sim’s objective is almost flat — small formula changes don’t change outcomes much, or
  - **Ceiling for this class:** The scoring / scenario set may cap or heavily penalize strategies that look like “V14 + one extra term” so we keep landing on the same score.

So the plateau is both **empirical** (every variant we tried hits 380.13) and **structural** (we’re not changing the things the sim might be rewarding or punishing).

---

## 2. Why Our Levers Didn’t Move It

We added one at a time on V14:

| Lever | What it addresses | Result |
|-------|--------------------|--------|
| **pImplied (V18)** | Cleaner price for pHat/ret/dir/surge; less distortion from toxic trade’s spot | 380.13 |
| **Sigma×tox + cubic (V19)** | Sharper fee when wrong and volatile | 380.13 |
| **Trade-aligned boost (V20)** | Extra charge when *current* trade is toxic | 380.13 |

Plausible reasons they don’t help:

1. **Sim doesn’t punish the exploit we fix**  
   If the harness doesn’t have many “move-then-fade” or “toxic current trade” scenarios, improving our response to them doesn’t show up in edge.

2. **Sim rewards something we don’t change**  
   Top score ~526 (YQ ~520). The gap is ~146 points. That suggests the sim rewards:
   - Different **base structure** (e.g. very low base + build-up, activity/flow in base),
   - **First-in-step** logic (sigma only on first trade in step, dual alpha),
   - **Regime switch** (low fee in calm, full pipeline in stress),
   - Or **tail compression** and protect/attract rather than a hard cap.

   We’ve been testing “V14 + one lever” without those structural changes.

3. **Need a combination, not isolation**  
   Maybe pImplied + first-in-step, or trade boost + dirState, only help when combined. Single-term additions might be too small a change.

4. **Local optimum**  
   V14’s 75 bps cap and additive base might sit at a local optimum. Small tweaks (more tox, cleaner signal, trade boost) don’t move us off that plateau; a bigger change (two regimes, first-in-step, or different base) might be required.

---

## 3. What the Audit Already Said (380 vs 526)

From [2025-02-09-Sapient-audit-380-vs-526.md](2025-02-09-Sapient-audit-380-vs-526.md):

- **Structural gaps vs YQ:** No lambda/size/activity in base; hard cap instead of tail compression; single alpha and sigma every trade (no first-in-step); higher base than YQ’s 3 bps build-up.
- **Exploits:** Cap arbitrage, fade after surge/dirState, undercharging activity, retail routing when we’re above ~30 bps in calm, first-trade-in-step move-then-fade.

So the plateau isn’t only “we need one more coefficient” — it’s that we’re still missing **structural** pieces the sim may be scoring (activity in base, first-in-step, regime switch, tail shape).

---

## 4. What We Haven’t Tried Yet (on V14)

- **V21 — First-in-step:** One slot (stepTradeCount); fast alpha on first trade in step, slow on later; update sigma only on first-in-step. Directly targets “move then fade” and multi-trade noise.
- **V22 — dirState alone:** Flow-direction memory; protect side under pressure, attract the other. (V8 had it bundled and regressed; isolation may behave differently.)
- **V23 — Stale + attract alone:** Widen vulnerable side, attract on the other. Same idea — try alone on V14.
- **V24 — Two regimes:** If sigma and tox below threshold → flat low fee (calm); else full V14 pipeline (stressed). Explicit “cheap in calm, high in stress.”
- **V25 — Conditional tail:** Compress only when fee > 75 bps, then clamp 85. Keeps 25–75 band like V14, softens above 75.

Or **combine** levers: e.g. V18 + V21 (pImplied + first-in-step), or V14 + two regimes (V24).

---

## 5. Short Answer

**Why 380.13?**

- **Empirically:** V14 and every “V14 + one lever” variant we ran (pImplied, sigma×tox+cubic, trade boost) score 380.13 in this sim.
- **Structurally:** The sim likely rewards different **structures** (activity in base, first-in-step, regime switch, tail shape). Our one-term additions don’t change those, so we stay in a flat region or at a local optimum.
- **Next:** Try **first-in-step (V21)** or **two regimes (V24)**, or a **combination** (e.g. pImplied + first-in-step), and document results. If edge still doesn’t move, the next step is to inspect how the sim computes edge and which scenario types drive the gap to 526.
