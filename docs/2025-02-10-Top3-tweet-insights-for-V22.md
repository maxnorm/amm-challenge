# Top-3 Tweet Insights Applied to Sapient V22

**Source:** Java (@rishabhjava) — 3rd place AMM Challenge; "Three learnings" tweet.  
**Current state:** V22 (regime-first) Edge 128.27.  
**Goal:** Use these insights to tune and refine V22.

---

## 1. Directional fee asymmetry based on price deviation from fair value

**Tweet:** *"Directional fee asymmetry based on price deviation from fair value was the biggest unlock."*

**What we have in V22:**

- **Price deviation:** We use `ret = |pImplied - pHat| / pHat` (and gate/sigma from it). So "fair value" = pHat; deviation = ret.
- **Asymmetry tied to deviation:**
  - **Dir premium** (`_applyDirSurgeAndSize`): when `ret <= gate` and `ret >= 0.5%`, we add premium to the **wrong side** (spot ≥ pHat → ask; spot < pHat → bid). This is exactly directional asymmetry from price deviation.
  - **Surge:** when `ret > gate`, we add to the trade side (protection on large moves).
  - **Trade-aligned boost:** when the trade is "toxic" (buy when spot ≥ pHat, sell when spot < pHat), we add boost to that side.
- **dirState skew:** Asymmetry from **flow direction** (who’s been hitting us), not directly from current price deviation. So we have two kinds: (a) price-deviation-based (dir premium, surge, trade boost), (b) flow-based (dirState).

**Implication:** The tweet suggests (a) should be the main driver. Right now dir premium is capped at 30 bps and applied only when ret is in a band; dirState skew is 20 bps × dirDev + 10 bps × dirDev×tox. We may be underweighting **price-deviation-based** asymmetry relative to flow-based.

**Concrete tuning to try:**

- **Strengthen price-deviation asymmetry:** Increase `DIR_BPS_PER_UNIT_RET` (e.g. from ~25 bps per 10% ret toward 35–40) and/or `CAP_DIR_BPS` (e.g. 35–40 bps) so that "wrong side" fees respond more clearly to ret.
- **Optional:** Reduce `DIR_COEF` / `DIR_TOX_COEF` slightly so that flow-based skew doesn’t dominate; let ret-based dir premium and surge be the primary asymmetry. Or keep dirState but ensure the **order** of application is consistent (e.g. base → vulnerable tox → **dir premium from ret** → dirState → surge/size → trade boost → tail).

---

## 2. Stable and symmetric post-retail fees to minimize exploitation

**Tweet:** *"When the arb gets a low fee, they trade aggressively and extract disproportionately; optimal strategy is to keep post-retail fees as stable and symmetric as possible, minimize exploitable moments."*

**What we have:**

- **Calm regime:** We return flat `FEE_CALM` (12 bps) on both sides — **stable and symmetric**. No skew, no boost. This matches the tweet.
- **Risk:** If we **flip in and out** of calm (e.g. sigma/tox hovering around threshold), we create moments where one step we quote 12 bps symmetric and the next step we quote high asymmetric stress fees. Arbs can exploit the **transition** or the predictability of "low fee now, high fee next."

**Concrete tuning to try:**

- **Hysteresis for calm:** Enter calm only when sigma and tox have been "low enough" for more than one step, or use a **stricter** threshold for entering calm (e.g. sigma < 0.3%, tox < 0.3%) and a **looser** threshold for leaving (e.g. sigma > 0.6% or tox > 0.6%). That reduces flapping and keeps post-retail (calm) windows more stable.
- **Alternative:** Widen the calm band (e.g. `SIGMA_CALM_THRESH` and `TOX_CALM_THRESH` to 0.6–0.8%) so we stay in symmetric calm more often, and only switch to stress when there’s clear volatility/toxicity — again reducing exploitable transitions.

---

## 3. Trade-off between protection and retail volume

**Tweet:** *"We're optimizing a tradeoff; maximizing protection is not optimal as it loses retail."*

**What we have:**

- Regime-first V22 already aims for this: calm = flat low fee (retail), stress = trimmed pipeline (protection but not every lever).
- Edge 128 suggests we’re still on the wrong side of the trade-off: either **too much protection** (stress fees so high we get almost no flow, or only toxic flow) or **too little retail** (calm triggers too rarely so we’re almost always in stress).

**Concrete tuning to try:**

- **Lower stress fee level:** Reduce `MAX_FEE_CAP` from 85 bps to 75 bps so we don’t sit at the cap as often; or slightly reduce `BASE_LOW` / flow coefficients so that in stress we’re still protective but not maxed out. That can attract more flow (including some retail) in stress.
- **Spend more time in calm:** Loosen calm thresholds (e.g. `SIGMA_CALM_THRESH` and `TOX_CALM_THRESH` to 0.6% or 0.8%) so that we classify more periods as calm and quote 12 bps symmetric more often — explicitly favoring retail volume over maximum protection at the margin.
- **Soften stress skews:** Slightly reduce `DIR_COEF` / `DIR_TOX_COEF` or the vulnerable-side ASYMM so that stress fees are less extreme and we don’t "lose retail" as much when we’re in stress.

---

## Summary: what to try first

1. **Emphasize price-deviation asymmetry:** Bump `DIR_BPS_PER_UNIT_RET` and/or `CAP_DIR_BPS`; optionally reduce dirState coefficients so ret-based dir/surge/boost lead.
2. **Stabilize post-retail:** Add hysteresis (stricter enter-calm / looser exit-calm) or wider calm band so we don’t flip regimes every step.
3. **Favor retail a bit more:** Lower stress cap or base/flow; loosen calm thresholds so we’re in calm more often; or trim stress skew strength.

Re-run `amm-match run contracts/src/SapientStrategyV22.sol --simulations 1000` after each change and compare edge to 128.27 and to V21 (~380).
