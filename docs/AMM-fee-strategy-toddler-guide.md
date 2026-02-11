# AMM Fee Strategy — Explained Like You're Five

A very simple guide to each idea you need to design an AMM fee strategy.  
**References** for learning more are at the end.

---

## 1. What is the pool?

Imagine a **big bowl** with two kinds of candy: red (X) and blue (Y).  
When someone trades, they put some of one color in and take some of the other out.  
The **price** is just: “how much blue do you get for one red?” It depends on how much red and blue are **in the bowl right now**.

- **Pool** = the bowl (the AMM).
- **Reserves** = how much X and Y are in the bowl.
- **Spot price** = “right now, how much Y for 1 X?” = reserves of Y ÷ reserves of X.

---

## 2. Why do we charge a fee?

The pool is like a **shop**. When people trade, we take a **tiny piece** of what they trade (the fee).  
That’s how the shop makes money.

- **Fee** = the small piece we keep (e.g. 0.30% = 30 “basis points” or bps).
- We can choose **different** fees for “someone sells us X” (bid) and “someone buys X from us” (ask). That’s **two fees**, not one.

---

## 3. Two kinds of people who trade

**Nice traders (retail):**  
They just want to swap candy for their own reasons. They don’t know if our price is a bit wrong. We like them. We want **lower fees** for them so they come to our shop.

**Tricky traders (arbitrageurs):**  
They look at other shops (other markets). When **our** price is wrong (e.g. we’re too cheap), they buy from us until we’re back in line. That **fixes** our price but **costs** our bowl value — we sold too cheap. We want to **charge more** when we think they’re about to do that.

So: **low fee when we’re safe, higher fee when we’re in danger.**

---

## 4. The big problem: we don’t see “the real price”

We only see **our bowl**: how much X and Y we have, and the trades that just happened.  
We don’t have a screen showing “the real world price.” So we have to **guess** from our own numbers:

- “Are we safe or in danger?”
- “Should we charge a little or a lot?”

**Fee strategy** = the set of rules we use to set our two fees (bid and ask) using only what we see (reserves, trades, time).

---

## 5. Fair price (pHat) — “Our best guess of the real price”

We can’t call someone to ask “what’s the real price?” So we keep a **guess** inside the strategy. Many strategies call it **pHat** (“p-hat”).

- We start from the price in our bowl (spot).
- When people trade, we **update** our guess a little: if the trade looks “normal,” we move our guess toward it; if it looks “weird” or too big, we don’t trust it and we don’t move much.
- So **pHat** = “our best guess of fair price” using only what happened in our pool.

**Toddler version:** “We don’t have a teacher to tell us the right answer. We write down our best guess and change it a tiny bit when we see new trades, but we don’t change it when someone does something crazy.”

---

## 6. Wrong price = toxicity

**Toxicity** = “how wrong is our bowl’s price compared to our guess?”

- If **spot** (price in the bowl) is **far** from **pHat** (our guess), we’re **wrong** — someone might arb us.
- We measure that as: **tox** = |spot − pHat| / pHat (how far, in relative terms).
- We often **smooth** it (toxEma) so one crazy trade doesn’t make the number jump too much.

**Toddler version:** “When the bowl says one price and our guess says another, we’re ‘wrong.’ The more wrong we are, the more we should charge, so the tricky people pay more.”

**References:**  
- [Toxic order flow (Meka)](https://meka.tech/writing/toxic-order-flow-5ab9af99-7b77-4efa-b360-31054046617e)  
- [Discrimination of toxic flow in Uniswap V3 (CrocSwap)](https://crocswap.medium.com/discrimination-of-toxic-flow-in-uniswap-v3-part-1-fb5b6e01398b)

---

## 7. Jumpy market = volatility (sigmaHat)

**Volatility** = “how much has our ‘fair price’ guess been moving lately?”

- When we see **big** moves in our guess (pHat), we call that **high volatility**.
- We keep a smoothed number, often **sigmaHat**: “on average, how big were recent moves?”
- When the world is **jumpy**, we’re more at risk, so we charge **more**.

**Toddler version:** “When the right answer keeps changing a lot, we’re nervous. So we ask for a bigger fee to be safe.”

---

## 8. Who’s been hitting us? Direction (dirState)

**Direction** = “lately, have people been **selling us X** or **buying X from us**?”

- We keep one number (e.g. **dirState**): above “neutral” = more sells of X to us; below = more buys of X from us.
- When **one side** has been hit a lot, we **raise the fee on that side** (protect) and can **lower it a bit on the other side** (attract good flow).

**Toddler version:** “If everyone’s been giving us red candy, we charge more when the next person gives us red, and a bit less when someone takes red. So we protect the side that’s been used a lot.”

---

## 9. How busy and how big? Activity (lambda, size, actEma)

**Activity** = “how many trades lately?” and “how big are they?”

- **Lambda** (λ) = “about how many trades per time step?” (busy = more risk).
- **Size** = “how big is each trade compared to the bowl?” (big trades = more impact).
- **actEma** = a smoothed “how big are trades?” (activity level).

When the pool is **busy** and trades are **big**, we charge **more**, because we’re more exposed.

**Toddler version:** “When lots of people trade and they trade big, we ask for a little more fee, because our bowl is changing a lot.”

---

## 10. Fee-adjusted price (pImplied)

When someone trades, they **already paid a fee**. So the price they *really* got is not exactly “spot” — it’s **adjusted** by that fee.

- **pImplied** = “what price did they really get after the fee?” (we can compute it from spot and the fee we charged).
- If we use **pImplied** (instead of spot) to update our fair-price guess (pHat), one **toxic** trade doesn’t drag our guess as much — we’re being smarter about what we trust.

**Toddler version:** “We look at what they actually paid, not just the sign on the bowl. So one sneaky trade doesn’t trick our guess.”

---

## 11. First trade in a step (first-in-step)

Time is in **steps** (e.g. each “moment” in the sim). In each step there can be **several trades**.

- **First trade in a step** = the first one in that moment. Many strategies treat it as **more informative** (maybe the one that moves price).
- **Later trades** in the same step = more “noise” or follow-up. So we might:
  - Update our fair price (pHat) **faster** on the first trade, **slower** on the rest.
  - Update **volatility (sigma)** only on the first trade.

**Toddler version:** “The first person in line gets us to change our guess more. The next people in the same line, we change our guess only a little.”

---

## 12. Stale price: which side to protect?

We compare **spot** (bowl price) to **pHat** (our guess):

- **spot ≥ pHat** → we’re “rich in Y” → the next arb would *sell X* to us → we **raise the bid fee** and can **lower the ask** a bit.
- **spot < pHat** → we’re “rich in X” → the next arb would *buy X* from us → we **raise the ask fee** and can **lower the bid** a bit.

So we **add fee** on the “vulnerable” side and **subtract a bit** on the other (attract). That’s **stale/attract**.

**Toddler version:** “If our bowl is too full of blue, we charge more when someone gives us red. If our bowl is too full of red, we charge more when someone takes red. And we make the other side a tiny bit cheaper so nice traders come.”

---

## 13. Tail compression (no huge fees)

We don’t want fees to go to 10% on small moves. So above a small “knee” (e.g. 5 bps):

- We **compress**: the part above the knee is multiplied by a number &lt; 1 (e.g. 0.93 or 0.955).
- We can use a **steeper** compression on the “protect” side and **softer** on the “attract” side.
- Then we **clamp** to the max allowed fee (e.g. 10%).

**Toddler version:** “We never let the fee get super huge. After a point we squeeze it so it doesn’t go crazy.”

---

## 14. Decay (forgetting over time)

When **time passes** and **no one trades**:

- We **forget** a little: our “who’s been hitting us” (dirState), activity (actEma, sizeHat), toxicity (toxEma) **decay** toward calm values.
- So after a quiet period, fees can **come down** — we assume things are calmer.

**Toddler version:** “If nobody trades for a while, we slowly forget that we were nervous. Our fees go down a bit until someone trades again.”

---

## 15. Loss-versus-rebalancing (LVR) — why fees matter

**LVR** = the **cost** to the pool because our price was wrong and smart traders (arbs) traded against us. It’s like “money that left the bowl” because we were mispriced.

- **Fees** create a “no-trade zone”: arbs only trade when the price move is **big enough** to cover the fee. So **higher fees** reduce how much they can take.
- But **too high** fees push away **nice** traders, so we get less fee income and more **toxic** flow on average.
- **Fee strategy design** = balance: high enough to cut LVR, low enough to keep volume and attract retail.

**Toddler version:** “Smart people take candy when our price is wrong. Fees are like a toll — they only cross if the move is big enough. We want the toll high enough so they don’t take too much, but not so high that our friends stop coming.”

**References:**  
- [Loss versus Rebalancing 101 (Medium)](https://medium.com/@titania-research/loss-versus-rebalancing-101-bc9651ec6e43)  
- [AMM and LVR (Jason Milí)](https://jasonmili.github.io/publication/2022-08-11-LVR)

---

## 16. One sentence per concept (cheat sheet)

| Concept        | In one sentence |
|----------------|------------------|
| **Pool / spot** | The bowl and its current price (Y per X). |
| **Fee**         | The small cut we keep; we can set bid and ask separately. |
| **Retail vs arb** | Nice traders we want (low fee); tricky traders we charge more. |
| **pHat**        | Our best guess of “real” price with no oracle. |
| **Toxicity**    | How wrong our bowl price is vs our guess; more wrong → charge more. |
| **Volatility (sigmaHat)** | How jumpy our guess has been; jumpy → charge more. |
| **Direction (dirState)** | Which side has been hit more; we protect that side. |
| **Activity**    | How busy and how big trades are; busy/big → charge more. |
| **pImplied**    | Price after fee; use it so one toxic trade doesn’t ruin our guess. |
| **First-in-step** | Treat first trade in a time step as more important; update pHat/sigma smarter. |
| **Stale/attract** | Add fee on vulnerable side, subtract a bit on the other. |
| **Tail compression** | Don’t let fee go crazy; compress above a knee, then clamp. |
| **Decay**        | When no one trades, forget a bit; fees drift down. |
| **LVR**          | Cost from being wrong and arbs trading against us; fees help reduce it. |

---

## Learn more (references)

- **AMM fees and adverse selection:**  
  [Fees in AMMs: A quantitative study (ADS)](https://ui.adsabs.harvard.edu/abs/2024arXiv240612417A/abstract)  
  [Dynamic fees (Uniswap v4)](https://docs.uniswap.org/contracts/v4/concepts/dynamic-fees) — when to charge more (volatility, volume, etc.).

- **Toxic flow and informed trading:**  
  [Toxic order flow (Meka)](https://meka.tech/writing/toxic-order-flow-5ab9af99-7b77-4efa-b360-31054046617e)  
  [Discrimination of toxic flow in Uniswap V3 (CrocSwap Part 1)](https://crocswap.medium.com/discrimination-of-toxic-flow-in-uniswap-v3-part-1-fb5b6e01398b)  
  [Part 2](https://crocswap.medium.com/discrimination-of-toxic-flow-in-uniswap-v3-part-2-21d84aaa33f5)  
  [Order flow toxicity on DEXes (ethresear.ch)](https://ethresear.ch/t/order-flow-toxicity-on-dexes/13177)

- **LVR and fee design:**  
  [Loss versus Rebalancing 101 (Titania Research)](https://medium.com/@titania-research/loss-versus-rebalancing-101-bc9651ec6e43)  
  [AMM and LVR (Jason Milí)](https://jasonmili.github.io/publication/2022-08-11-LVR)

- **In this repo:**  
  [YQ_STRATEGY_EXPLAINED.md](YQ_STRATEGY_EXPLAINED.md) — same ideas with a bit more detail.  
  [2025-02-10-from-scratch-reverse-engineer-and-design.md](2025-02-10-from-scratch-reverse-engineer-and-design.md) — how YQ and the leaderboard inform a from-scratch design.
