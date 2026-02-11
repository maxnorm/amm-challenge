# What We Can Use from YQStrategy.sol

**Date:** 2025-02-09  
**Source:** [amm-challenge/contracts/src/refs/YQStrategy.sol](../amm-challenge/contracts/src/refs/YQStrategy.sol)  
**Purpose:** Concrete, copy-pasteable patterns from YQ (~520 edge) that Sapient can adopt without cloning the whole strategy.

---

## 1. Slot Layout (YQ)

| Slot | Content        | Purpose |
|------|----------------|---------|
| 0    | prev bid fee   | pImplied, tail compression |
| 1    | prev ask fee   | pImplied |
| 2    | last timestamp | New-step detection, elapsed |
| 3    | dirState       | Flow direction (WAD = neutral) |
| 4    | actEma         | Activity / trade-size blend |
| 5    | pHat           | EWMA price |
| 6    | sigmaHat       | Volatility (for gate) |
| 7    | lambdaHat      | Trades-per-step estimate |
| 8    | sizeHat        | Smoothed trade size vs reserves |
| 9    | toxEma         | Toxicity EMA |
| 10   | stepTradeCount | Trades in current step (int) |

Sapient V7 already uses: pHat, volatility, timestamp, sigma, toxEma (and temp slots). We have room to add: **prev bid/ask fee**, **dirState**, **actEma**, **sizeHat**, **lambdaHat**, **stepTradeCount** if we reserve slots.

---

## 2. pImplied (Price Signal)

**What YQ does:** Uses the **fee that was just paid** to back out an implied price so pHat and ret don’t overreact to one toxic trade.

```solidity
uint256 feeUsed = trade.isBuy ? prevBidFee : prevAskFee;
uint256 gamma = feeUsed < WAD ? WAD - feeUsed : 0;
uint256 pImplied;
if (gamma == 0) {
    pImplied = spot;
} else {
    pImplied = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
}
// Then: use pImplied (not spot) for ret and pHat update
uint256 ret = pHat > 0 ? wdiv(absDiff(pImplied, pHat), pHat) : 0;
// ...
if (ret <= adaptiveGate) {
    pHat = wmul(pHat, WAD - alpha) + wmul(pImplied, alpha);
}
```

**What we can use:** Store last bid/ask fee (we can reuse fee outputs in next call). Compute `gamma = 1 - feeUsed`, then `pImplied = spot * gamma` (buy) or `spot / gamma` (sell). Use **pImplied** when updating pHat and when computing ret for gate/dir. No new slots if we store prev fees in existing slots.

---

## 3. dirState (Flow Direction)

**What YQ does:** One state centered at WAD. Pushed up on buy (by trade size), down on sell; decay toward WAD by elapsed steps. Fee skew: protect the side that’s been under pressure (higher fee), attract the other (lower fee).

```solidity
// Decay (on new step)
dirState = _decayCentered(dirState, DIR_DECAY, elapsed);

// Update (when trade size above threshold)
if (tradeRatio > SIGNAL_THRESHOLD) {
    uint256 push = tradeRatio * DIR_IMPACT_MULT;
    if (push > WAD / 4) push = WAD / 4;
    if (trade.isBuy) {
        dirState = dirState + push;
        if (dirState > 2 * WAD) dirState = 2 * WAD;
    } else {
        dirState = dirState > push ? dirState - push : 0;
    }
}

// Skew
uint256 dirDev = dirState >= WAD ? dirState - WAD : WAD - dirState;
bool sellPressure = dirState >= WAD;
uint256 skew = wmul(DIR_COEF, dirDev) + wmul(DIR_TOX_COEF, wmul(dirDev, toxSignal));
if (sellPressure) { bidFee = fMid + skew; askFee = fMid - skew; }
else              { askFee = fMid + skew; bidFee = fMid - skew; }
```

**What we can use:** One slot for dirState (WAD = neutral). On new step: decay with `_decayCentered(dirState, DECAY, elapsed)` (we’d need `_powWad` and `_decayCentered`). On trade: if tradeRatio > threshold, push dirState by size (cap push). Then add a skew term to bid/ask from dirDev and optionally dirDev×tox. Gives persistent “who’s hitting us” memory.

---

## 4. Time-Consistent Decay (elapsed)

**What YQ does:** On new step, decays state by **elapsed** steps: `state = state * decay^elapsed` (capped), not a single-step decay.

```solidity
uint256 elapsedRaw = trade.timestamp - lastTs;
uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;
dirState = _decayCentered(dirState, DIR_DECAY, elapsed);
actEma = wmul(actEma, _powWad(ACT_DECAY, elapsed));
// ...
function _powWad(uint256 factor, uint256 exp) internal pure returns (uint256 result) {
    result = WAD;
    while (exp > 0) {
        if (exp & 1 == 1) result = wmul(result, factor);
        factor = wmul(factor, factor);
        exp >>= 1;
    }
}
```

**What we can use:** When `timestamp > lastTs`, set `elapsed = min(timestamp - lastTs, ELAPSED_CAP)` and use `decay^elapsed` for toxEma (and any dirState). Copy `_powWad` for integer exponent in WAD. Makes decay consistent with time without flow.

---

## 5. lambdaHat (Trades per Step)

**What YQ does:** On new step, if there were trades last step, compute instantaneous lambda = stepTradeCount / elapsed and blend into lambdaHat. Use in base fee.

```solidity
if (isNewStep) {
    // ...
    if (stepTradeCount > 0 && elapsedRaw > 0) {
        uint256 lambdaInst = (stepTradeCount * WAD) / elapsedRaw;
        if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
        lambdaHat = wmul(lambdaHat, LAMBDA_DECAY) + wmul(lambdaInst, WAD - LAMBDA_DECAY);
    }
    stepTradeCount = 0;
}
// ... later in same swap:
stepTradeCount = stepTradeCount + 1;
// Base fee:
fBase = BASE_FEE + ... + wmul(LAMBDA_COEF, lambdaHat) + wmul(FLOW_SIZE_COEF, wmul(lambdaHat, sizeHat));
```

**What we can use:** We don’t have “step” as first-class (we have timestamp). We can treat “step” as a time window: e.g. increment a trade count every afterSwap and, when timestamp advances, set lambdaInst = count/elapsed and blend into lambdaHat, then reset count. Adds one or two slots (lambdaHat, stepTradeCount). Fee term: LAMBDA_COEF × lambdaHat and optionally FLOW_SIZE_COEF × lambdaHat × sizeHat.

---

## 6. sizeHat and actEma (Flow Size / Activity)

**What YQ does:**  
- **sizeHat:** Smoothed trade size (tradeRatio), blended with SIZE_BLEND_DECAY, decayed by SIZE_DECAY on new step.  
- **actEma:** Same tradeRatio blended with ACT_BLEND_DECAY, decayed by ACT_DECAY on new step.  
- **flowSize = lambdaHat × sizeHat** goes into base fee.

```solidity
if (tradeRatio > SIGNAL_THRESHOLD) {
    actEma = wmul(actEma, ACT_BLEND_DECAY) + wmul(tradeRatio, WAD - ACT_BLEND_DECAY);
    sizeHat = wmul(sizeHat, SIZE_BLEND_DECAY) + wmul(tradeRatio, WAD - SIZE_BLEND_DECAY);
    if (sizeHat > WAD) sizeHat = WAD;
}
// On new step:
actEma = wmul(actEma, _powWad(ACT_DECAY, elapsed));
sizeHat = wmul(sizeHat, _powWad(SIZE_DECAY, elapsed));
// Fee:
uint256 flowSize = wmul(lambdaHat, sizeHat);
fBase = BASE_FEE + ... + wmul(FLOW_SIZE_COEF, flowSize);
fMid = fBase + ... + wmul(ACT_COEF, actEma);
```

**What we can use:** We already have a **trade-size bump** on the current trade. We can add **sizeHat** (and optionally actEma) as state: blend tradeRatio into sizeHat when tradeRatio > threshold; decay on new step. Add a base term like FLOW_SIZE_COEF × sizeHat (or FLOW_SIZE_COEF × lambdaHat × sizeHat if we add lambdaHat). Uses 1–2 more slots.

---

## 7. Sigma×Tox and Cubic Toxicity

**What YQ does:**  
- **Sigma×tox:** One term in the mid fee: `SIGMA_TOX_COEF * sigmaHat * toxSignal`.  
- **Cubic tox:** `TOX_CUBIC_COEF * toxEma^3`.

```solidity
fMid = fMid + wmul(SIGMA_TOX_COEF, wmul(sigmaHat, toxSignal));
{
    uint256 toxCubed = wmul(toxSignal, wmul(toxSignal, toxSignal));
    fMid = fMid + wmul(TOX_CUBIC_COEF, toxCubed);
}
```

**What we can use:** We already have sigmaHat and toxEma. Add:  
- `sigmaToxBps = SIGMA_TOX_COEF * sigmaHat * toxEma` (tune coef in bps).  
- `toxCubicBps = TOX_CUBIC_COEF * toxEma^3`.  
Add both to our “vulnerable side” premium (or to base). No new slots.

---

## 8. Stale-Dir + Attract (Protect One Side, Discount Other)

**What YQ does:** Add a “stale” term to the side where price is ahead (vulnerable); **subtract** a fraction of that from the other side (attract).

```solidity
uint256 staleShift = wmul(STALE_DIR_COEF, toxSignal);
uint256 attractShift = wmul(staleShift, STALE_ATTRACT_FRAC);
if (spot >= pHat) {
    bidFee = bidFee + staleShift;
    askFee = askFee > attractShift ? askFee - attractShift : 0;
} else {
    askFee = askFee + staleShift;
    bidFee = bidFee > attractShift ? bidFee - attractShift : 0;
}
```

**What we can use:** After we have bid/ask from base+tox+asym+dir+surge+size, add:  
- staleShift = STALE_DIR_COEF × toxEma.  
- If spot ≥ pHat: add staleShift to bid, subtract min(askFee, attractFrac × staleShift) from ask (floor 0).  
- Else: add staleShift to ask, subtract from bid. No new slots; sharpens spread.

---

## 9. Trade-Aligned Toxicity Boost

**What YQ does:** If the **current** trade is “toxic” (buy when spot ≥ pHat, or sell when spot < pHat), add a boost to that side scaled by trade size.

```solidity
bool tradeAligned = (trade.isBuy && spot >= pHat) || (!trade.isBuy && spot < pHat);
if (tradeAligned) {
    uint256 tradeBoost = wmul(TRADE_TOX_BOOST, tradeRatio);
    if (trade.isBuy) bidFee = bidFee + tradeBoost;
    else askFee = askFee + tradeBoost;
}
```

**What we can use:** We already have spot, pHat, tradeRatio, isBuy. Add: tradeAligned = (isBuy && spot ≥ pHat) || (!isBuy && spot < pHat). If true, add TRADE_TOX_BOOST × tradeRatio (capped) to bid or ask. No new slots; directly charges the current trade when it’s toxic.

---

## 10. Tail Compression (Smooth Cap)

**What YQ does:** Instead of a hard cap, compress the fee above a “knee”: fee_compressed = knee + slope × (fee - knee). Different slopes for “protect” vs “attract” side.

```solidity
function _compressTailWithSlope(uint256 fee, uint256 slope) internal pure returns (uint256) {
    if (fee <= TAIL_KNEE) return fee;
    return TAIL_KNEE + wmul(fee - TAIL_KNEE, slope);
}
// Apply per side (then clamp to MAX_FEE):
if (sellPressure) {
    bidFee = clampFee(_compressTailWithSlope(bidFee, TAIL_SLOPE_PROTECT));
    askFee = clampFee(_compressTailWithSlope(askFee, TAIL_SLOPE_ATTRACT));
} else {
    askFee = clampFee(_compressTailWithSlope(askFee, TAIL_SLOPE_PROTECT));
    bidFee = clampFee(_compressTailWithSlope(bidFee, TAIL_SLOPE_ATTRACT));
}
```

**What we can use:** After computing bid/ask, apply _compressTailWithSlope with a knee (e.g. 5 bps) and slope (e.g. 0.93 protect, 0.955 attract), then clamp to MAX_FEE. Replaces or sits alongside our current 75 bps hard cap so we don’t clip as harshly.

---

## 11. PHAT_ALPHA for First-in-Step vs Retail

**What YQ does:** Uses a **faster** pHat blend for the first trade in a step (PHAT_ALPHA) and a **slower** one for subsequent trades in the same step (PHAT_ALPHA_RETAIL). Also updates sigma only on first-in-step.

```solidity
bool firstInStep = stepTradeCount == 0;
// ...
uint256 alpha = firstInStep ? PHAT_ALPHA : PHAT_ALPHA_RETAIL;
if (ret <= adaptiveGate) {
    pHat = wmul(pHat, WAD - alpha) + wmul(pImplied, alpha);
}
if (firstInStep) {
    if (ret > RET_CAP) ret = RET_CAP;
    sigmaHat = wmul(sigmaHat, SIGMA_DECAY) + wmul(ret, WAD - SIGMA_DECAY);
}
```

**What we can use:** If we add stepTradeCount (or a “first trade this step” flag), we can use a larger alpha when firstInStep and a smaller one otherwise, and update sigmaHat only when firstInStep. Makes pHat/sigma more responsive to the first move in a step and less to follow-up noise.

---

## 12. Summary: What to Adopt First (Sapient)

| Concept           | New slots | Effort | Use in Sapient |
|-------------------|-----------|--------|----------------|
| **pImplied**      | 0 (store prev fee) | Low  | Cleaner pHat/ret; less lag |
| **Sigma×tox + cubic tox** | 0 | Low  | Sharper fee when wrong + volatile |
| **Trade-aligned boost**   | 0 | Low  | Charge current toxic trade by size |
| **Stale + attract**       | 0 | Low  | Widen spread; attract rebalancing |
| **Tail compression**     | 0 | Low  | Softer than hard 75 bps cap |
| **dirState**      | 1 | Medium | Persistent flow direction |
| **Time decay^elapsed**    | 0 | Low  | _powWad + decay on new step |
| **lambdaHat + step count**| 2 | Medium | Activity in base fee |
| **sizeHat / actEma**      | 1–2 | Medium | Flow size in base fee |
| **First-in-step alpha**   | 0 if we have step count | Low | Better pHat/sigma update |

**Suggested order for V8:**  
1) Cap raise (85–100 bps).  
2) pImplied for pHat/ret.  
3) Sigma×tox + cubic tox.  
4) Trade-aligned boost.  
5) Tail compression or stale+attract (one of the two).  
Then, if still under 400: dirState, then lambdaHat/sizeHat/actEma.
