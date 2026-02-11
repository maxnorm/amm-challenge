# YQ Fee Strategy — Explained for Newcomers

This guide explains the **YQ** AMM fee strategy in plain language. No prior AMM experience required.

---

## Part 1: Why Do We Need a Fee Strategy?

### What is an AMM?

An **Automated Market Maker (AMM)** is a pool that holds two assets (here: **X** and **Y**). Traders swap one for the other against the pool. The pool doesn’t see “buy orders” or “sell orders” from an order book — it just executes swaps at a price that depends on the current reserves (how much X and Y are in the pool).

- **Spot price** = reserveY / reserveX (how much Y per 1 X right now).
- After each trade, reserves change, so the price for the *next* trade changes too.

### Two kinds of traders

1. **Retail / noise traders**  
   They trade for their own reasons (need to convert X to Y, rebalance, etc.). They don’t necessarily know the “true” market price. We want to attract them with **reasonable fees** — they provide volume and fee income without trying to exploit us.

2. **Arbitrageurs**  
   They compare our pool’s price to the “fair” price (e.g. on other venues). When our price is wrong (e.g. we’re too cheap in Y), they buy Y from us until we’re back in line. That **corrects** our price but **costs** the pool value — we sold Y too cheap. We want to **charge more** when we’re likely to be arbed, so that we get paid for the risk.

### The goal of a fee strategy

- **When we’re safe** (price in line, balanced, calm): keep fees **lower** to attract retail and volume.
- **When we’re at risk** (price wrong, one-sided flow, volatile): set fees **higher** so we get paid for the risk and reduce how much arbitrageurs can take.

The catch: the AMM **does not see the “fair” price**. It only sees its own reserves and the trades that just happened. So we have to **infer** “are we safe or at risk?” from that limited information. YQ does exactly that.

---

## Part 2: The Big Picture of YQ

YQ keeps a small amount of **memory** (several numbers in “slots”) and updates it after every trade. Then it uses that memory to set **two** fees:

- **Bid fee** — charged when the AMM **buys X** (trader sells X to the pool).
- **Ask fee** — charged when the AMM **sells X** (trader buys X from the pool).

So we can charge **different** fees on each side. When we think the next exploiter will “sell X to us,” we raise the **bid** fee. When we think they’ll “buy X from us,” we raise the **ask** fee. That’s called **asymmetric fees**.

Important: the fee we **compute** in `afterSwap` is applied to the **next** trade, not the one we just saw. So we’re always one step ahead in our *thinking*, but the *current* trade already happened at the previous fee.

---

## Part 3: The Main Ideas (Step by Step)

### Idea 1 — “Fair price” without an oracle: **pHat**

We don’t have a feed for the true market price. So YQ maintains its own estimate, called **pHat** (pronounced “p-hat”), meaning “our best guess of fair price.”

How do we update it?

- After a trade we know: reserves (so **spot** = reserveY/reserveX) and which fee was used.
- From the math of the AMM, we can work backward: “given this spot and this fee, what price did the trader effectively get?” That gives **pImplied**.
- If pImplied is **close** to our current pHat, we blend it in a bit (we’re probably right). If pImplied is **very far** from pHat, we **don’t** update — we treat it as a noisy or toxic trade and don’t let it move our “fair price” guess. That’s the **adaptive gate**: only update when `|pImplied − pHat| / pHat` is below a threshold (based on recent volatility).

So: **pHat** = our internal “fair price”; we only trust small, consistent moves, not big jumps.

---

### Idea 2 — How wrong we are: **Toxicity (tox)**

**Toxicity** answers: “How far is our current pool price (spot) from our fair-price estimate (pHat)?”

- **tox** = |spot − pHat| / pHat (capped at 20% so one crazy trade doesn’t blow it up).
- We keep a smoothed version, **toxEma**, that reacts **quickly** to new trades (about 95% weight on the new value). So when we’re suddenly wrong, toxicity goes up fast.

High toxicity = we’re likely mispriced = the next trade might be an arb. So **fees go up a lot** when toxicity is high — and YQ uses not only a linear term but also **quadratic** and **cubic** terms in toxicity. That means when we’re *really* wrong, fees rise very sharply.

---

### Idea 3 — How jumpy the market is: **Volatility (sigmaHat)**

We also track how much the “implied price” has been moving:

- On the **first** trade in a new time step, we compute **ret** = |pImplied − pHat| / pHat (capped).
- **sigmaHat** is a smoothed average of that (like an EMA). So sigmaHat is high when we’ve been seeing big price moves recently.

High sigmaHat = volatile environment = more risk of big arbs. So the **base** part of the fee increases with sigmaHat. We also mix sigmaHat with toxicity (sigma × tox) so we charge even more when it’s both volatile *and* we’re wrong.

---

### Idea 4 — Who’s been hitting us: **Direction (dirState)**

**dirState** is a single number that means “recently, have we been buying more X or selling more X?”

- **Above WAD (1e18)** → more **buys of X** (traders sold X to us) → we’re accumulating X → “sell pressure” on X.
- **Below WAD** → more **sells of X** (traders bought X from us) → we’re losing X → “buy pressure” on X.

We update it only when the trade size is meaningful (above a small threshold). Each trade pushes dirState up (if they sold X to us) or down (if they bought X from us). Over time with no trades, dirState **decays** back toward neutral (WAD).

Why it matters: if we’ve been buying a lot of X lately, the next trader might be an arb selling us more X (we’re “rich in X” and cheap). So we want to **raise the bid fee** (fee when we buy X). That’s **directional asymmetry**: we charge more on the side that’s been getting hit.

---

### Idea 5 — How busy and how big: **Activity and size (actEma, sizeHat)**

- **actEma** = smoothed “how big are trades relative to reserves?” (trade ratio). High actEma = recently we’ve seen chunky trades → we might see more. Fee goes up with actEma.
- **sizeHat** = similar idea, slightly different smoothing. Combined with **lambdaHat** (trades per time step), we get **flowSize** = lambdaHat × sizeHat. High flowSize = “lots of flow, and it’s not tiny” → more fee.

So when the pool is **busy** and trades are **large**, we charge more, because that’s when we’re more exposed to both volume and possible arb.

---

### Idea 6 — Stale price: which side to protect?

We compare **spot** (current pool price) to **pHat** (our fair-price guess):

- **spot ≥ pHat** → we’re “rich in Y” (our pool price is high). The arb would *sell X* to us (we buy X) → we want to **raise the bid fee** and can **lower the ask fee** a bit to attract flow that buys X from us.
- **spot < pHat** → we’re “rich in X.” The arb would *buy X* from us → we **raise the ask fee** and can **lower the bid fee** a bit.

So we add a **stale-direction** term: extra fee on the “vulnerable” side and a small discount on the “helpful” side. That way we protect the side that’s likely to get arbed and stay attractive on the other side.

---

### Idea 7 — Trade-aligned toxicity boost

If the trade we *just* saw was “toxic” in our model (e.g. they bought when our spot was already above pHat), we add a small extra fee on that same side for the *next* trade. So we’re saying: “the last trade looked like an arb on this side; we’ll charge the next one on that side a bit more.”

---

### Idea 8 — Tail compression

We don’t want fees to explode to 10% on small moves. So above a small “knee” (e.g. 5 bps), we **compress** the fee:

- On the **protect** side: we multiply the part above the knee by 0.93 (slight dampening).
- On the **attract** side: we multiply by 0.955 (slightly less dampening so that side stays a bit cheaper).

Then we clamp the final fee to the allowed range (0 to 10%). So we get strong asymmetry without wild extremes.

---

## Part 4: How the Fee Is Built (Formula in Words)

1. **Base**  
   Start from 3 bps, then add:
   - a term proportional to **volatility** (sigmaHat),
   - a term proportional to **arrival rate** (lambdaHat),
   - a term proportional to **flow size** (lambdaHat × sizeHat).

2. **Toxicity**  
   Add linear + quadratic + cubic terms in **toxEma**, plus a **sigma × toxicity** term. So when we’re wrong (high tox) and/or volatile (high sigma), the fee goes up a lot.

3. **Activity**  
   Add a term in **actEma** (recent trade size relative to reserves).

4. **Directional skew**  
   From **dirState** we get **dirDev** (distance from neutral) and whether we’re in “sell pressure” or “buy pressure.” We add a skew that raises one side (bid or ask) and lowers the other. We also add **dirDev × toxicity** so the skew is stronger when we’re wrong.

5. **Stale-direction**  
   From **spot vs pHat** we add to the vulnerable side and subtract a bit from the other side (with a factor &gt; 1 on the discount so the attract side is clearly cheaper).

6. **Trade-aligned boost**  
   If the last trade was “toxic” in direction (e.g. buy when spot ≥ pHat), we add a small boost to the same side for the next trade.

7. **Tail compression and clamp**  
   Apply the knee + slope compression to each side, then clamp to [0, 10%].

Result: **bidFee** and **askFee** for the **next** trade.

---

## Part 5: What Happens Over Time (Decay)

When **time passes without a trade** (new “step”):

- **dirState** drifts back toward neutral (WAD).
- **actEma**, **sizeHat**, **toxEma** decay (we forget a bit).
- **lambdaHat** is updated from “how many trades last step / time elapsed” so we have an idea of “trades per step.”

So after a quiet period, our fees tend to come down — we assume things are calmer. The downside: the *first* trade after a long quiet period might be an arb, and they get that lower fee. That’s a known limitation of any strategy that only reacts after the fact.

---

## Part 6: Glossary

| Term        | Meaning |
|------------|---------|
| **AMM**    | Automated Market Maker — pool that quotes prices from reserves. |
| **Bid**    | When the AMM *buys* X (trader sells X to the pool). |
| **Ask**    | When the AMM *sells* X (trader buys X from the pool). |
| **Spot**   | reserveY / reserveX (current pool price). |
| **pHat**   | Strategy’s internal estimate of “fair” price. |
| **Toxicity** | How far spot is from pHat (we’re “wrong” by that much). |
| **sigmaHat** | Smoothed volatility (size of recent price moves). |
| **dirState** | Recent direction of flow (buy vs sell X); WAD = neutral. |
| **EMA**    | Exponential moving average — smooth average that reacts to new data. |
| **bps**    | Basis points; 1 bps = 0.01%. 30 bps = 0.30%. |

---

## Part 7: One-Sentence Summary

**YQ** keeps an internal “fair price” (pHat) and estimates how wrong the pool is (toxicity), how volatile things are (sigmaHat), which side is under pressure (dirState), and how busy and large trades are (actEma, sizeHat, lambdaHat); it then sets **asymmetric bid and ask fees** that are **higher when we’re wrong, volatile, or under one-sided flow**, and **lower on the side that helps rebalance us**, using tail compression so fees don’t go to extremes.

That’s the strategy in a form that a newcomer can use to start reading the code and tuning parameters.
