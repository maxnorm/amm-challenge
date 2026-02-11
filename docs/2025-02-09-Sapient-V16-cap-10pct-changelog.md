# Sapient V16 — Changelog (V14 with cap at 10%)

**Date:** 2025-02-09  
**Contract:** [amm-challenge/contracts/src/SapientStrategyV16.sol](../amm-challenge/contracts/src/SapientStrategyV16.sol)

V16 is V14 (low base + additive) with **MAX_FEE_CAP** raised to the protocol maximum: **10%** (`1e17` = WAD/10). The base contract allows fees up to `MAX_FEE = WAD/10`; we were previously self-capping at 75 bps (V14) or 85 bps (V15).

---

## Summary of changes

- **MAX_FEE_CAP:** `75e14` (75 bps) → **`1e17`** (10%).
- All other logic unchanged from V14.

---

## Note

With a 10% cap, the fee formula can output very high fees in stressed regimes (base + tox + asym + surge + size). The sim may then route most volume to the 30 bps normalizer, leaving us mainly toxic flow; past analysis (e.g. Sapient-v6-edge-wall-deep-review) suggested that removing the cap entirely hurt edge. If V16’s edge drops, try an intermediate cap (e.g. 100 bps = `100e14`, or 1% = `1e16`) in a follow-up variant.

---

## How to run

From `amm-challenge`:

```bash
amm-match run contracts/src/SapientStrategyV16.sol --simulations 1000
```

Compare edge to V14 (380.13).
