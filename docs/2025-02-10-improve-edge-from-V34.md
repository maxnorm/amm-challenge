# How to Improve Edge from V34 (524.63)

**Context:** SapientStrategyV34 (YQ baseline) scores **Edge: 524.63** in 1000 sims. Leaderboard top ~526. This doc summarizes what’s been tried and what to do next.

---

## What we know

| Version | Change | Edge | Note |
|--------|--------|------|------|
| **V34** | YQ baseline | **524.63** | Current best; structural baseline |
| V35 | Imbalance skew (inventory term) | ↓ | Hurt; reverted (see V35 changelog) |
| V36 | Calm vs stressed (1% σ, 2% tox) | 524.56 | Slight regression |
| V37 | Calm vs stressed looser (2%, 5%) | 524.42 | Worse |
| V38 | Calm vs stressed tighter (0.5%, 1%) | 523.98 | Worst of calm variants |
| V39 | Tox-dependent dirState decay (angle 2.6) | 524.63 | Neutral — same as V34 |
| V40 | Silence risk (angle 2.4) | 524.63 | Neutral — same as V34 |
| V41 | Gate by size (angle 2.3) | 524.08 | Slight regression |
| V42 | Toxic flow run (angle 2.5) | 507.46 | Clear regression |
| V43 | Two-speed pHat (angle 2.7) | 524.63 | Neutral — same as V34 |
| V44 | Velocity discount (HydraSwap-style) | _see changelog_ | — |
| V45 | Size-weighted tox (CrocSwap-style) | 524.63 | Neutral — same as V34 |
| V46 | Bandit over 4 fee multipliers (P1) | 516.69 | Regression |
| V47 | Momentum asymmetric fee (P2) | 524.09 | Slight regression |
| V48 | Dual sigma + dual lambda (P3) | 524.40 | Slight regression |

**Takeaway:** No variant beats V34. V43 (two-speed pHat) ties V34. **V34 remains baseline**. Next: try **size-dependent attract (2.8)** or **constant tuning**.

---

## Recommended next steps (in order)

### 1. Low-risk: constant tuning (no new logic)

- **Detailed procedural plan:** [2025-02-10-param-tuning-procedural-plan.md](2025-02-10-param-tuning-procedural-plan.md) — 20 constants in a fixed order, one change per version (V42+), with exact values and results log.
- Tweak **one** of: BASE_FEE, SIGMA_COEF, LAMBDA_COEF, FLOW_SIZE_COEF, TOX/QUAD/CUBIC coefs, TAIL_KNEE, TAIL_SLOPE_*, decay constants.
- Change in small steps (e.g. ±5–10% of one coef), run `amm-match run contracts/src/SapientStrategyVXX.sol --simulations 1000`, compare to 524.63.
- If edge improves, keep and iterate; if it drops, revert and try another constant.

### 2. ~~Run V38~~ Done: V38 = 523.98

- Calm/stressed experiment complete. V34 (524.63) > V36 (524.56) > V37 (524.42) > V38 (523.98). **V34 stays baseline.**

### 3. One structural experiment (one angle per version)

From [2025-02-10-V34-explanation-and-unique-angles.md](2025-02-10-V34-explanation-and-unique-angles.md):

| Angle | Version | Edge | Note |
|-------|---------|------|------|
| **Tox-dependent decay** | V39 | 524.63 (tie) | [V39 changelog](2025-02-10-Sapient-V39-tox-dependent-decay-changelog.md) |
| **Silence risk** | V40 | 524.63 (tie) | [V40 changelog](2025-02-10-Sapient-V40-silence-risk-changelog.md) |
| **Gate by size** | V41 | 524.08 (regression) | [V41 changelog](2025-02-10-Sapient-V41-gate-by-size-changelog.md) |
| **Toxic flow run** | V42 | 507.46 (regression) | [V42 changelog](2025-02-10-Sapient-V42-toxic-flow-run-changelog.md) |
| **Two-speed pHat** | V43 | 524.63 (tie) | [V43 changelog](2025-02-10-Sapient-V43-two-speed-phat-changelog.md) |

**Not yet tried:**

| Angle | Doc section | Idea | Risk |
|-------|-------------|------|------|
| ~~Silence risk~~ | 2.4 | _(V40)_ | — |
| ~~Gate/alpha by size~~ | 2.3 | _(V41)_ | — |
| ~~Toxic flow run~~ | 2.5 | _(V42)_ | — |
| ~~Two-speed pHat~~ | 2.7 | _(V43)_ | — |
| **Size-dependent attract** | 2.8 | Attract discount increases with sizeHat (compete for large rebalancing flow) | Gaming if based on current trade only |

**Suggested first experiments:** **2.4 (silence)** or **2.6 (tox-dependent decay)** — no new slots for 2.6 (reuse dirState decay), minimal state for 2.4 (elapsed already available at step boundary).

### 4. If one experiment wins

- Keep the winning change as new baseline (e.g. V39), then try **one more** angle (e.g. V40). Document each in a short changelog under `/docs` and record edge.

### 5. If nothing beats V34

- Consider: (a) more aggressive constant tuning, (b) inspecting how the sim computes edge and which scenario types drive the gap to 526, (c) checking whether the harness favors a different fee distribution (e.g. avg fee, cap-hit rate).

---

## Quick reference

- **Baseline:** V34 = 524.63. Always compare new versions to this.
- **Command:** `amm-match run contracts/src/SapientStrategyVXX.sol --simulations 1000`
- **Rule:** One structural change per version; revert if edge drops; document in `/docs`.
