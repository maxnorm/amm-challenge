# Why V24 Edge Collapsed to 40.30

**Date:** 2025-02-10  
**Context:** V23 (3 bps base, tail only) ≈ 380 edge. V24 (V23 + activity in base with YQ coefficients) → **40.30** edge.

---

## 1. Root cause: activity terms dominate and peg fee at 75 bps

Fee units: **1e14 = 1 bps**. So `MAX_FEE_CAP = 75e14` = 75 bps.

### 1.1 Activity add-ons in raw fee (WAD where needed)

- **LAMBDA_COEF × lambdaHat**  
  `12e14 × 0.8` (init) → `12e14 × 8e17 / 1e18` = **~9.6e13** → **~0.96 bps**. Small.

- **FLOW_SIZE_COEF × (lambdaHat × sizeHat)**  
  Init: lambdaHat = 0.8, sizeHat = 0.002 → flowSize = 0.0016 (WAD).  
  `4842e14 × 1.6e15 / 1e18` = **~7.75e14** → **~77.5 bps**.

- **ACT_COEF × actEma**  
  `91843e14 × actEma` (actEma in WAD).  
  actEma = 1% = 1e16 → `91843e14 × 1e16 / 1e18` = **~918.43e14** → **~918 bps** per 1% actEma.

So with **initial** state (actEma = 0):

- Base: 3 bps  
- Lambda: ~1 bps  
- FlowSize: **~77.5 bps**  
- **Subtotal from activity alone: ~78.5 bps** → already above 75 bps cap.

After a few trades, `actEma` blends up (e.g. 0.5% → +459 bps from ACT_COEF alone). So **raw fee is almost always far above 75 bps** → we clamp to 75 bps on almost every trade.

---

## 2. Why that kills edge

- We **quote 75 bps** (or close) on almost every trade.
- The sim has a **fixed 30 bps baseline** (or similar). When we’re at 75 bps we’re **much more expensive**.
- **Flow goes to the cheaper pool**; we keep mainly **adverse/toxic** flow.
- Result: **low volume, bad adverse selection** → edge collapses to ~40.

So the regression is not “activity is wrong,” but **YQ’s activity coefficients are far too large when stacked on top of our existing base** (sigma, imb, vol, symTox, floor).

---

## 3. Why YQ can use those coefficients

In YQ:

- **fBase** = base + **sigma** + **lambda** + **flowSize** (no imbalance, no vol in base).
- **fMid** = fBase + tox + **actEma** + sigma×tox + cubic, etc.

So in YQ, the **only** “base” drivers are base fee, sigma, lambda, and flowSize. There is **no** imb/vol/symTox in that layer. So 77 bps from flowSize and large actEma contribution can still land in a range YQ’s tail and cap then shape.

In V24 we **added** lambda + flowSize + actEma **on top of**:

- sigma (SIGMA_COEF × sigmaHat)
- imbalance (IMB_COEF × imbalance)
- vol (VOL_COEF × vol)
- symTox (linear + quad + SYM_HIGH)
- imbalance floor

So we have **two layers of “base”**: our original (sigma/imb/vol/symTox) **plus** YQ-style activity. That makes the **total** base fee huge and we hit the 75 bps cap almost always.

---

## 4. Numerical summary

| Term              | Typical contribution (approx) | Comment        |
|-------------------|--------------------------------|----------------|
| BASE_LOW          | 3 bps                          | Fixed          |
| Lambda            | ~1 bps                         | Small          |
| FlowSize (init)   | **~77 bps**                    | **Dominant**   |
| ACT_COEF × actEma | **~918 bps per 1% actEma**     | **Explodes**   |
| Sigma/imb/vol/symTox (V23) | 10–40+ bps (before activity) | Adds on top    |

So **raw fee** is often **100–500+ bps** → clamp to 75 bps → we look “max fee” almost always → edge ~40.

---

## 5. What to do next

1. **Scale down activity coefficients** so activity adds on the order of **a few bps to ~20 bps** total, not 78+ bps from flowSize and hundreds from actEma. For example:
   - **FLOW_SIZE_COEF**: try **~50–200× smaller** (e.g. 4842e14 → ~25e14–100e14) so flowSize adds ~0.5–2 bps at init.
   - **ACT_COEF**: try **~100–500× smaller** (e.g. 91843e14 → ~180e14–900e14) so 1% actEma adds ~1.8–9 bps.

2. **Or** add a **cap on the activity contribution** (e.g. lambda + flowSize + actEma add at most 15–20 bps) so the rest of the formula (sigma, imb, vol, symTox, dir, surge, tail) can still differentiate.

3. **Re-run** with scaled (or capped) activity and compare edge to V23 (~380) and V24 (40). If edge recovers toward 380 and then improves with tuning, we keep “activity in base” but with our own scaling.

---

## 6. Summary

| Finding | Detail |
|--------|--------|
| **Cause** | YQ’s FLOW_SIZE_COEF and ACT_COEF are huge; on top of our sigma/imb/vol/symTox they push raw fee to 100–500+ bps. |
| **Effect** | Fee is clamped to 75 bps almost always → we’re expensive → flow leaves → adverse selection → edge ~40. |
| **Fix** | Use much smaller (or capped) activity coefficients so “activity in base” adds a few bps to ~20 bps, not hundreds. |
