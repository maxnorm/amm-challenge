# Sapient V7 — Why We're Stuck Under 400 (Edge 380.14)

**Date:** 2025-02-09  
**Context:** V7 implements Approach A (dir-only-when-no-surge, scaled surge, sym-tox high, size bump).  
**Observed:** Edge **380.14** (1000 sims) — up from V6 ~374 but still below 400.  
**Goal:** Diagnose why we plateau below 400, identify remaining exploit vectors and failure modes, and propose next-step designs.

---

## Step 1 — Loss Diagnosis (Why Still Under 400)

### What V7 already fixed (from V6)

- **Dir only when ret ≤ gate** — Dir and surge no longer overlap; surge gets headroom.
- **Scaled surge** — 15–40 bps by (ret − gate) instead of fixed 25 bps.
- **Stronger symmetric tox** — Extra term when toxEma ≥ 1.5%.
- **Trade-size bump** — Up to 20 bps on the side hit, by amountY/reserveY (capped 20%).

So the gain 374 → 380 shows these changes help, but **~20 points** remain to reach 400.

### Mechanical reasons we're still stuck

1. **75 bps cap is binding**  
   V7 (and V6) use `MAX_FEE_CAP = 75e14` (75 bps). V4/V5 used **100 bps**. Base + vol×K_VOL + imb×K_IMB + sym-tox + floor + tox premium + asym (60%) + surge (up to 40 bps) + size bump (up to 20 bps) can easily exceed 75 bps on the vulnerable side. The cap clips the **marginal** gain from surge and size bump exactly when we want to charge most (large, toxic moves). So we are leaving edge on the table by clamping at 75 bps. Raising the cap toward 100 bps (or testing 85–90) could recover 5–15 points if the sim mix allows it without killing volume.

2. **pHat lag is unchanged**  
   We still update pHat with spot when ret ≤ gate; directionality uses spot ≥ pHat. In trends, pHat lags, so we still sometimes raise the wrong side (e.g. ask while the next hit is bid). V7 did not add pImplied or any cleaner price signal. So directionality remains noisy and caps how much we can lean on it.

3. **No flow-direction memory**  
   We have no notion of “who has been hitting us” over time (dirState). So we don’t persistently protect the side under pressure; we only react to current reserves and spot vs pHat. Arb can still fade by trading the side we didn’t just surge.

4. **Symmetric tox and size bump are conservative**  
   SYM_HIGH adds 25 bps per unit tox above 1.5%; size bump is capped at 20 bps and trade ratio at 20%. In high-tox or large-trade regimes we might be undercharging the non-vulnerable side and undercharging large trades relative to impact.

5. **No activity or “flow size” in base**  
   We don’t use trade count per step or a smoothed flow-size (actEma, sizeHat, lambdaHat). So we don’t charge more when **activity** is high; we only charge more by size on the current trade. High-activity toxic regimes may still be under-priced.

6. **Decay is per-step, not time-consistent**  
   Decay uses a fixed step factor. We don’t use decay^elapsed for time without flow, so long idle periods don’t decay state more than one step — minor, but can leave stale tox/vol slightly high.

**Summary:** The main structural limits are: **(a) 75 bps cap** clipping surge and size bump on the worst flow, **(b) unchanged pHat/dir logic** so directionality is still noisy, **(c) no flow-direction memory** so we don’t persistently protect the pressured side, and **(d) conservative coefficients and no activity term** so we undercharge in high-tox and high-activity regimes.

---

## Step 2 — Adversarial Exploitation (V7)

1. **Cap arbitrage at 75 bps**  
   Whenever true fee would be 80–100 bps we output 75. The arb’s profit on those trades is larger than we’ve priced; we cannot recover that margin.

2. **Fade the surge side**  
   After a gate breach we add surge to one side. The next trade on the **other** side (reversion) sees only base + sym-tox + maybe dir. So arb can wait for a large move (surge fires), then trade the opposite side at lower fee.

3. **Grind directionality**  
   Dir still uses spot ≥ pHat with laggy pHat. In choppy regimes we still sometimes add dir to ask, sometimes to bid. A bot that trades when dir has just been applied to the other side gets the non-dir side.

4. **Size timing**  
   Size bump is capped at 20 bps and trade ratio at 20%. One very large trade (e.g. 30% of reserve) is still undercharged relative to impact; splitting into one big hit plus revert is still attractive.

5. **Regime selection**  
   In regimes where we often hit the 75 bps cap, all marginal improvements (surge, size) are clipped. Adversaries that trade mainly in those regimes extract more.

---

## Step 3 — Failure Modes (V7)

| Regime / condition           | V7 limitation                              | Effect                                      |
|-----------------------------|--------------------------------------------|---------------------------------------------|
| High tox, near 75 bps cap   | base + sym + tox + asym + surge + size → cap | Cap clips; we undercharge the worst flow   |
| Trending                    | pHat lags; dir often wrong side             | Dir adds to ask while bid gets hit          |
| Choppy (ret ~ 0.5%)         | Dir flips with spot vs pHat                 | Small net gain; can be faded                |
| Large single trade          | Size bump capped at 20 bps, ratio 20%       | Still undercharge vs impact                 |
| High activity (many trades) | No lambdaHat/actEma in fee                 | No extra charge for flow intensity          |
| Post–gate breach            | Surge on one side only                     | Reversion on other side at lower fee        |
| Non-vulnerable side at high tox | Sym-tox + SYM_HIGH still modest         | Arb can still fade at lower fee             |

---

## Step 4 — New Strategy Ideas (To Cross 400)

**A. Raise cap to 85–100 bps (low risk)**  
- **Idea:** Set `MAX_FEE_CAP = 85e14` or `100e14`.  
- **Addresses:** Cap binding; gives surge and size bump headroom.  
- **Risk:** If the sim penalizes high fees (volume loss / toxic selection), edge might drop; need to test.

**B. pImplied for pHat and ret (medium risk)**  
- **Idea:** Use fee just paid to back out implied price: γ = 1 − feeUsed, pImplied = spot×γ (buy) or spot/γ (sell). Update pHat and/or ret from pImplied instead of raw spot.  
- **Addresses:** pHat lag and dir noise; one toxic trade doesn’t drag pHat as much.  
- **Needs:** Store previous bid/ask fee (or fee used) and use in next step.

**C. dirState (flow-direction memory) (medium risk)**  
- **Idea:** One slot: centered at WAD; push up on buy (by size), down on sell; decay toward WAD by elapsed steps. Use distance from WAD to skew bid vs ask (e.g. add to the side that’s been hit more).  
- **Addresses:** No persistent “who’s hitting us”; makes it harder to fade the surge by trading the other side once.

**D. Stronger sym-tox and size (low–medium risk)**  
- **Idea:** (1) Increase SYM_HIGH_COEF or add a cubic sym term at very high toxEma. (2) Raise CAP_SIZE_BPS or TRADE_RATIO_CAP so we charge more on larger trades.  
- **Addresses:** Non-vulnerable side still cheap at high tox; large trades still undercharged.

**E. Sigma×tox and cubic tox (medium risk)**  
- **Idea:** Add `SIGMA_TOX_COEF × sigmaHat × toxEma` and/or `TOX_CUBIC × toxEma³` on the vulnerable side (or symmetric).  
- **Addresses:** When we’re both wrong and volatile, fee should rise more sharply.

**F. Trade-aligned toxicity boost (medium risk)**  
- **Idea:** If current trade is “toxic” (e.g. buy when spot ≥ pHat), add `K_TRADE_TOX × tradeRatio` (capped) to the **next** fee on that side (or to the same side for the next trade).  
- **Addresses:** Follow-up arb on the same side; charges more when the last trade was large and toxic.

---

## Step 5 — Formulas & Pseudocode

**A. Cap raise**
```solidity
uint256 constant MAX_FEE_CAP = 85e14;  // or 100e14; test both
```

**B. pImplied (minimal)**
```text
// After swap: store fee used (e.g. bidFee if buy, askFee if sell)
// Next step:
gamma = ONE_WAD - feeUsed;
pImplied = isBuy ? _wmul(spot, gamma) : _wdiv(spot, gamma);
// Use pImplied instead of spot when updating pHat and when computing ret for gate/dir
ret = pHat > 0 ? _wdiv(_abs(pImplied, pHat), pHat) : 0;
// And: pHat blend with pImplied when ret <= gate
```

**C. dirState**
```text
// Slot: dirState (WAD = neutral, > WAD = more buys, < WAD = more sells)
// On trade: sizeFactor = min(tradeRatio, CAP)
//   if isBuy: dirState = dirState + _wmul(DIR_PUSH, sizeFactor)
//   else:     dirState = dirState - _wmul(DIR_PUSH, sizeFactor)
// On new step (timestamp > lastTs): elapsed = min(timestamp - lastTs, ELAPSED_CAP)
//   dirState = WAD + _wmul(dirState - WAD, _pow(DECAY, elapsed))
// In fee: dirSkew = (dirState - WAD) * DIR_SKEW_COEF (capped)
//   if dirSkew > 0: askFee += dirSkew (more buys recently → protect ask)
//   else: bidFee += |dirSkew|
```

**D. Stronger sym and size**
```text
// Option 1: SYM_HIGH_COEF 25 → 35e14; or add SYM_CUBIC * toxEma³ for toxEma > 2%
// Option 2: CAP_SIZE_BPS 20 → 25e14; TRADE_RATIO_CAP 20% → 30%
```

**E. Sigma×tox and cubic tox**
```text
// sigmaToxBps = _wmul(SIGMA_TOX_COEF, _wmul(sigmaHat, toxEma));
// toxCubicBps = _wmul(TOX_CUBIC, _wmul(toxEma, _wmul(toxEma, toxEma)));
// Add to vulnerable side (or to base): toxPremium += sigmaToxBps + toxCubicBps;
```

**F. Trade-aligned boost**
```text
// tradeAligned = (isBuy && spot >= pHat) || (!isBuy && spot < pHat);
// if (tradeAligned) { boost = _wmul(K_TRADE_TOX, tradeRatio); if (boost > CAP) boost = CAP; }
// if (isBuy) bidFeeOut = _clampFee(bidFeeOut + boost); else askFeeOut = _clampFee(askFeeOut + boost);
```

---

## Step 6 — Simulation Blueprint

- **Inputs:** Same harness, 1000 sims, same baseline; same seeds if possible for comparability.
- **Metrics:**  
  - Edge (primary).  
  - % of steps where fee hit cap (vulnerable vs non-vulnerable).  
  - Surge fire rate and average fee on those steps.  
  - Average size bump applied.  
  - (If cap raised) Distribution of fee before clamp (how often we would exceed 75 vs 85 vs 100 bps).
- **Scenarios:**  
  - **V8-cap:** V7 + MAX_FEE_CAP = 85e14; then 100e14.  
  - **V8-tune:** V7 + stronger SYM_HIGH/size caps (D).  
  - **V8-pImplied:** V7 + pImplied for pHat/ret (B).  
  - **V8-dirState:** V7 + dirState (C).  
  - **V8-combo:** Cap 85 + (B or C) or (D).
- **Criteria:** Edge ≥ 400; cap-hit rate and fee distribution to ensure we’re not just shifting clipping; no large variance increase across runs.

---

## Step 7 — Recommendation

**Priority to cross 400:**

1. **Raise cap to 85 bps, then 100 bps (A)**  
   Lowest effort; directly addresses the binding cap. Run V7 with `MAX_FEE_CAP = 85e14` and then `100e14`. If edge rises and cap-hit rate drops, we’ve confirmed cap was the main ceiling. If edge falls (volume/toxicity effect), revert and keep 75.

2. **Stronger sym-tox and size caps (D)**  
   Small constant changes: SYM_HIGH_COEF up, CAP_SIZE_BPS and/or TRADE_RATIO_CAP up. Quick test to see if we’re leaving money on the table in high-tox and large-trade regimes.

3. **pImplied (B) or dirState (C)**  
   One of these for a cleaner price signal or flow-direction memory. Prefer **pImplied** first (fewer slots, addresses dir noise directly); if we add one slot and still below 400, add **dirState** in a follow-up.

4. **Sigma×tox and cubic tox (E)**  
   Add once A–D are in place, if we need more sensitivity in high-volatility, high-tox regimes.

**Suggested next step:** Implement **V8** in a new contract file (e.g. `SapientStrategyV8.sol`):  
- **Baseline:** V7 logic.  
- **Change 1:** `MAX_FEE_CAP = 85e14` (or 100e14).  
- **Change 2 (optional):** Slightly stronger SYM_HIGH and/or size caps per (D).  
Run `amm-match run contracts/src/SapientStrategyV8.sol --simulations 1000` and compare edge to 380.14. If edge ≥ 400, document and keep. If not, add pImplied (B) in the same or next version and re-run.

---

## Summary Table

| Cause we're stuck under 400     | Fix (next version)              |
|---------------------------------|----------------------------------|
| 75 bps cap clips surge/size     | Raise cap to 85–100 bps          |
| pHat lag, dir noisy             | pImplied for pHat/ret            |
| No flow-direction memory        | dirState                         |
| Conservative sym/size           | Stronger SYM_HIGH, size caps     |
| No vol×tox or cubic tox         | Sigma×tox, cubic tox term        |

---

## Changelog

- **2025-02-09:** Initial analysis: V7 edge 380.14; diagnosis (cap, pHat, no dirState, conservative params); exploit vectors; failure modes; ideas A–F; formulas; simulation plan; recommendation (cap raise first, then tune, then pImplied/dirState).
