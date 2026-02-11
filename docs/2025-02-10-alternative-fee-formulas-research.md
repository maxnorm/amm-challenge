# Alternative Fee Formulas — Research Summary

**Purpose:** Search for alternative AMM fee formulas in literature and practice that could inspire a **new formula** for our strategy (no oracle: only reserves, last trade, 11 slots).

**References:** Academic papers, Uniswap v4, HydraSwap, KyberSwap, CrocSwap, Avellaneda–Stoikov.

---

## 1. Academic: Optimal Dynamic Fees (Baggiani, Herdegen, Sánchez-Betancourt 2025)

**Source:** [Optimal Dynamic Fees in Automated Market Makers](https://arxiv.org/html/2506.02869v1) (arXiv:2506.02869).

**Findings:**
- **Two regimes:** (1) Higher fees to deter arbitrageurs; (2) Lower fees to attract noise traders and increase volatility.
- **Optimal structure:** Dynamic fees that are **linear in inventory** and **sensitive to external price changes** approximate the optimal fee well.
- Model: fee 𝔪(y), 𝔭(y) on a grid of inventory y; order flow has intensity depending on gap between AMM price and external price S_t.
- **Linear approximation** of the optimal policies performs nearly as well as the full optimal in their simulations.

**Adaptation to our setting (no oracle):**
- We have **no external price**; we use **pHat** as our “fair price” and **tox = |spot − pHat|/pHat** as “how wrong we are” (proxy for price gap).
- **Inventory:** We have reserves (spot ∝ reserveY/reserveX) and **dirState** (flow direction). So “linear in inventory” could mean:
  - **Bid/ask fee = base + coef × (some measure of imbalance)**.  
  (We tried imbalance in V35 and it hurt; a very small linear term or one that only *modulates* dirState might still be worth testing.)
- **Sensitive to “external price”:** We already are, via tox and sigma. The paper supports that **fee should respond to the gap between our price and “fair”** — we do that with tox and stale/attract. So our current design is aligned; the new idea is **explicit linear-in-inventory** (careful: V35 failed with a direct skew term).

**Formula idea (cautious):**  
Fee = base + f(σ, λ, tox, …) + **η × inventory_deviation** with η very small, or use inventory only to **damp** dirState when inventory and dirState disagree (see [2025-02-10-base-concept-improvements-and-edge-actions.md](2025-02-10-base-concept-improvements-and-edge-actions.md) §2.4).

---

## 2. HydraSwap: Volatility-Adjusted Fee (Variance / Velocity)

**Source:** [A window into AMM 2.0 — Introducing Volatility Adjusted Fee](https://medium.com/hydraswap/a-window-into-amm-2-0-introducing-volatility-adjusted-fee-af909b6c8ba5) (HydraSwap, 2022).

**Formula (concept):**
- **Volatility drag** (LP wealth decay) ∝ **variance** of price (σ² in their notation).
- **Total fee** earned ∝ **percentFee × volume**.
- They set:  
  **percentFee = (volatility drag over period) / (velocity)**  
  where **velocity = volume / TVL** (turnover).
- So: **fee ∝ variance / velocity**. High vol → higher fee; high velocity (lots of volume relative to TVL) → lower fee to stay competitive.
- Implementation: **EWMA variance** (hourly returns), min fee 5 bps, max 2%.

**Adaptation to our setting:**
- We have **sigma** (smoothed |ret|) — we can use σ or σ² as variance proxy.
- We have **lambdaHat × sizeHat** (flow size / activity) but **no TVL** in the strategy interface. We could:
  - Use **velocity proxy = lambdaHat × sizeHat** (activity level) and set  
    **fee_base_component = σ² / (1 + k × activity)**  
    so that when activity is high we reduce the vol-based part (lower effective fee), when activity is low we rely more on vol.
  - Or **inverse:** fee = base + σ² × g(activity) with g increasing in σ and decreasing in activity (calm + busy → moderate fee; calm + quiet → lower fee; stressed + busy → higher fee).

**Formula idea:**  
Introduce an explicit **velocity term**: e.g.  
**fBase = BASE_FEE + SIGMA_COEF×σ − VELOCITY_DISCOUNT×min(lambdaHat×sizeHat, cap)**  
so that high turnover reduces the fee (attract flow), consistent with “low fee to attract noise traders” from the academic paper. (V34 already has +FLOW_SIZE for flowSize; this would be the opposite sign on a similar quantity — **fee decreases** with activity in some regimes. Need to check if that’s already implicit in the sim.)

---

## 3. Uniswap v4–Style: Short vs Long Volatility + Sigmoid

**Source:** Uniswap v4 dynamic fee hooks; [e.g. best-fees-hook](https://github.com/berteotti/best-fees-hook), docs.

**Idea:**
- Compare **short-term volatility** (e.g. 24h) vs **long-term volatility** (e.g. 7d).
- **Sigmoid**: fee increases when short-term vol is **elevated** relative to baseline (regime change).
- Some implementations use **Chainlink volatility feeds** (oracle).

**Adaptation to our setting:**
- We have **sigma** (one EMA). We could add **sigma_slow** (slower EMA of |ret|) and define:
  - **vol_regime = sigma / sigma_slow** (or sigma_slow / sigma).
  - **Fee bump** when vol_regime > threshold (recent vol high vs baseline) — similar in spirit to V43 two-speed pHat but on **volatility** instead of price.
- No oracle needed: both sigma and sigma_slow from our own returns.

**Formula idea:**  
**fMid += REGIME_COEF × sigmoid(sigma / sigma_slow − 1)** when sigma > sigma_slow (or similar). One extra slot for sigma_slow. This is a **regime detector** based on vol, not price.

---

## 4. Avellaneda–Stoikov (Classic Market Making)

**Source:** Avellaneda & Stoikov (2008); [e.g. Hummingbot guide](https://medium.com/hummingbot/a-comprehensive-guide-to-avellaneda-stoikovs-market-making-strategy-102d64bf5df6).

**Formulas:**
- **Optimal spread:**  
  **spread = γ σ² (T−t) + (2/γ) ln(1 + γ/k)**  
  where γ = risk aversion, σ² = variance, k = order arrival intensity, T−t = time remaining.
- **Reservation price:**  
  **price = s − q γ σ² (T−t)**  
  (inventory q shifts the mid: more inventory → move mid to encourage offsetting flow).

**Interpretation:**
- Spread is **linear in σ²** and in **time** (T−t), plus a **log term in (1 + γ/k)** (order intensity).
- Mid is **linear in inventory** q.

**Adaptation to our setting:**
- **σ²:** we have sigma (we could use sigma² or keep linear in sigma for simplicity).
- **Time (T−t):** we don’t have a terminal time. We could use **elapsed** (time since last trade) as “uncertainty grows with silence” → spread widens with elapsed (similar to “silence risk” angle 2.4).
- **k (intensity):** we have **lambdaHat** (trades per step). So **ln(1 + γ/k)** could be approximated by a term in **1/(1 + lambdaHat)** or similar — when lambda is high, spread component decreases.
- **Inventory q:** we have **dirState** (and possibly reserves). Reservation price shift = we already do “protect/attract” via dirState; A–S says **linear** shift in mid by inventory, which we approximate with skew.

**Formula idea:**  
- **Spread (half-width) = A×σ² + B×elapsed + C/(1 + lambdaHat)** (or similar). Our current spread is implicit in bid/ask skew and tail; we could try making the **base spread** explicitly depend on **sigma²** and **elapsed** and **1/(1+λ)** to mirror A–S.
- **Reservation price:** we already skew by dirState; could try making the skew **linear in a reserve-imbalance measure** (again, small; V35 failed with a direct skew from imbalance).

---

## 5. KyberSwap Classic: Volume-Based Dynamic Fee

**Source:** [KyberSwap Classic — Dynamic Auto-Adjusting Fees](https://docs.kyberswap.com/reference/legacy/kyberswap-classic/concepts/dynamic-auto-adjusting-fees).

**Idea:**
- Fee = **base + z**, where **z** is a “variant factor” from **short-window vs long-window** volume (SMA or EMA).
- High recent volume vs long-term average → adjust fee (they use it to scale with volatility of volume).

**Adaptation to our setting:**
- We have **lambdaHat** (and flowSize). We could maintain **lambdaHat_fast** and **lambdaHat_slow** (two EMAs of trades-per-step). Then:
  - **z = f(lambdaHat_fast / lambdaHat_slow)** — e.g. when recent activity is high relative to baseline, add a small fee (busy regime); when low, subtract (quiet regime). Or the opposite, depending on whether we want to attract flow when quiet.
- Bounded fee range (they use 2–60 bps depending on pair).

**Formula idea:**  
**Activity regime:** **fMid += ACTIVITY_REGIME_COEF × (lambdaHat_fast / lambdaHat_slow − 1)** capped. One extra slot for lambdaHat_slow (or reuse something we already have). This is **activity-based regime** rather than vol-based.

---

## 6. CrocSwap: Toxic Flow Discrimination (Concept Only)

**Source:** [Discrimination of Toxic Flow in Uniswap V3 (Part 1)](https://crocswap.medium.com/discrimination-of-toxic-flow-in-uniswap-v3-part-1-fb5b6e01398b).

**Findings:**
- Toxic flow: large notional, repeated (same wallets). Non-toxic: fresh wallets, smaller size; for **fresh** wallets, even large size can be profitable (e.g. “retail whales”).
- **Price discrimination:** charge more to toxic, discount to non-toxic. Implementation would need wallet identity or proxies.

**Adaptation to our setting:**
- We **don’t have wallet identity**. We only have **trade size** and **step/trade count** (first-in-step vs not).
- We could proxy “fresh” by **first trade in step** (new step) and give a **slightly different** fee (e.g. small discount for first-in-step to attract; or small bump for “silence risk”). That’s already close to **silence risk (2.4)** and **first-in-step** logic in V34.
- **Size-based:** we have sizeHat; charging more when size is large is a form of “toxicity” proxy (CrocSwap found large size more often toxic). V34 already has FLOW_SIZE in the base; we could add a **size-dependent tox boost** (e.g. tox term × (1 + sizeHat factor)) — “when wrong and trade is large, charge more.” That’s a **formula variant**, not a new structural angle.

**Formula idea:**  
**Tox term = TOX_COEF×tox × (1 + SIZE_TOX_COEF×sizeHat)** so that toxicity is weighted up for large trades. (Mild; one constant.)

---

## 7. Summary: Candidate New Formulas We Can Implement (No Oracle)

| Idea | Source | What to add / change | Risk |
|------|--------|----------------------|------|
| **Velocity discount** | HydraSwap | fBase or fMid **minus** a term ∝ min(lambdaHat×sizeHat, cap) so fee decreases when turnover is high | Medium — might over-discount in busy regimes |
| **Vol regime (sigma vs sigma_slow)** | Uniswap v4 style | sigma_slow slot; fMid += coef × sigmoid(sigma/sigma_slow − 1) when sigma > sigma_slow | Low — one slot, one term |
| **Activity regime (lambda fast/slow)** | KyberSwap | lambdaHat_slow; fMid += coef × (lambdaHat_fast/lambdaHat_slow − 1) capped | Low — one slot or reuse |
| **A–S spread shape** | Avellaneda–Stoikov | Base spread ∝ σ² + elapsed + 1/(1+λ); explicit “spread” construction | Medium — bigger change to fee build-up |
| **Size-weighted tox** | CrocSwap | tox term × (1 + coef×sizeHat) | Low — one constant |
| **Linear in inventory (very small)** | Baggiani et al. | Small η × (reserve imbalance) or use imbalance to damp dirState | High — V35 failed; try only as damp |

---

## 8. Suggested order to try as “new formula” experiments

1. **Size-weighted toxicity** — Easiest: one constant, no new slots. tox × (1 + SIZE_TOX_COEF×sizeHat). **Implemented as V45:** see [2025-02-10-Sapient-V45-size-weighted-tox-changelog.md](2025-02-10-Sapient-V45-size-weighted-tox-changelog.md).
2. **Vol regime (sigma / sigma_slow)** — One new slot (sigma_slow), fee bump when sigma > sigma_slow. Aligns with “two regimes” from the academic paper and v4-style hooks.
3. **Velocity discount** — Subtract a small term ∝ activity from base or mid when activity is high (fee decreases with turnover). Test one version with a cap. **Implemented as V44:** see [2025-02-10-Sapient-V44-velocity-discount-changelog.md](2025-02-10-Sapient-V44-velocity-discount-changelog.md).
4. **Activity regime (lambda fast/slow)** — Similar to vol regime but on lambda; one slot for lambdaHat_slow.
5. **A–S-style spread** — Larger change: define half-spread = A×σ² + B×elapsed + C/(1+λ) and build bid/ask around it; compare to current tail/skew.

Each of 1–4 can be implemented as **one version** (e.g. V44, V45, …) and run against 524.63; document in `/docs` per workspace rules.

---

## 9. References (URLs)

- Baggiani, Herdegen, Sánchez-Betancourt (2025), *Optimal Dynamic Fees in Automated Market Makers*, https://arxiv.org/html/2506.02869v1  
- HydraSwap, *Introducing Volatility Adjusted Fee*, https://medium.com/hydraswap/a-window-into-amm-2-0-introducing-volatility-adjusted-fee-af909b6c8ba5  
- KyberSwap Classic, *Dynamic Auto-Adjusting Fees*, https://docs.kyberswap.com/reference/legacy/kyberswap-classic/concepts/dynamic-auto-adjusting-fees  
- CrocSwap, *Discrimination of Toxic Flow in Uniswap V3: Part 1*, https://crocswap.medium.com/discrimination-of-toxic-flow-in-uniswap-v3-part-1-fb5b6e01398b  
- Uniswap v4, *Dynamic Fees*, https://docs.uniswap.org/contracts/v4/concepts/dynamic-fees  
- Avellaneda–Stoikov (2008); Hummingbot, *A comprehensive guide to Avellaneda & Stoikov*, https://medium.com/hummingbot/a-comprehensive-guide-to-avellaneda-stoikovs-market-making-strategy-102d64bf5df6  
