# Sapient V22 — Full upgrade changelog

**Date:** 2025-02-10  
**Base:** V21 (V20 baseline: 8 bps additive base, trade-aligned toxicity boost)  
**Reference plan:** AMM Strategy Major Upgrade Plan — One Big V22 (in `.cursor/plans/` or attached)

---

## Summary

V22 is a single contract that bundles all report-recommended concepts to move edge from ~380 toward competition-ready (~520):

| Feature | Description |
|--------|-------------|
| **Tail compression** | Replace hard cap with knee (5 bps) + slope (0.93 protect / 0.955 attract), then clamp at 85 bps |
| **Two regimes** | Calm (sigma and tox below thresholds) → return flat FEE_CALM (12 bps) and still update state; stress → full pipeline |
| **Activity/flow in base** | lambdaHat (trades per step), sizeHat (smoothed trade size), stepTradeCount; add LAMBDA_COEF×lambdaHat + FLOW_SIZE_COEF×flowSize to base |
| **pImplied** | Prev bid/ask stored; fee-adjusted price used for ret and pHat update (no first-in-step) |
| **dirState + stale/attract** | Flow-direction memory (protect/attract skew); stale shift on vulnerable side, attract discount on other; tail slopes by dirState |

First-in-step is **not** included (regressed to 128 in this sim).

---

## Slot layout (V22)

| Slot | Content | Purpose |
|------|---------|---------|
| 0 | prevBidFee | pImplied (fee used for buy) |
| 1 | prevAskFee | pImplied (fee used for sell) |
| 2 | lastTimestamp | New-step detection, elapsed |
| 3 | dirState | Flow direction (WAD = neutral) |
| 4 | pHat | EWMA price (updated with pImplied) |
| 5 | volatility | Vol EMA |
| 6 | sigmaHat | Volatility for gate |
| 7 | toxEma | Toxicity EMA |
| 8 | lambdaHat | Trades-per-step estimate |
| 9 | sizeHat | Smoothed trade size vs reserves |
| 10 | stepTradeCount | Trades in current step (integer, cap 64) |
| 11–15 | temp: reserveX, reserveY, timestamp, isBuy, amountY | Scratch for trade and stack depth |
| 16–20 | temp: vol, ret, gate, spot, pImplied | Scratch for signals |

Base allows 32 slots; 11 persistent + 10 temp = 21 used.

---

## Constants (V22 add-ons)

- **Tail:** TAIL_KNEE = 5 bps, TAIL_SLOPE_PROTECT = 0.93, TAIL_SLOPE_ATTRACT = 0.955, MAX_FEE_CAP = 85 bps  
- **Regimes:** SIGMA_CALM_THRESH = 0.5%, TOX_CALM_THRESH = 0.5%, FEE_CALM = 12 bps  
- **Activity/flow:** ELAPSED_CAP = 8, LAMBDA_CAP = 5 WAD, LAMBDA_DECAY = 0.99, SIZE_DECAY = 0.70, SIZE_BLEND_DECAY = 0.818, LAMBDA_COEF = 8 bps, FLOW_SIZE_COEF = 20 bps, SIGNAL_THRESHOLD = 0.2%, STEP_COUNT_CAP = 64  
- **dirState:** DIR_DECAY = 0.80, DIR_IMPACT_MULT = 2, DIR_PUSH_CAP = 25%, DIR_COEF = 20 bps, DIR_TOX_COEF = 10 bps  
- **Stale/attract:** TOX_DECAY = 0.91, STALE_DIR_COEF = 50 bps, STALE_ATTRACT_FRAC = 1.124  

V21 constants for base, tox, dir, surge, size, and trade-aligned boost are unchanged.

---

## Implementation notes

- **Stack depth:** Resolved without changing Foundry config: trade written to temp slots at start of `afterSwap`; `_onNewStepDecay()` and `_onTradeUpdateSignals()` do state/signals; fee path reads from slots and uses helpers.  
- **Calm path:** When sigma and tox are below thresholds, state is still updated (pImplied, pHat, sigma, vol, tox, dirState, sizeHat, stepCount) and (FEE_CALM, FEE_CALM) is returned; timestamp is persisted.  
- **Contract name:** File is `SapientStrategyV22.sol`; contract name is `Strategy` for deployment compatibility with other versioned strategies.

---

## Changelog

- **2025-02-10:** V22 implemented: tail compression, two regimes, activity/flow in base, pImplied, dirState, stale/attract; stack-too-deep fixed via temp slots and split helpers (`_onNewStepDecay`, `_onTradeUpdateSignals`).
