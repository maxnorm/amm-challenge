# Sapient V8 — Changelog

**Date:** 2025-02-09  
**Contract:** [amm-challenge/contracts/src/SapientStrategyV8.sol](../amm-challenge/contracts/src/SapientStrategyV8.sol)

Sapient V8 improves on V7 (edge ~380) using concepts from the under-400 analysis and from YQ: fee-adjusted price (pImplied), sigma×tox and cubic tox, trade-aligned boost, stale+attract spread, cap raise, and (Phase 2) dirState with time-consistent decay. Goal: cross 400 edge.

---

## Summary of changes

### Phase 1

1. **Cap raised to 85 bps** — `MAX_FEE_CAP = 85e14` (was 75 in V7) to reduce clipping on the vulnerable side.
2. **pImplied** — Store previous bid/ask fee in slots 5–6. Compute `gamma = 1 - feeUsed`, `pImplied = spot×γ` (buy) or `spot/γ` (sell). Use **pImplied** (not spot) when updating pHat and when computing ret for gate/dir/surge. Keeps one toxic trade from dragging pHat.
3. **Sigma×tox and cubic tox** — Add `SIGMA_TOX_COEF×sigmaHat×toxEma` and `TOX_CUBIC_COEF×toxEma³` to the vulnerable-side premium (with existing linear/quad).
4. **Trade-aligned toxicity boost** — If current trade is toxic (buy when spot≥pHat or sell when spot<pHat), add `TRADE_TOX_BOOST×tradeRatio` (capped) to the side just hit.
5. **Stale + attract** — Add `STALE_COEF×toxEma` to the vulnerable side (by move direction); subtract `ATTRACT_FRAC×staleShift` from the other side (floor 0) to widen spread and attract rebalancing.
6. **Initialization** — Set slots 5 and 6 to BASE_FEE so the first afterSwap has a valid feeUsed.

### Phase 2

7. **dirState (slot 7)** — WAD-centered flow-direction state. On new step: decay toward WAD by `_decayCentered(dirState, DIR_DECAY, elapsed)`. On trade: if `tradeRatio > SIGNAL_THRESHOLD`, push dirState by size (buy +push, sell −push); clamp in [0, 2×WAD]. Skew bid/ask from dirDev and dirDev×tox (protect side under pressure, attract other).
8. **Time-consistent tox decay** — On new step, decay toxEma by `toxEma × TOX_DECAY^elapsed` before blending in the new tox observation.
9. **Helpers** — `_powWad(factor, exp)`, `_decayCentered(centered, decay, elapsed)`, `_applyDirStateSkew(bidFee, askFee, dirState, toxEma)`.

---

## New/updated constants

| Constant           | Value    | Description |
|--------------------|----------|-------------|
| MAX_FEE_CAP        | 85e14    | 85 bps cap |
| SIGMA_TOX_COEF     | 50e14    | 50 bps per sigma×tox |
| TOX_CUBIC_COEF     | 15e14    | 15 bps per tox³ |
| TRADE_TOX_BOOST    | 25e14    | 25 bps per unit trade ratio |
| CAP_TRADE_BOOST    | 25e14    | 25 bps max trade boost |
| STALE_COEF         | 68e14    | 68 bps per unit toxEma |
| ATTRACT_FRAC       | 1124e15  | 1.124 WAD (fraction of stale to subtract from other side) |
| ELAPSED_CAP        | 8        | Max elapsed steps for decay |
| DIR_DECAY          | 80e16    | 0.80 dirState decay per elapsed step |
| TOX_DECAY          | 91e16    | 0.91 toxEma time decay |
| SIGNAL_THRESHOLD   | 2e15     | 0.2% trade ratio to push dirState |
| DIR_IMPACT_MULT    | 2e18     | Push = tradeRatio × mult (capped) |
| DIR_PUSH_CAP       | 25e16    | Max push 25% of WAD |
| DIR_COEF           | 20e14    | 20 bps per unit dirDev |
| DIR_TOX_COEF       | 10e14    | 10 bps per dirDev×toxEma |

---

## Slot usage

| Slot    | Content        |
|---------|----------------|
| 0       | pHat           |
| 1       | volatility     |
| 2       | timestamp      |
| 3       | sigmaHat       |
| 4       | toxEma         |
| 5       | prevBidFee     |
| 6       | prevAskFee     |
| 7       | dirState (WAD-centered) |
| 10–15   | temp (reserves, timestamp, isBuy, amountY, vol) |

---

## References

- [2025-02-09-Sapient-V7-under-400-analysis.md](2025-02-09-Sapient-V7-under-400-analysis.md) — Diagnosis and recommendation.
- [2025-02-09-YQ-extract-for-Sapient.md](2025-02-09-YQ-extract-for-Sapient.md) — Concepts adopted from YQ.
- [2025-02-09-Sapient-V8-design.md](2025-02-09-Sapient-V8-design.md) — Design summary.

---

## Verification

- Build (project may require `via_ir` if other strategies hit stack limit): from `amm-challenge/contracts`, `forge build --skip test`.
- Run: from `amm-challenge`, `amm-match run contracts/src/SapientStrategyV8.sol --simulations 1000`. Compare edge to V7 (~380) and target ≥400.
