# Sapient V18 — pImplied Only on V14 — Implementation Plan

**Date:** 2025-02-09  
**Source:** [2025-02-09-Sapient-other-levers-research.md](2025-02-09-Sapient-other-levers-research.md) (recommendation #1)  
**Baseline:** V14 = 380.13 edge (75 bps, additive base).  
**Goal:** V18 = V14 + **pImplied only** (2 slots: prev bid, prev ask). No other levers. If edge ≥ 382, keep; else cleaner baseline for next levers.

---

## 1. Scope

| Include | Exclude |
|--------|--------|
| pImplied for `ret` and pHat update (when ret ≤ gate) | dirState, stale+attract, trade-aligned boost |
| 2 new slots: prev bid fee, prev ask fee | sigma×tox, cubic tox (keep V14’s linear + quad only) |
| Store `prevBid = bidFeeOut`, `prevAsk = askFeeOut` at end of `afterSwap` | first-in-step, lambda/size/flow (V14 has none) |

**Contract:** New file `SapientStrategyV18.sol`, copy of V14 with the minimal pImplied changes below.

---

## 2. Changes from V14

### 2.1 Storage

- Add two slot constants and use them (no change to existing slot indices):
  - `SLOT_PREV_BID` = 5  
  - `SLOT_PREV_ASK` = 6  

### 2.2 Initialization (`afterInitialize`)

- After setting V14’s slots, set:
  - `slots[SLOT_PREV_BID] = BASE_LOW`
  - `slots[SLOT_PREV_ASK] = BASE_LOW`
- Return `(BASE_LOW, BASE_LOW)` unchanged.

### 2.3 Fee / price block in `afterSwap` (replace spot-based ret/pHat)

**Current V14 (spot-based):**

```solidity
ret = pHat > 0 ? _wdiv(_abs(spot, pHat), pHat) : 0;
// ...
if (ret <= adaptiveGate) {
    pHat = _wmul(ONE_WAD - PHAT_ALPHA, pHat) + _wmul(PHAT_ALPHA, spot);
}
```

**V18 (pImplied):**

- Read `prevBid = slots[SLOT_PREV_BID]`, `prevAsk = slots[SLOT_PREV_ASK]`.
- `feeUsed = trade.isBuy ? prevBid : prevAsk`
- `gamma = feeUsed < ONE_WAD ? ONE_WAD - feeUsed : 0`
- `pImplied = (gamma == 0) ? spot : (trade.isBuy ? _wmul(spot, gamma) : _wdiv(spot, gamma))`
- `ret = pHat > 0 ? _wdiv(_abs(pImplied, pHat), pHat) : 0` (cap with RET_CAP as in V14).
- `adaptiveGate` unchanged.
- pHat update: `if (ret <= adaptiveGate) { pHat = _wmul(ONE_WAD - PHAT_ALPHA, pHat) + _wmul(PHAT_ALPHA, pImplied); }`
- `sigmaHat` update: keep using `ret` (already based on pImplied).
- **Tox:** keep V14’s definition. Research doc uses ret for gate/pHat; tox in V14 is derived from `ret` (line 195). So keep `tox = ret > TOX_CAP ? TOX_CAP : ret` (ret is already pImplied-based).
- **Volatility (SLOT_TEMP_VOL):** keep V14’s formula; can keep spot for vol (no doc requirement to use pImplied for vol). Optional: use pImplied for vol for consistency—document either way.

### 2.4 Persist prev fees

- After computing `bidFeeOut` and `askFeeOut`, before `return`:
  - `slots[SLOT_PREV_BID] = bidFeeOut`
  - `slots[SLOT_PREV_ASK] = askFeeOut`

### 2.5 Downstream (dir/surge/size)

- `_applyDirSurgeAndSize(ret, adaptiveGate, spot, pHat, ...)`: keep signature. `ret` and `pHat` are already pImplied-driven; keep passing `spot` for the “spot ≥ pHat” direction check (or pass pImplied; research says dir/surge benefit from cleaner signal, so using pHat vs pImplied for “which side” is consistent—no change required if we keep `spot` for that comparison, or we could use pImplied; plan: keep `spot` for dir/surge side check to minimize change surface).

---

## 3. Implementation Checklist

- [x] Create `SapientStrategyV18.sol` from `SapientStrategyV14.sol`.
- [x] Add `SLOT_PREV_BID`, `SLOT_PREV_ASK`; keep other slot indices as in V14.
- [x] In `afterInitialize`: set `slots[SLOT_PREV_BID]` and `slots[SLOT_PREV_ASK]` to `BASE_LOW`.
- [x] In `afterSwap`: read `prevBid`/`prevAsk`; compute `feeUsed`, `gamma`, `pImplied`; use `pImplied` for `ret` and for pHat update when `ret <= adaptiveGate`; leave sigma/tox/vol logic as in V14 (ret already pImplied-based).
- [x] At end of `afterSwap`: write `slots[SLOT_PREV_BID] = bidFeeOut`, `slots[SLOT_PREV_ASK] = askFeeOut`.
- [x] Update contract title and `getName()` to “Sapient v18 - (V14 + pImplied only)”.
- [x] Build and run simulation (1000 sims): **Edge 380.13** (same as V14 — no gain); record edge vs V14 (380.13). Target: ≥ 382.

---

## 4. Success Criteria

- **Edge ≥ 382:** Keep V18 as new baseline for further levers (e.g. sigma×tox + cubic → V19).
- **Edge &lt; 382 but ≥ 380:** Keep as optional “cleaner signal” baseline; still proceed to V19/V20.
- **Edge &lt; 380:** Document result; consider reverting to V14 as baseline and trying next lever (e.g. sigma×tox + cubic) on V14.

---

## 5. References

- [2025-02-09-Sapient-other-levers-research.md](2025-02-09-Sapient-other-levers-research.md) — Section B (pImplied pseudocode), Step 7 (priority 1).
- [SapientStrategyV14.sol](../amm-challenge/contracts/src/SapientStrategyV14.sol) — base.
- [SapientStrategyV8.sol](../amm-challenge/contracts/src/SapientStrategyV8.sol) — reference for pImplied (V8 had it bundled with other levers).

---

## 6. Result & how to break the 380 plateau

**Sim result (1000 runs):** V18 edge = **380.13** (identical to V14). pImplied-only did not break the plateau.

**Next levers to try (one at a time, per research doc):**

| Priority | Lever | Slots | Base | Action |
|----------|--------|-------|------|--------|
| **1** | **Sigma×tox + cubic tox** | 0 | V14 (or V18) | V19: add `SIGMA_TOX_COEF * sigmaHat * toxEma` and `TOX_CUBIC_COEF * toxEma^3` to vulnerable-side tox. Tune small (e.g. 50e14, 15e14). |
| 2 | Trade-aligned boost | 0 | V14 / V18 | V20: if (isBuy && spot ≥ pHat) or (!isBuy && spot < pHat), add capped boost to that side. |
| 3 | First-in-step | 1 | V14 / V18 | V21: stepTradeCount; dual alpha (fast first trade, slow later); sigma only on first-in-step. |
| 4 | dirState alone | 1 | V14 / V18 | V22: flow-direction memory; protect side under pressure, attract other. |
| 5 | Stale + attract | 0 | V14 / V18 | V23: staleShift on vulnerable side, attractShift on other. |
| 6 | Two regimes | 0 | V14 / V18 | V24: if sigma & tox below threshold → flat low fee (calm); else full pipeline (stressed). |
| 7 | Conditional tail | 0 | V14 | V25: compress only when fee > 75 bps, then clamp 85. |

**Recommendation:** Implement **V19 (sigma×tox + cubic tox on V14)** next — no new slots, addresses “sharper fee when wrong and volatile,” and YQ/V8 use it. If V19 ≥ 382, keep; then stack trade-aligned boost (V20) or first-in-step (V21).
