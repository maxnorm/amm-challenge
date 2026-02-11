# Sapient V23 — V21 + tail compression only

**Date:** 2025-02-10  
**Purpose:** Isolate whether tail compression alone preserves edge. V22 (full upgrade) scores 128.27; V21 scores ~380. If V23 scores ~380, the regression is from other V22 additions (pImplied, flow, regimes, dirState). If V23 scores ~128, tail itself or its interaction with the harness is the cause.

**File:** [SapientStrategyV23.sol](../amm-challenge/contracts/src/SapientStrategyV23.sol)

## Change

- **Same as V21:** 8 bps base, spot-based ret/pHat, sigma every trade, vulnerable tox, dir/surge/size, trade-aligned boost, 75 bps cap.
- **Only addition:** Replace final hard cap with **tail compression**: knee 5 bps, slope 0.93 (protect) / 0.955 (attract), then clamp at 75 bps. Protect/attract side from reserve imbalance (reserveY >= reserveX → bid protect).

## How to run

```bash
cd amm-challenge
amm-match run contracts/src/SapientStrategyV23.sol --simulations 1000
```

Compare edge to V21 (~380) and V22 (128.27).
