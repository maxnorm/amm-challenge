# Sapient V34 — YQ baseline changelog

**Date:** 2025-02-10  
**Purpose:** From-scratch baseline: minimal YQ-aligned clone. Same formula and slot layout as [refs/YQStrategy.sol](../amm-challenge/contracts/src/refs/YQStrategy.sol); no structural changes.

**Design reference:** [2025-02-10-from-scratch-reverse-engineer-and-design.md](2025-02-10-from-scratch-reverse-engineer-and-design.md).

---

## What V34 is

- **Contract:** [SapientStrategyV34.sol](../amm-challenge/contracts/src/SapientStrategyV34.sol)
- **getName():**
  - `"Sapient v34 - YQ baseline"`
- **Logic:** Copy of YQ with only import-path and name adaptations (see plan). No change to constants, slot layout, or formula.

---

## Slot layout (same as YQ)

| Slot | Content        | Slot | Content        |
|------|----------------|-----|----------------|
| 0    | prev bid fee   | 6   | sigmaHat       |
| 1    | prev ask fee   | 7   | lambdaHat      |
| 2    | last timestamp | 8   | sizeHat        |
| 3    | dirState       | 9   | toxEma         |
| 4    | actEma         | 10  | stepTradeCount |
| 5    | pHat           | 11–31 | unused       |

---

## Formula summary (unchanged from YQ)

1. **Base:** 3 bps + SIGMA_COEF×sigmaHat + LAMBDA_COEF×lambdaHat + FLOW_SIZE_COEF×(lambdaHat×sizeHat)
2. **Mid:** fBase + tox (linear + quad) + ACT_COEF×actEma + SIGMA_TOX_COEF×sigmaHat×tox + TOX_CUBIC_COEF×tox³
3. **dirState skew:** protect side +skew, attract −skew; tail protect/attract by dirState
4. **Stale/attract:** by spot vs pHat
5. **Trade-aligned boost:** when current trade is toxic (buy when spot ≥ pHat or sell when spot < pHat)
6. **Tail:** knee 5 bps, slopes 0.93 (protect) / 0.955 (attract), then clamp to MAX_FEE
7. **Price/sigma:** pImplied for ret and pHat update; adaptive gate; first-in-step alpha and sigma update only on first-in-step
8. **Decay:** step-based (elapsed) for dirState, actEma, sizeHat, toxEma, lambda

---

## Validation (amm-match 1000 sims)

**Command (from `amm-challenge/` with venv activated):**

```bash
source .venv/bin/activate
amm-match run contracts/src/SapientStrategyV34.sol --simulations 1000
```

- **Build/run:** Strategy compiles, deploys, and runs; `getName()` returns `"Sapient v34 - YQ baseline"`.
- **Result:** **Edge: 524.63** (1000 sims, from `amm-challenge/` with venv).
- **Criterion:** Edge in same ballpark as YQ (~520) — achieved; V34 is the structural baseline for Phase 1 tuning and unique angles (see [2025-02-10-V34-explanation-and-unique-angles.md](2025-02-10-V34-explanation-and-unique-angles.md)).
