# Sapient V8 — Design Summary

**Date:** 2025-02-09  
**Goal:** Cross 400 edge from V7 (~380) by integrating concepts from our under-400 analysis and from YQ, without copying YQ’s implementation.

---

## Concepts used (and how they are integrated)

1. **Fee-adjusted price (pImplied)** — Use the fee that was just paid to infer an implied price so pHat and ret don’t overreact to one toxic trade. Slots 5–6 store previous bid/ask fee; we compute gamma = 1 − feeUsed and pImplied from spot; we use pImplied for ret, pHat update, and sigma. Spot is still used for volatility and for “vulnerable side” / dir logic.

2. **Sigma×tox and cubic tox** — When we’re both wrong and volatile, fee should rise more. We add SIGMA_TOX_COEF×sigmaHat×toxEma and TOX_CUBIC_COEF×toxEma³ to the vulnerable-side premium (same place as existing linear/quad tox).

3. **Trade-aligned toxicity boost** — If the current trade is toxic (buy when spot≥pHat or sell when spot<pHat), we add a size-scaled boost to the side just hit. No new state; uses current trade only.

4. **Stale + attract** — Add a tox-scaled term to the vulnerable side (by move direction) and subtract a fraction from the other side so we widen the spread and attract rebalancing flow. No new state.

5. **Cap raise** — 85 bps (from 75) so surge and size bump aren’t clipped as often on the worst flow.

6. **dirState (Phase 2)** — One slot (7), WAD-centered. Updated by trade direction and size (when trade ratio above threshold), decayed toward WAD by elapsed steps. We apply a skew from dirDev and dirDev×tox: protect the side under pressure, attract the other. Gives persistent “who’s been hitting us” memory.

7. **Time-consistent decay** — On a new step, we decay toxEma by TOX_DECAY^elapsed (and dirState by DIR_DECAY^elapsed) so that long idle periods reduce state more than a single step. Uses _powWad for exponentiation.

---

## Pipeline order (V8)

1. Read state (pHat, vol, timestamp, sigma, toxEma, dirState, prevBid, prevAsk).
2. If new step: decay dirState and toxEma by elapsed (time-consistent).
3. Compute spot, feeUsed, gamma, pImplied; ret from pImplied; update pHat (with pImplied when ret≤gate) and sigma.
4. Update volatility (from spot vs pHat) and toxEma (blend new tox with decayed toxEma).
5. Set temp slots (reserves, timestamp, isBuy, amountY).
6. Update dirState with current trade push (if tradeRatio > threshold).
7. Compute raw fee (base + sym-tox + floor + decay), baseFee, toxPremium (linear + quad + sigma×tox + cubic), then bid/ask with asym.
8. Apply dir/surge/size (_applyDirSurgeAndSize).
9. Apply trade-aligned boost and stale+attract (_applyTradeBoostAndStaleAttract).
10. Apply dirState skew (_applyDirStateSkew).
11. Write all state (including prev bid/ask and dirState); return clamped bid/ask.

---

## References

- [2025-02-09-Sapient-V8-changelog.md](2025-02-09-Sapient-V8-changelog.md) — Constants, slots, and verification.
- [2025-02-09-Sapient-V7-under-400-analysis.md](2025-02-09-Sapient-V7-under-400-analysis.md) — Why we were stuck under 400.
- [2025-02-09-YQ-extract-for-Sapient.md](2025-02-09-YQ-extract-for-Sapient.md) — YQ concepts we adapted.
