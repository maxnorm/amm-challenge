# Sapient V23 vs YQ — Structural Comparison

**Date:** 2025-02-10  
**Purpose:** Understand key structural concepts we are missing or getting wrong vs YQ (~520 edge). V23 (V21 + tail only) scores ~380; adding YQ-like features in V22 dropped us to 128. This doc compares **V23** (our current best) to **YQ** at the concept level.

**References:** [YQStrategy.sol](amm-challenge/contracts/src/refs/YQStrategy.sol), [SapientStrategyV23.sol](amm-challenge/contracts/src/SapientStrategyV23.sol).

---

## 1. Base fee formula

| Aspect | YQ | Sapient V23 |
|--------|-----|-------------|
| **Base level** | 3 bps (`BASE_FEE`) | 8 bps (`BASE_LOW`) |
| **Structure** | Additive: base + σ·coef + λ·coef + flowSize·coef | Additive: base + σ·coef + **imb**·coef + **vol**·coef + symTox |
| **Activity in base** | Yes: `LAMBDA_COEF·lambdaHat`, `FLOW_SIZE_COEF·(lambdaHat×sizeHat)` | **No** — no λ, no flowSize |
| **Tox in base** | Yes: tox + tox² + **actEma** + σ×tox + tox³ in *mid* fee | Yes: symTox (linear + quad + SYM_HIGH) in base |
| **Imbalance / vol** | No explicit imbalance or vol in base | Yes: `IMB_COEF`, `VOL_COEF`; floor and time-decay toward floor |
| **Mid fee** | fMid = fBase + tox terms + actEma + sigma×tox + tox³ | We fold tox into base and add **vulnerable-side** tox premium (linear+quad × ASYMM) |

**Structural difference:** YQ uses a **low base (3 bps)** and builds the fee from **activity (λ, flowSize) and a rich mid fee (tox, actEma, σ×tox, cubic)**. We use a **higher base (8 bps)** and build from **imbalance, volatility, and symmetric tox**, then add a **vulnerable-side** tox premium. We have **no activity/flow in the base** — that’s a clear structural gap.

---

## 2. Price signal (fair value and ret)

| Aspect | YQ | Sapient V23 |
|--------|-----|-------------|
| **Fair value** | pHat (EWMA) | pHat (EWMA) |
| **Input to ret / gate** | **pImplied** (fee-adjusted: γ = 1 − feeUsed, pImplied = spot·γ or spot/γ) | **Spot** — ret = \|spot − pHat\|/pHat |
| **pHat update** | Blended with **pImplied** when ret ≤ gate | Blended with **spot** when ret ≤ gate |
| **Sigma update** | Only on **first trade in step** (see below) | **Every trade** |

**Structural difference:** YQ bases ret and pHat on **pImplied** so one toxic trade doesn’t drag the fair price. We use **spot** everywhere, so a single large toxic trade can move pHat and sigma a lot and distort gate/dir/surge. **We are missing pImplied** in V23.

---

## 3. Step, first-in-step, and sigma

| Aspect | YQ | Sapient V23 |
|--------|-----|-------------|
| **Step** | timestamp advance: `isNewStep = (trade.timestamp > lastTs)` | Same (we have lastTs) but we don’t use it for decay or lambda |
| **First-in-step** | `firstInStep = (stepTradeCount == 0)` | **Not used** |
| **pHat alpha** | firstInStep → 0.26; else 0.05 (retail) | Single alpha 0.26 every trade |
| **Sigma update** | **Only when firstInStep** | Every trade |
| **Step trade count** | Incremented each trade; reset to 0 on new step; drives lambda | **We don’t have it** |

**Structural difference:** YQ treats the **first trade in a step** as the informative move and uses a **faster pHat** and **sigma update** only then; later trades in the same step use a **slower pHat** and **don’t** update sigma. We update sigma every trade and use one alpha. So we **don’t have first-in-step logic**; when we tried it in V21 it regressed in our sim — so either our implementation was off or step semantics in the harness differ from YQ’s.

---

## 4. Activity and flow (lambda, size, actEma)

| Aspect | YQ | Sapient V23 |
|--------|-----|-------------|
| **lambdaHat** | Trades-per-step estimate; on new step: lambdaInst = stepCount/elapsed, blend into lambdaHat; decay | **None** |
| **sizeHat** | Smoothed trade size (tradeRatio); blend when tradeRatio > threshold; decay on new step | **None** (we have a one-shot size bump on current trade only) |
| **actEma** | Activity EMA from tradeRatio; blend when tradeRatio > threshold; decay on new step | **None** |
| **In base/mid** | fBase += LAMBDA·lambdaHat + FLOW_SIZE·(lambda×size); fMid += ACT_COEF·actEma | **None** |
| **Time decay** | On new step: decay by `decay^elapsed` (capped), not per-trade | We have time-decay only for **base fee toward floor** (steps), not for tox/lambda/size |

**Structural difference:** YQ has **first-class activity state** (lambdaHat, sizeHat, actEma) with **step-based decay** and feeds them into the fee. We have **no** λ, sizeHat, or actEma; we only add a **one-off size bump** to the current trade. So we **miss the whole activity/flow layer** in V23.

---

## 5. Asymmetry: direction and protect/attract

| Aspect | YQ | Sapient V23 |
|--------|-----|-------------|
| **Flow-direction memory** | **dirState** (WAD = neutral); push on buy/sell by trade size; decay toward WAD on new step | **None** |
| **Skew from dirState** | skew = DIR_COEF·dirDev + DIR_TOX·dirDev·tox; protect side +skew, attract −skew | **None** |
| **Tail protect/attract** | **dirState** decides which side is protect (steeper slope) vs attract | **Reserve imbalance** (reserveY ≥ reserveX → bid protect) |
| **Ret-based “wrong side”** | No separate ret-based dir premium | **Yes**: when ret ≤ gate and ret ≥ 0.5%, add premium to wrong side (spot vs pHat) |
| **Surge on gate breach** | No explicit surge | **Yes**: when ret > gate, add 15–40 bps to trade side |

**Structural difference:** YQ’s **only** directional asymmetry is **dirState** (who’s been hitting us) + **stale/attract** (below). We have **no dirState**; we use **ret-based dir premium** (wrong side) and **surge** (trade side when ret > gate), and we use **reserve imbalance** for tail protect/attract. So we **substitute** ret + surge + imbalance for YQ’s dirState; the **information** is different (one-shot ret vs persistent flow memory).

---

## 6. Stale and attract

| Aspect | YQ | Sapient V23 |
|--------|-----|-------------|
| **Stale** | Add STALE_DIR_COEF·tox to the “vulnerable” side (spot ≥ pHat → bid; else ask) | **None** |
| **Attract** | Subtract staleShift × STALE_ATTRACT_FRAC from the **other** side (floor 0) | **None** |

**Structural difference:** YQ explicitly **widens the spread** on the side where price has moved (stale) and **discounts** the other side (attract). We don’t have this; we only have ret-based dir and surge. So we **miss stale/attract** in V23.

---

## 7. Tail compression

| Aspect | YQ | Sapient V23 |
|--------|-----|-------------|
| **Knee** | 5 bps | 5 bps |
| **Slopes** | 0.93 protect, 0.955 attract | Same |
| **Protect/attract by** | **dirState** (sellPressure → bid protect) | **Reserve imbalance** (reserveY ≥ reserveX → bid protect) |
| **After tail** | clamp to MAX_FEE (YQ doesn’t show a numeric cap in snippet; likely 10% or similar) | clamp to 75 bps |

**Structural difference:** Tail **shape** is the same; the **choice of which side is protect** is **dirState** in YQ vs **reserve imbalance** in us. So when we add dirState later, we could switch tail to use dirState for protect/attract to align with YQ.

---

## 8. Toxicity definition and blend

| Aspect | YQ | Sapient V23 |
|--------|-----|-------------|
| **Tox signal** | \|spot − pHat\|/pHat (capped); **spot vs pHat** | Same: ret from spot vs pHat, tox = capped ret |
| **Blend** | toxEma = TOX_BLEND_DECAY·toxEma + (1−TOX_BLEND_DECAY)·tox (fast blend ~0.05) | toxEma = (1−TOX_ALPHA)·toxEma + TOX_ALPHA·tox (0.1) |
| **Time decay** | On new step: toxEma = toxEma · TOX_DECAY^elapsed | **No** step-based decay of toxEma |
| **In fee** | tox + tox² + σ×tox + tox³ (symmetric mid); no separate “vulnerable” premium | Symmetric in base (symTox) + **vulnerable-side premium** (linear+quad × ASYMM) |

**Structural difference:** YQ uses **spot vs pHat** for tox (we do too in V23). YQ **decays toxEma by elapsed time** on new step; we don’t. YQ puts tox in a **symmetric mid fee** (with σ×tox and cubic); we put **symmetric tox in base** and add a **vulnerable-side** premium. So we have **extra asymmetry** (vulnerable tox) and **no time-decay of toxEma**.

---

## 9. Summary: what we have vs what we miss or do differently

| Concept | YQ | V23 | Verdict |
|---------|-----|-----|--------|
| **Base level** | 3 bps | 8 bps | We’re higher; YQ builds from lower base |
| **pImplied** | Yes (ret, pHat, gate) | **No** (spot only) | **We miss it** |
| **First-in-step** | Yes (pHat alpha, sigma only first) | No | **We miss it** (and it regressed when we tried) |
| **Activity in base** | λ, flowSize, actEma | **None** | **We miss it** |
| **Step-based decay** | dirState, actEma, sizeHat, toxEma, lambda | Only base fee floor decay | **We mostly miss it** |
| **dirState** | Yes (skew + tail protect/attract) | No (we use ret + surge + imbalance) | **We do something different** |
| **Stale/attract** | Yes | **No** | **We miss it** |
| **Sigma×tox, cubic tox** | Yes in mid fee | No (we have symTox + vulnerable premium) | **Different structure** |
| **Vulnerable-side tox** | No separate block | Yes (linear+quad × ASYMM) | **We have it; YQ doesn’t** |
| **Imbalance / vol in base** | No | Yes | **We have it; YQ doesn’t** |
| **Ret-based dir + surge** | No | Yes | **We have it; YQ doesn’t** |
| **Tail** | Yes (by dirState) | Yes (by imbalance) | Same shape; different protect/attract rule |
| **Trade-aligned boost** | Yes | Yes | Same idea |

---

## 10. What we might be getting wrong (when we add YQ-like features)

From the above, when we added “YQ-like” features in V22 and got 128, likely issues are **combination and ordering**, not necessarily a single wrong concept:

1. **Base still high + activity on top**  
   We kept 8 bps base and **added** λ and flowSize. YQ has **3 bps** base and then builds. So we may have **overcharged** (base 8 + flow + everything else) and driven away flow.

2. **pImplied + our sigma/tox**  
   We switched to pImplied for ret/pHat but kept **sigma every trade** and (in some versions) **tox from ret**. YQ uses pImplied for ret/pHat and **sigma only first-in-step** and **tox from spot vs pHat**. So our **mix** (pImplied + sigma every trade, or tox from pImplied-based ret) might be wrong for this harness.

3. **dirState + our ret/surge**  
   We added dirState **on top of** ret-based dir and surge. YQ has **only** dirState (no ret-based dir premium, no surge). So we may **double-count** direction (ret + dirState) and make spreads too wide.

4. **Stale/attract on top of vulnerable tox**  
   We added stale/attract while keeping a **vulnerable-side tox premium**. YQ has **no** separate vulnerable block — only symmetric tox + dirState skew + stale/attract. So we may have **too much** asymmetry (vulnerable tox + dirState + stale) and again overcharge.

5. **Tail by dirState vs by imbalance**  
   In V22 we used dirState for tail protect/attract. In V23 we use **imbalance** and get ~380. So **tail by dirState** might be the wrong choice in our sim, or it only works when the rest of the fee (base, activity, skews) is YQ-like.

6. **Regimes (calm/stress)**  
   YQ has **no** explicit calm/stress; it’s one pipeline. We added a calm branch with flat fee. If the harness has few true “calm” periods or our thresholds were off, we could have created **exploitable** or **misclassified** regimes.

**Bottom line:** Structurally we’re **missing**: pImplied, activity/flow in base (λ, flowSize, actEma), step-based decay, dirState (we substitute ret/surge), and stale/attract. We’re **different** in: higher base, imbalance/vol in base, vulnerable-side tox, ret-based dir and surge, and (when we added them) how we combined YQ-like pieces. To adopt YQ’s structure without regressing, we likely need to **align one piece at a time** (e.g. V23 + pImplied only; then + activity only; then + dirState with **removal** of ret-based dir and surge; etc.) and test after each step.
