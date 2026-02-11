# Sapient V7 — Changelog (Approach A)

**Date:** 2025-02-09  
**Contract:** [amm-challenge/contracts/src/SapientStrategyV7.sol](../amm-challenge/contracts/src/SapientStrategyV7.sol)

Sapient V7 implements **Approach A** from the V7 structural brainstorm: minimal structural changes to break the ~374 edge wall, with no new storage slots.

---

## Summary of changes

1. **Dir only when ret ≤ gate** — Directionality is applied only when `ret <= adaptiveGate` and `ret >= DIR_RET_THRESHOLD`. When `ret > adaptiveGate`, we apply surge only (no dir). Dir and surge are mutually exclusive per trade so surge gets full headroom under the cap.

2. **Scaled surge** — Surge is no longer a fixed 25 bps. Formula: `surge = SURGE_BASE + SURGE_COEF * (ret - adaptiveGate)`, capped at `CAP_SURGE`. Larger breaches above the gate get a larger surge (15–40 bps).

3. **Stronger symmetric tox at high toxEma** — When `toxEma >= SYM_HIGH_THRESH` (1.5%), an extra symmetric term is added: `SYM_HIGH_COEF * (toxEma - SYM_HIGH_THRESH)`. This raises both sides more in high-tox regimes so the non-vulnerable side is not as cheap.

4. **Trade-size bump** — A fee bump is added to the side that was just hit (bid if buy, ask if sell), scaled by trade size. `tradeRatio = amountY / reserveY` (capped at 20%); `sizeBps = K_SIZE * tradeRatio` (capped at 20 bps). Uses `TradeInfo` only; no new state.

---

## New/updated constants

| Constant           | Value   | Description                                      |
|--------------------|---------|--------------------------------------------------|
| SURGE_BASE         | 15e14   | 15 bps minimum surge                             |
| SURGE_COEF         | 2e18    | 2 bps per 1% above gate (WAD)                    |
| CAP_SURGE          | 40e14   | 40 bps max surge                                 |
| SYM_HIGH_THRESH    | 15e15   | 1.5% toxEma threshold for extra sym term         |
| SYM_HIGH_COEF      | 25e14   | 25 bps per unit tox above threshold              |
| K_SIZE             | 50e14   | 50 bps per 100% trade ratio                      |
| CAP_SIZE_BPS       | 20e14   | 20 bps max size bump                             |
| TRADE_RATIO_CAP    | 20e16   | 20% cap on tradeRatio (WAD)                      |

Removed: fixed `SURGE_BPS` (replaced by scaled surge).

---

## References

- [2025-02-09-V7-structural-brainstorm.md](2025-02-09-V7-structural-brainstorm.md) — Approach A definition (lines 119–128).
- [Sapient-v6-edge-wall-deep-review.md](Sapient-v6-edge-wall-deep-review.md) — Diagnosis and formulas for dir/surge/sym-tox/size.

---

## Verification

- Build: `cd amm-challenge/contracts && forge build --skip test`. No `via_ir` required: stack depth is kept under the limit using internal helpers (`_computeRawFee`, `_applyDirSurgeAndSize`) and temporary slot storage (slots 10–15) for intermediate values.
- Run: `amm-match run contracts/src/SapientStrategyV7.sol --simulations 1000` (from `amm-challenge` with `amm-match` installed); compare edge to V6 (~374) and cap-hit rate.
