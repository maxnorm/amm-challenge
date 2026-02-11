# Analysis: V23 / V29 / V31 Results

**Date:** 2025-02-10  

| Strategy | Description | Edge |
|----------|-------------|------|
| **V23** | Baseline (no activity) | **379.74** |
| **V29** | Exact copy of V23 (name only) | **379.74** |
| **V31** | V28 (pHat fix) + V26 scaled activity coefs | **40.30** |

---

## 1. What this confirms

- **V23 vs V29:** Same edge (379.74). The sim is not sensitive to strategy name or file path; behavior is driven by the code path.
- **Baseline is stable:** ~380 is the correct reference for “no activity” in this harness.
- **V31 = 40.30:** Adding scaled activity (LAMBDA 2e14, FLOW_SIZE 300e14, ACT 500e14) on top of the pHat fix still collapses edge. So the regression is **not** fixed by (a) pHat write order or (b) scaling down activity coefs.

---

## 2. Root cause (revised)

The drop to **40.30** is tied to the **activity pipeline** (step decay, blend, slots 5–8), not only to the size of the activity terms:

- **V27** (activity terms zeroed, pipeline still there) → 40.30  
- **V28** (pHat fix, terms still zeroed) → 40.30  
- **V31** (pHat fix + scaled activity terms) → 40.30  

So:

1. **Any version that runs the activity logic** (step decay, blend, step count, reads/writes of lambda/size/actEma) ends up at **40.30**, whether or not activity is added to the fee.
2. So either:
   - The **pipeline itself** changes something that affects fees or routing (e.g. a bug that changes vol/sigma/timestamp or another input used later), or
   - The **sim** reacts to something that correlates with this pipeline (e.g. more storage writes, different slot layout, gas). The first is more likely, since the intended fee formula with zero activity terms should match V23.

---

## 3. Practical conclusion

- To **keep edge ~380**, use **V23 (or V29)** — no activity in the base, no step/blend/extra slots.
- The current **activity-in-base** design (lambdaHat, sizeHat, actEma, step decay, blend) **consistently** gives 40.30 in this harness, with or without pHat fix and with or without scaled activity terms. So for this sim it is not a viable path in its current form.
- To **improve beyond 380** without regressing, options are:
  1. **Find and fix the bug** in the activity pipeline (e.g. a wrong slot index or an unintended dependency on slots 5–8 or on step/blend order).
  2. **Redesign activity** so it does not use this pipeline (e.g. different state, no step-based decay, or activity that does not run before spot/pHat).
  3. **Leave activity out** and try other levers (e.g. pImplied, first-in-step, dirState, stale/attract) one at a time on top of V23, as in the V23 vs YQ comparison doc.

---

## 4. Summary table

| Has activity pipeline (step/blend/slots 5–8) | Activity terms in fee | Edge |
|---------------------------------------------|------------------------|------|
| No (V23, V29)                                | No                     | **379.74** |
| Yes (V24–V28, V31)                           | Any (zero or scaled)   | **40.30** |

The **activity pipeline** is the discriminator for the 40.30 outcome; the level of activity in the fee (zero vs scaled) does not change it.
