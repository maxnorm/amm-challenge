# Detailed Procedural Plan: Diverse Parameter Tuning for Edge

**Purpose:** Run a structured, diverse set of single-constant experiments to improve edge from V34 baseline (524.63).  
**Rule:** One constant change per version. Copy from current best (V34 or later improved version).  
**Command:** From `amm-challenge/`: `amm-match run contracts/src/SapientStrategyVXX.sol --simulations 1000`

---

## 1. Conventions

| Term | Meaning |
|------|--------|
| **Baseline** | Best edge so far; start = 524.63 (V34). After any improvement, new baseline = that version’s edge. |
| **Parent** | Contract to copy for the next version (initially V34; after a win, the winning version). |
| **Improve** | Edge > baseline → adopt as new parent, document, continue. |
| **Regress** | Edge < baseline → discard version; try opposite direction for same constant or move to next constant. |
| **Neutral** | Edge = baseline → no adoption; move to next constant. |

**Version numbering:** Start at V42 and increment (V42, V43, …) so we don’t collide with existing V35–V41.

**WAD values:** Use 18 decimals. E.g. 0.93 → `930000000000000000`, +5% → multiply by 1.05 in WAD (e.g. `wmul(930000000000000000, 105e16)` = 9765e14 → `976500000000000000`).

---

## 2. Master Parameter List (Diverse Set)

Each row is one experiment (one version, one constant). Order alternates **groups** so we don’t over-explore one dimension.

| # | Group | Constant | Current value (V34) | Test A | Test B | Notes |
|---|-------|----------|---------------------|--------|--------|-------|
| 1 | Tail | TAIL_KNEE | 500 * BPS | 450 * BPS | 550 * BPS | Try Test A first; if regress, try Test B. |
| 2 | Toxicity | TOX_QUAD_COEF | 11700 * BPS | 12285 (≈+5%) | 11115 (≈−5%) | 11700 * 1.05, 11700 * 0.95. |
| 3 | Flow | FLOW_SIZE_COEF | 4842 * BPS | 5084 (≈+5%) | 4599 (≈−5%) | |
| 4 | Base/Vol | BASE_FEE | 3 * BPS | 4 * BPS | 2 * BPS | Additive. |
| 5 | Direction | DIR_COEF | 20 * BPS | 21 * BPS | 19 * BPS | Or 20*1.05 / 20*0.95. |
| 6 | Tail | TAIL_SLOPE_PROTECT | 0.93 (930…e17) | 0.9393 (+1%) | 0.9207 (−1%) | 93e16→939e15; 93e16→9207e14. |
| 7 | Toxicity | TOX_COEF | 250 * BPS | 262 (≈+5%) | 237 (≈−5%) | |
| 8 | Flow | LAMBDA_COEF | 12 * BPS | 12.6 (≈+5%) | 11.4 (≈−5%) | 12*1.05 ≈ 12.6, 12*0.95 ≈ 11.4. |
| 9 | Base/Vol | SIGMA_COEF | 0.20 (2e17) | 0.21 (2.1e17) | 0.19 (19e16) | WAD. |
| 10 | Direction | DIR_TOX_COEF | 100 * BPS | 105 * BPS | 95 * BPS | |
| 11 | Tail | TAIL_SLOPE_ATTRACT | 0.955 (955e15) | 0.9645 (+1%) | 0.9455 (−1%) | |
| 12 | Toxicity | TOX_CUBIC_COEF | 15000 * BPS | 15750 (≈+5%) | 14250 (≈−5%) | |
| 13 | Direction | STALE_DIR_COEF | 6850 * BPS | 7185 (≈+5%) | 6507 (≈−5%) | |
| 14 | Other | TRADE_TOX_BOOST | 2500 * BPS | 2625 (≈+5%) | 2375 (≈−5%) | |
| 15 | Flow | ACT_COEF | 91843 * BPS | 96435 (≈+5%) | 87249 (≈−5%) | |
| 16 | Toxicity | SIGMA_TOX_COEF | 500 * BPS | 525 * BPS | 475 * BPS | |
| 17 | Decay | PHAT_ALPHA | 0.26 (26e16) | 0.2678 (+3%) | 0.2522 (−3%) | 26e16 * 1.03, * 0.97. |
| 18 | Direction | STALE_ATTRACT_FRAC | 1.124 (1124e15) | 1.161 (+3%) | 1.087 (−3%) | |
| 19 | Other | GATE_SIGMA_MULT | 10 * WAD | 10.5 * WAD | 9.5 * WAD | |
| 20 | Decay | TOX_BLEND_DECAY | 0.051 (51e15) | 0.0525 (+3%) | 0.0495 (−3%) | |

---

## 3. Exact Values Reference (copy-paste)

Use these for consistency. BPS = 1e14, WAD = 1e18.

**Tail**
- TAIL_KNEE: 500 → **450** or **550** (BPS)
- TAIL_SLOPE_PROTECT: 930000000000000000 → **939000000000000000** (+1%) or **920700000000000000** (−1%)
- TAIL_SLOPE_ATTRACT: 955000000000000000 → **964550000000000000** (+1%) or **945450000000000000** (−1%)

**Toxicity (BPS-style; use integer BPS then * BPS)**
- TOX_QUAD_COEF: 11700 → **12285** or **11115**
- TOX_COEF: 250 → **262** or **237**
- TOX_CUBIC_COEF: 15000 → **15750** or **14250**
- SIGMA_TOX_COEF: 500 → **525** or **475**

**Flow (BPS)**
- FLOW_SIZE_COEF: 4842 → **5084** or **4599**
- LAMBDA_COEF: 12 → **13** or **11** (round 12.6/11.4)
- ACT_COEF: 91843 → **96435** or **87249**

**Base/Vol**
- BASE_FEE: 3 → **4** or **2** (BPS)
- SIGMA_COEF: 200000000000000000 → **210000000000000000** or **190000000000000000**

**Direction (BPS then * BPS)**
- DIR_COEF: 20 → **21** or **19**
- DIR_TOX_COEF: 100 → **105** or **95**
- STALE_DIR_COEF: 6850 → **7185** or **6507**
- STALE_ATTRACT_FRAC: 1124000000000000000 → **1157720000000000000** (+3%) or **1090280000000000000** (−3%)

**Other**
- TRADE_TOX_BOOST: 2500 → **2625** or **2375** (BPS)
- GATE_SIGMA_MULT: 10 * WAD → **10500000000000000000** (10.5) or **9500000000000000000** (9.5)

**Decay**
- PHAT_ALPHA: 260000000000000000 → **267800000000000000** (+3%) or **252200000000000000** (−3%)
- TOX_BLEND_DECAY: 51000000000000000 → **52530000000000000** (+3%) or **49470000000000000** (−3%)

---

## 4. Step-by-Step Procedure (Per Experiment)

### 4.1 Before You Start
- Set **parent** = V34 (file: `SapientStrategyV34.sol`).
- Set **baseline edge** = 524.63.
- Set **next version** = V42.

### 4.2 For Each Row in the Master List (in order 1 → 20)

1. **Copy parent**  
   - Copy `SapientStrategyV34.sol` (or current parent) to `SapientStrategyVXX.sol` (XX = next version).  
   - Update contract name/title and `getName()` to "Sapient vXX - …" and note the single constant you will change.

2. **Apply one change**  
   - Change only the constant for this row.  
   - Use **Test A** first (e.g. TAIL_KNEE 450, TOX_QUAD +5%, BASE_FEE 4, etc.).  
   - Leave all other constants identical to parent.

3. **Run**  
   ```bash
   cd amm-challenge && amm-match run contracts/src/SapientStrategyVXX.sol --simulations 1000
   ```  
   - Record the reported **Edge** in the results log (Section 5).

4. **Decide**  
   - **Edge > baseline** → **Improve.** Set parent = this VXX, baseline = this edge. Document in Section 5 and in a short changelog under `/docs`. Go to next row; use the **same** parent (the one you just adopted) for the next copy.  
   - **Edge < baseline** → **Regress.** Do not adopt. Option A: create VXX+1 from parent and apply **Test B** for the same constant; run and log. Option B: skip Test B and go to next row.  
   - **Edge = baseline** → **Neutral.** Do not adopt. Go to next row.

5. **Increment version**  
   - If you created a second test for the same constant (Test B), use VXX+1. Then next row uses VXX+2.  
   - Otherwise next row uses VXX+1.

6. **Repeat** from step 1 for the next row until you complete all 20 or decide to stop.

### 4.3 After a Full Pass (Optional)
- If baseline improved, do a **second pass** on the same list (or a shortened list of the most impactful groups) with the new parent, using smaller steps (e.g. ±3% where you used ±5%) on constants that improved.

---

## 5. Results Log Template

Fill this as you run. Parent = version used as source for this run.

| Version | Parent | Constant | Test (A/B) | New value | Edge | vs baseline | Adopt? |
|---------|--------|----------|------------|-----------|------|-------------|--------|
| V49 | V34 | TAIL_KNEE | A | 450 BPS | _run and fill_ | | |
| (next) | … | TOX_QUAD_COEF | A | 12285 BPS | | | |
| … | … | … | … | … | … | … | … |

**Current baseline:** 524.63 (V34) → update after any adoption.

**Note:** Tuning versions start at V49 to avoid overwriting existing V42–V48 (feature variants). Parent for all experiments is V34 until a run improves edge.

---

## 6. Quick Reference: Run Order and First Value to Try

| Order | Const | First value to try (Test A) |
|-------|--------|-----------------------------|
| 1 | TAIL_KNEE | 450 * BPS |
| 2 | TOX_QUAD_COEF | 12285 * BPS |
| 3 | FLOW_SIZE_COEF | 5084 * BPS |
| 4 | BASE_FEE | 4 * BPS |
| 5 | DIR_COEF | 21 * BPS |
| 6 | TAIL_SLOPE_PROTECT | 939000000000000000 |
| 7 | TOX_COEF | 262 * BPS |
| 8 | LAMBDA_COEF | 13 * BPS |
| 9 | SIGMA_COEF | 210000000000000000 |
| 10 | DIR_TOX_COEF | 105 * BPS |
| 11 | TAIL_SLOPE_ATTRACT | 964550000000000000 |
| 12 | TOX_CUBIC_COEF | 15750 * BPS |
| 13 | STALE_DIR_COEF | 7185 * BPS |
| 14 | TRADE_TOX_BOOST | 2625 * BPS |
| 15 | ACT_COEF | 96435 * BPS |
| 16 | SIGMA_TOX_COEF | 525 * BPS |
| 17 | PHAT_ALPHA | 267800000000000000 |
| 18 | STALE_ATTRACT_FRAC | 1157720000000000000 |
| 19 | GATE_SIGMA_MULT | 10500000000000000000 |
| 20 | TOX_BLEND_DECAY | 52530000000000000 |

---

## 7. Summary

- **Diversity:** 20 constants across 6 groups (Tail, Toxicity, Flow, Base/Vol, Direction, Decay, Other).  
- **Procedure:** Copy parent → change one constant (Test A) → run 1000 sims → log edge → adopt if improve, else try Test B or next constant.  
- **Documentation:** Keep results in Section 5; when you adopt a version, add a short changelog in `/docs` (e.g. `2025-02-10-Sapient-V42-tail-knee-changelog.md`) with constant, value, and edge.  
- **Baseline:** Start 524.63; update whenever a run beats the current baseline.

This gives you a repeatable, diverse param-tuning procedure based on the earlier findings.
