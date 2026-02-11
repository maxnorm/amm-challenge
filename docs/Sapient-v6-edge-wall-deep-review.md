# Sapient v6 — Edge Wall at 374.54: Deep Review (AMM Fee Designer)

**Observed:** V6 (sym-tox floor + strong dir + surge) **Edge 374.54** — same as V4/V5. We have hit a plateau.  
**Goal:** Diagnose why the strategy is stuck, identify exploit vectors and failure modes, and propose designs to break above 374.54.

---

## Step 1 — Loss Diagnosis (Why We're Stuck at 374.54)

### What V6 does

- **Base:** 30 bps + vol×K_VOL + imb×K_IMB, then symmetric tox (12 bps linear + 30 bps quad in toxEma), imbalance floor, decay, cap 100 bps.
- **Vulnerable side:** + tox premium (25 bps linear + 60 bps quad) + 60% asymmetry.
- **Directionality:** Only when ret ≥ 0.5%; add up to 30 bps to ask if spot ≥ pHat else to bid.
- **Surge:** 25 bps on the side just hit when ret > adaptiveGate.

### Mechanical reasons we plateau

1. **100 bps cap binds on the wrong trades**  
   When base + sym-tox + floor + tox premium + asym + dir + surge are summed, the vulnerable side often hits 100 bps. The cap clips the *marginal* gain from directionality and surge. So we cannot charge more exactly when we want to (large toxic move). The ceiling is structural: we're leaving edge on the table by clamping.

2. **Directionality and surge overlap the same side**  
   When ret > gate we add both dir (if ret ≥ 0.5%) and surge. Both add to the same leg (e.g. ask). So we get dir + 25 bps surge, but the cap then truncates. If we *didn't* have dir on that trade, we'd have more headroom for surge. The two mechanisms compete for the same 100 bps budget instead of being coordinated.

3. **pHat lag in trends makes dir noisy**  
   In a strong trend, pHat updates only when ret ≤ gate, so it lags. We add dir based on spot ≥ pHat. When lag is large, "spot ≥ pHat" can be true for many steps while the next move is actually down (mean reversion). So we raise ask repeatedly; arb or reversion hits bid. Directionality then *mis*-prices as often as it helps in the simulation mix, limiting net edge.

4. **Symmetric tox is small and fixed**  
   SYM_TOX (12 + 30×tox²) raises both sides when toxEma is high, which helps the non-vulnerable side. But the coefficients are modest. If the sim has a lot of flow on the non-vulnerable side at high tox, we're still cheaper there than the full tox+asym on the vulnerable side. So we've only *partially* closed the arb gap on the cheap side; the rest averages into the same edge.

5. **No notion of trade size or step activity**  
   We have no `amountX`/`amountY` or trade count. A single large toxic trade and ten small ones are treated the same after the fact. Fee is purely state-based (reserves, pHat, vol, toxEma). So we cannot charge more for the *current* trade's size, which is where LVR and adverse selection are largest. Our improvements (dir, surge) are still one-size-fits-all per step.

6. **Surge is one-shot and gate-driven**  
   Surge applies only when ret > gate. Gate = max(σ×10, 3%). So in low-vol regimes surge rarely fires; in high-vol it fires often but we're already near cap. So surge either doesn't apply or gets clamped. We don't have a *size*- or *impact*-based surge (e.g. scaled by trade amount / reserves).

**Summary:** The wall is not a single bug but a combination: (a) **cap binding** on the side we want to charge most, (b) **dir and surge sharing the same budget** and both using laggy pHat, (c) **symmetric tox** only partly raising the cheap side, and (d) **no trade-size or per-trade impact** so we can't target the largest toxic trades. The simulation's mix of arb vs retail and of volatility regimes makes these effects balance out at ~374.54.

---

## Step 2 — Adversarial Exploitation (How to Exploit V6)

1. **Trade the side that just got surge**  
   After a gate breach we add 25 bps to that side. The *next* trade on that same side still has elevated base + tox. But if the next trade is the *other* side (reversion), it only has base + sym-tox + maybe dir. So an arb can *fade* the surge: wait for a large move (surge fires), then trade the opposite side at relatively lower fee. We've concentrated fee on one leg; the other remains cheaper.

2. **Grind directionality**  
   We add dir when ret ≥ 0.5% and spot ≥ pHat (ask) or spot < pHat (bid). In a choppy market, ret often just above 0.5% and spot crosses pHat often. So we sometimes add 30 bps to ask, sometimes to bid. A bot that trades when dir has *just* been applied to the other side gets the side we didn't raise. So dir can be faded by trading the non-dir side.

3. **Cap arbitrage**  
   When our fee would be 110 bps we output 100. The arb's profit on that trade is higher than we've priced. So any scenario that would imply fee > 100 bps is exploited at the cap; we cannot recover that margin.

4. **Size timing**  
   One large toxic trade pays the same fee as one small one (same state after). So splitting a large order into one big hit and then reverting is equivalent to paying once at the current fee. We don't charge more for the size of the hit, so large informed flow is undercharged relative to its impact.

5. **Volatility regime selection**  
   In low σ, gate is 3% (MIN_GATE). Surge rarely fires. In high σ, gate is large, so ret > gate is less frequent unless the move is very large. So surge is either rare or we're already at high fee. An adversary that trades mainly in regimes where surge doesn't fire (or is capped) extracts more.

---

## Step 3 — Failure Mode Identification

| Regime / condition        | V6 limitation                              | Effect                                   |
|---------------------------|--------------------------------------------|------------------------------------------|
| High tox, near cap        | base + sym + tox + asym + dir + surge → cap | Cap clips; we undercharge the worst flow |
| Trending                  | pHat lags; dir often wrong side             | Dir adds to ask while bid gets hit       |
| Choppy (ret ~ 0.5%)       | Dir flips often                             | Small net gain; can be faded             |
| Large single trade        | No size term                                | Undercharge vs impact                    |
| Low vol                   | Gate = 3%; surge rare                       | Little extra capture                     |
| Non-vulnerable side flow  | Only sym-tox (12+30×tox²)                   | Still cheaper than vulnerable side       |
| Post–gate breach          | Surge on one side only                      | Reversion on other side at lower fee     |

---

## Step 4 — New Strategy Ideas (To Break the Wall)

**A. Coordinated cap / priority (dir vs surge)**  
- **Idea:** When both dir and surge would apply, give **priority** to the one that captures more from *this* trade. E.g. if ret > gate, **don't** add dir on the same side; add only surge. So surge gets full headroom (e.g. 25 bps) before cap. Dir then applies only when ret ≤ gate (no surge).  
- **Addresses:** Dir and surge competing for the same 100 bps; ensures surge isn't clipped by dir on the same leg.

**B. Surge scaled by return (above gate)**  
- **Idea:** Instead of fixed 25 bps, set `surge = SURGE_BASE + SURGE_COEF * (ret - gate)` (capped). So the larger the breach, the larger the surge.  
- **Addresses:** One-shot surge being too small for very large moves; we capture more when ret is far above gate.

**C. Trade-size–based fee bump (within same step)**  
- **Idea:** Use `tradeRatio = amountX / reserveX` (or amountY/reserveY) as a proxy for trade size. Add a fee term like `sizeBps = min(K_SIZE * tradeRatio, CAP_SIZE_BPS)` to the side that was just hit. No new state; purely from `TradeInfo`.  
- **Addresses:** No differentiation by size; large toxic trades currently undercharged.

**D. Asymmetric cap or higher effective cap on toxic side**  
- **Idea:** Contract may allow up to MAX_FEE (e.g. 10%). If we're allowed more than 100 bps, raise cap on the vulnerable side only (e.g. 120 bps) when toxEma is above a threshold, keep 100 bps on the other side.  
- **Addresses:** Cap binding on the side we want to charge most. (Only if rules allow.)

**E. Stronger symmetric tox when toxEma is high**  
- **Idea:** Make sym-tox **non-linear**: e.g. sym-tox = SYM_COEF*toxEma + SYM_QUAD*toxEma² + SYM_HIGH*(max(0, toxEma - THRESHOLD)) when toxEma > 1.5%. So above a threshold we raise both sides more.  
- **Addresses:** Non-vulnerable side still too cheap at high tox; reduces arb profit on that side.

**F. Directionality only when gate is not breached**  
- **Idea:** Apply dir **only when ret ≤ adaptiveGate**. When ret > gate we treat as toxic and use surge only (no dir). So we never add both on the same trade; dir is for "moderate" moves, surge for "cap" moves.  
- **Addresses:** Overlap and cap clipping; simplifies logic (same as A but framed as condition on ret).

---

## Step 5 — Formulas & Pseudocode

**A. Dir only when no surge (priority)**
```
// After computing baseFee, tox, asym, dirPremium, surge:
if (ret > adaptiveGate) {
  // Surge side: add only surge, no dir on this side
  if (trade.isBuy) bidFeeOut = clamp(bidFeeOut + SURGE_BPS);
  else askFeeOut = clamp(askFeeOut + SURGE_BPS);
} else {
  // No surge: allow directionality
  if (ret >= DIR_RET_THRESHOLD) {
    dirPremium = min(ret * DIR_BPS_PER_UNIT_RET, CAP_DIR_BPS);
    if (spot >= pHat) askFeeOut = clamp(askFeeOut + dirPremium);
    else bidFeeOut = clamp(bidFeeOut + dirPremium);
  }
}
```

**B. Surge scaled by breach size**
```
SURGE_BASE = 15e14;   // 15 bps minimum
SURGE_COEF = 2e18;   // 2 bps per 1% above gate (in WAD)
CAP_SURGE = 40e14;   // 40 bps max
if (ret > adaptiveGate) {
  uint256 excessRet = ret - adaptiveGate;
  uint256 surge = SURGE_BASE + _wmul(SURGE_COEF, excessRet);
  if (surge > CAP_SURGE) surge = CAP_SURGE;
  if (trade.isBuy) bidFeeOut = clamp(bidFeeOut + surge);
  else askFeeOut = clamp(askFeeOut + surge);
}
```

**C. Trade-size bump**
```
// tradeRatio in WAD: amountX / reserveX (post-trade reserves are before or after? use post-trade for reserve)
uint256 tradeRatio = trade.reserveX > 0 ? _wdiv(trade.amountX, trade.reserveX) : 0;
if (tradeRatio > 1e18) tradeRatio = 1e18;  // cap
K_SIZE = 50e14;   // 50 bps per 100% of reserve (scale down)
CAP_SIZE_BPS = 20e14;
uint256 sizeBps = _wmul(K_SIZE, tradeRatio);
if (sizeBps > CAP_SIZE_BPS) sizeBps = CAP_SIZE_BPS;
if (trade.isBuy) bidFeeOut = clamp(bidFeeOut + sizeBps);
else askFeeOut = clamp(askFeeOut + sizeBps);
```
Note: Check TradeInfo — if reserves are *post*-trade, use pre-trade reserves from state or approximate.

**E. Stronger symmetric tox at high toxEma**
```
SYM_HIGH_THRESH = 15e15;  // 1.5%
SYM_HIGH_COEF = 25e14;    // 25 bps per unit above threshold
uint256 symTox = SYM_TOX_COEF*toxEma + SYM_TOX_QUAD*toxEma²;
if (toxEma >= SYM_HIGH_THRESH)
  symTox += _wmul(SYM_HIGH_COEF, toxEma - SYM_HIGH_THRESH);
rawFee += symTox;
```

**F. Dir only when ret ≤ gate (no overlap)**
```
if (ret <= adaptiveGate && ret >= DIR_RET_THRESHOLD) {
  dirPremium = min(ret * DIR_BPS_PER_UNIT_RET, CAP_DIR_BPS);
  if (spot >= pHat) askFeeOut += dirPremium; else bidFeeOut += dirPremium;
}
if (ret > adaptiveGate) {
  // surge only
  if (trade.isBuy) bidFeeOut += SURGE_BPS; else askFeeOut += SURGE_BPS;
}
```

---

## Step 6 — Simulation Blueprint

- **Inputs:** Same 1000 sims, same baseline; same harness and seeds if possible.
- **Metrics:**  
  - Edge (primary).  
  - Fee capture ratio, average bid/ask fees.  
  - % of steps where fee hit cap (vulnerable vs non-vulnerable).  
  - Surge fire rate (ret > gate) and average fee on those steps.
- **Scenarios:**  
  - **V7-A:** V6 + dir only when ret ≤ gate (no dir when surge fires).  
  - **V7-B:** V6 + scaled surge (B).  
  - **V7-C:** V6 + trade-size bump (C) — if TradeInfo allows.  
  - **V7-D:** V6 + stronger sym-tox at high tox (E).  
  - **V7-AB:** A + B.  
  - **V7-full:** A + B + D (and C if feasible).
- **Criteria:** Edge > 374.54; prefer stable or improved variance across runs; monitor cap-hit rate to ensure we're not just shifting where we clip.

---

## Step 7 — Recommendation

**Priority for V7:**

1. **Dir only when ret ≤ gate (F / A)**  
   Implement directionality only when we do *not* apply surge. This removes overlap, gives surge full headroom under the cap, and avoids double-adding on the same side. Low implementation cost, clear structural fix.

2. **Scaled surge (B)**  
   Replace fixed 25 bps with surge = f(ret - gate) capped (e.g. 15 + 2×(ret - gate) bps, cap 40 bps). Captures more on the largest moves without over-charging small breaches. Moderate implementation cost.

3. **Stronger symmetric tox at high tox (E)**  
   Add a term when toxEma > 1.5% so the non-vulnerable side isn’t as cheap in high-tox regimes. Reduces arb on that side. Low implementation cost.

4. **Trade-size bump (C)**  
   Add only if `TradeInfo` exposes amount and we can define a stable trade ratio (e.g. amount vs reserve). Check harness for pre- vs post-trade reserves. If feasible, add a small size-based bump to the side just hit.

**Implementation:** New file `VIAFStrategyV7.sol` with:
- Same base as V6 (base, sym-tox, floor, decay, tox on vulnerable, asym).
- **Change:** Apply dir only when `ret <= adaptiveGate` and `ret >= DIR_RET_THRESHOLD`. Apply surge only when `ret > adaptiveGate` (scaled surge optional).
- **Optional:** SYM_HIGH term for toxEma above threshold; size bump from TradeInfo if available.

**Run:**  
`amm-match run contracts/src/VIAFStrategyV7.sol --simulations 1000`  
Compare Edge to 374.54 and check cap-hit rate.

---

## Summary Table (Why Wall at 374.54)

| Cause                          | Fix (V7)                          |
|--------------------------------|-----------------------------------|
| Cap binds on vulnerable side   | Dir only when no surge (more headroom) |
| Dir + surge same side           | Dir only when ret ≤ gate          |
| Surge too small on big moves    | Scaled surge by (ret - gate)     |
| Non-vulnerable side cheap      | Stronger sym-tox at high toxEma  |
| No size differentiation        | Size bump from TradeInfo (if ok) |

---

## Changelog — V6 cap: remove then restore (why the drop)

**2025-02-09 — Cap removed:** The 100 bps self-cap was removed so the strategy could use the challenge max (10%). **Result: Edge collapsed from 374.54 to 112.14.**

**Why the big drop:** Without the cap, the fee formula can output **2–5% or more** on the vulnerable side. Example: base 30 bps × (1 + K_VOL×vol) × (1 + K_IMB×imb) with high vol/imb gives 150–200+ bps; add sym-tox, floor, then ×1.6 (asym) + dir (30 bps) + surge (25 bps) → 300–400+ bps easily, and in stressed regimes much higher. So we were no longer “a bit above 100 bps”; we were often at **2–4%**. That (a) **kills volume** — traders don’t trade at 3% — and/or (b) **selects for only toxic flow** — only those willing to pay 3% trade, so adverse selection worsens. The simulation’s edge metric (likely LP PnL or fee capture vs losses) then collapses: we over-charge, lose volume and benign flow, and net edge drops. The 100 bps cap was a **guardrail** that kept fees in a range where the strategy still gets a healthy mix of flow and volume.

**2025-02-09 — Cap restored:** In `VIAFStrategyV6.sol`, the 100 bps cap was restored (`MAX_FEE_CAP = 100e14`, `_clampFee()`). So we keep the design that gave Edge ~374, and avoid the “runaway fee” regime that gave Edge ~112.
