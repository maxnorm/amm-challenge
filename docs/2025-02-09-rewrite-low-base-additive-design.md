# Rewrite Design: Low Base + Additive Build-Up (Sapient V14)

**Date:** 2025-02-09  
**Goal:** Improve edge by replacing the multiplicative base (35 bps × vol × imb) with a low base plus additive terms, so calm-regime fee stays competitive (~25–35 bps) and stressed-regime fee rises by adding terms.  
**Reference:** [2025-02-09-Sapient-what-works-next-big-thing.md](../2025-02-09-Sapient-what-works-next-big-thing.md) Option B.

---

## Section 1 — Goal, Scope, Success Criteria

**Goal:** One structural change only — the **base fee formula**. Everything after base (vulnerable-side tox, asym, dir, surge, size bump, cap) stays as in V7 so we can attribute any edge change to the new base.

**Scope (in):**
- New base: `fBase = BASE_LOW + SIGMA_COEF*sigmaHat + IMB_COEF*imbalance + VOL_COEF*vol + symTox(toxEma)` with floor and optional decay.
- Same state as V7: pHat, volatility, timestamp, sigma, toxEma (slots 0–4); same temp slots (10–15).
- Same downstream pipeline: tox premium (linear + quad) on vulnerable side, 60% asym, dir only when ret ≤ gate, scaled surge, trade-size bump, hard cap 75 bps (or 85 if we test).
- Same pHat/sigma/tox update logic as V7 (spot-based pHat, no pImplied, no first-in-step in v1).

**Scope (out for v1):**
- No dirState, no lambdaHat/sizeHat, no pImplied, no tail compression, no first-in-step. Those can be added in V15+ once the new base is validated.

**Success criteria:**
- Edge ≥ V7 (380.14) on same harness (1000 sims). Stretch: edge ≥ 390.
- Calm-regime fee (low sigma/vol/tox) in 25–35 bps range so we compete for retail; stressed-regime fee can exceed 35 bps via additive terms.
- No new slots; no foundry config change; stack depth within current compiler limits.

---

## Section 2 — Base Formula Change

**Current (V7):**
```text
rawFee = BASE_FEE * (1 + K_VOL*vol) * (1 + K_IMB*imbalance)
rawFee += symTox(toxEma)   // SYM_TOX_COEF*tox + SYM_TOX_QUAD*tox^2 + SYM_HIGH above 1.5%
rawFee = max(rawFee, imbFloor)
// optional: decay toward imbFloor when timestamp > lastTs
```

**New (V14):**
```text
fBase = BASE_LOW
fBase += SIGMA_COEF * sigmaHat
fBase += IMB_COEF * imbalance
fBase += VOL_COEF * vol
fBase += symTox(toxEma)   // same symTox formula as V7
imbFloor = BASE_LOW + FLOOR_IMB_SCALE * imbalance
fBase = max(fBase, imbFloor)
// optional: decay toward imbFloor when timestamp > lastTs (same decay logic as V7)
```

**Constants to define (WAD = 1e18; bps = 1e14):**
- `BASE_LOW`: 5e14–10e14 (5–10 bps). Tune so that with sigma/vol/imb ≈ 0, fBase ≈ 28–32 bps after floor (floor will pull up a bit).
- `SIGMA_COEF`: bps per WAD of sigmaHat. sigmaHat ~ 0.5%–2% typical; we want sigma term to add roughly 5–15 bps in normal regimes. So SIGMA_COEF in the ballpark of 500e14–1500e14 (500–1500 bps per unit sigma in WAD). Since sigma is small (e.g. 0.01 = 1e16), coef in WAD terms: e.g. 5e18–15e18 so that 0.01 * 10 = 0.1 → 10 bps. So SIGMA_COEF ≈ 10e18–20e18 (10–20 bps per 1% sigma in WAD).
- `IMB_COEF`: bps per WAD of imbalance (0–1). Imbalance 0.1 → add a few bps. E.g. IMB_COEF ≈ 50e14–150e14 (50–150 bps per unit imbalance).
- `VOL_COEF`: bps per WAD of vol. Similar to sigma; vol often 0.5%–2%. VOL_COEF ≈ 10e18–20e18.
- `FLOOR_IMB_SCALE`: same role as V7 — floor rises with imbalance. Keep 500e14 or tune so imbFloor in calm is not too high (e.g. floor min ~ 20–25 bps).

**Tuning order:** Set BASE_LOW so that with all additive terms zero, fBase = BASE_LOW and imbFloor = BASE_LOW + FLOOR_IMB_SCALE*imb. Then add SIGMA_COEF, IMB_COEF, VOL_COEF in small steps so that (a) calm fee ~ 28–32 bps, (b) stressed fee grows without exploding (e.g. cap base at 60 bps before downstream terms if needed).

---

## Section 3 — State, Slots, and Pipeline (Unchanged from V7)

**Persistent slots (same as V7):**
- 0: pHat  
- 1: volatility (EWMA of |spot−pHat|/pHat)  
- 2: timestamp  
- 3: sigmaHat  
- 4: toxEma  
- 10–15: temp (reserveX, reserveY, timestamp, isBuy, amountY, vol)

**No new slots.** We do not add prev bid/ask, dirState, lambdaHat, sizeHat, or stepTradeCount in V14.

**Pipeline after base (unchanged):**
1. baseFee = min(rawFee, MAX_FEE_CAP) — rawFee is the new additive base.
2. toxPremium = TOX_COEF*toxEma + TOX_QUAD_COEF*toxEma^2 (vulnerable side only).
3. bidFee/askFee: vulnerable side gets (baseFee + toxPremium) * (1 + ASYMM), other side gets baseFee.
4. Apply dir (only when ret ≤ gate, ret ≥ DIR_RET_THRESHOLD), then surge (when ret > gate), then size bump.
5. Clamp each side to MAX_FEE_CAP (75 or 85 bps).

**pHat / sigma / tox updates:** Exactly as V7: spot-based pHat when ret ≤ gate; sigma updated every trade; tox = min(ret, TOX_CAP), toxEma EWMA. No pImplied, no first-in-step.

---

## Section 4 — Edge Cases, Floor, Decay, Cap

**Init (afterInitialize):**  
- pHat = initialPrice; vol = 0; timestamp = 0; sigmaHat = 95e13 (same as V7); toxEma = 0.  
- Return (BASE_LOW, BASE_LOW) or (imbFloor(0), imbFloor(0)) — use BASE_LOW for simplicity so first swap sees consistent base.

**First trade:** sigmaHat and vol may still be small; imbalance from reserves. fBase = BASE_LOW + IMB_COEF*imb + small sigma/vol terms. Floor ensures we don’t go below BASE_LOW + FLOOR_IMB_SCALE*imb.

**Stale period (timestamp > lastTs):** Same decay as V7: excess = rawFee − imbFloor; decay = (timestamp − lastTs) * (1 − DECAY_FACTOR), capped at 1; rawFee = imbFloor + (1 − decay) * excess. So after long idle, fee decays toward imbFloor.

**Cap:** Keep single hard cap MAX_FEE_CAP (75e14 or 85e14) after all terms. No tail compression in V14.

**Overflow/stack:** Additive base keeps intermediate values smaller than multiplicative (no vol*imb product). If we need to cap the additive base before adding tox/dir/surge/size, we can do `baseFee = min(rawFee, BASE_CAP)` with BASE_CAP e.g. 60e14, then add vulnerable-side terms. Prefer not to add BASE_CAP unless we hit stack or unreasonable fees in testing.

---

## Section 5 — Implementation Plan

**New file:** `amm-challenge/contracts/src/SapientStrategyV14.sol`

**Steps:**
1. Copy `SapientStrategyV7.sol` to `SapientStrategyV14.sol`. Change contract name/comment to V14 rewrite (low base + additive).
2. Replace constants: add BASE_LOW, SIGMA_COEF, IMB_COEF, VOL_COEF; remove or repurpose K_VOL, K_IMB (no longer used in base). Keep BASE_FEE removed; use BASE_LOW. Keep FLOOR_IMB_SCALE; floor = BASE_LOW + FLOOR_IMB_SCALE*imbalance.
3. Replace `_computeRawFee(vol, toxEma, lastTs)` with `_computeRawFeeAdditive(vol, sigmaHat, imbalance, toxEma, lastTs)` that computes fBase = BASE_LOW + SIGMA_COEF*sigmaHat + IMB_COEF*imb + VOL_COEF*vol + symTox(toxEma), then applies floor and decay (same decay logic as V7, using imbFloor based on BASE_LOW).
4. In `afterSwap`, pass sigmaHat and imbalance into the new base computer; keep all other logic (pHat, sigma, tox updates, dir, surge, size, clamp) unchanged.
5. Build and run: `amm-match run contracts/src/SapientStrategyV14.sol --simulations 1000`. Compare edge to V7 (380.14).
6. Tune BASE_LOW, SIGMA_COEF, IMB_COEF, VOL_COEF so that (a) edge ≥ 380, (b) calm-regime fee ~ 28–35 bps. If edge improves, document in changelog and consider adding one of: tail compression, pImplied, or first-in-step in V15.

**Changelog:** Add `docs/2025-02-09-Sapient-V14-rewrite-changelog.md` summarizing the base formula change and initial constants.

---

## Summary Table

| Item              | V7                         | V14 (rewrite)                    |
|-------------------|----------------------------|----------------------------------|
| Base formula      | 35 bps × (1+K_VOL*vol)(1+K_IMB*imb) | BASE_LOW + σ*sigma + imb*coef + vol*coef |
| Sym tox           | same                       | same                             |
| Floor             | BASE_FEE + FLOOR_IMB_SCALE*imb | BASE_LOW + FLOOR_IMB_SCALE*imb |
| Decay             | toward floor when stale     | same                             |
| Downstream        | tox premium, asym, dir, surge, size | unchanged                        |
| Slots             | 0–4, 10–15                 | same                             |
| Cap               | 75 bps                     | 75 (or 85) bps                    |

---

## References

- [2025-02-09-Sapient-what-works-next-big-thing.md](../2025-02-09-Sapient-what-works-next-big-thing.md)
- [2025-02-09-Sapient-audit-380-vs-526.md](../2025-02-09-Sapient-audit-380-vs-526.md)
- [SapientStrategyV7.sol](../../amm-challenge/contracts/src/SapientStrategyV7.sol)
