# Param tuning run log (from procedural plan)

**Baseline:** 524.63 (V34)  
**Parent:** V34 (until we adopt a winner)  
**Tuning versions:** V49, V50, … (one constant per version)

---

## Experiment 1 — TAIL_KNEE (Test A: 450 BPS)

- **Version:** V49  
- **File:** `amm-challenge/contracts/src/SapientStrategyV49.sol`  
- **Change:** TAIL_KNEE 500 → 450 BPS  

**Run (from repo root or amm-challenge):**
```bash
cd amm-challenge && amm-match run contracts/src/SapientStrategyV49.sol --simulations 1000
```

**Result:** _(paste Edge here after run)_

| Edge | vs 524.63 | Decision |
|------|-----------|----------|
| ? | ? | Improve → adopt V49 as parent, next = TOX_QUAD_COEF (V50). Regress → try Test B (TAIL_KNEE 550) as V50. Neutral → next constant (V50 = TOX_QUAD_COEF). |

---

## Next experiments (after we log V49)

- **2.** TOX_QUAD_COEF: 12285 BPS (Test A)  
- **3.** FLOW_SIZE_COEF: 5084 BPS  
- … (see master list in `2025-02-10-param-tuning-procedural-plan.md`)
