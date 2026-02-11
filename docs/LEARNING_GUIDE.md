# AMM Challenge: Learning Guide
## Visual + Intuitive + Math Formulas

---

## 🎯 Part 1: What is an AMM? (The Basics)

### The Constant Product Formula: `x × y = k`

**Visual Intuition:**
```
Imagine a pool with two tokens: X and Y
┌─────────────────────────┐
│   Pool                  │
│   X: 1000 tokens        │
│   Y: 1000 tokens        │
│                         │
│   Constant: k = 1,000,000│
└─────────────────────────┘
```

**The Rule:** When someone trades, the product `x × y` must stay constant (or increase slightly due to fees).

**Example Trade:**
- **Before:** X = 1000, Y = 1000, k = 1,000,000
- **Trader wants to buy X** (sell Y to the pool)
- **After:** X = 900, Y = 1111.11, k = 1,000,000

**Math Formula:**
```
If trader sells Δx tokens of X:
  New Y reserve = (k / (x - Δx)) - y
  Price paid = New Y reserve - Old Y reserve
```

**Key Insight:** The more X you buy, the more expensive each X becomes. This creates a **slippage curve**.

---

## 💰 Part 2: What is "Edge" and How Do We Score?

### Edge = Profit/Loss Compared to True Market Price

**Visual Example:**

```
True Market Price: 1 X = 1.05 Y

Trade 1: Retail trader buys 10 X
  - AMM price: 1 X = 1.02 Y (before trade)
  - Trader pays: 10.2 Y for 10 X
  - True value: 10 X = 10.5 Y
  - Edge = 10.5 - 10.2 = +0.3 Y ✅ (PROFIT!)

Trade 2: Arbitrageur sells 50 X
  - AMM price: 1 X = 1.08 Y (drifted from true price)
  - Arbitrageur gets: 54 Y for 50 X
  - True value: 50 X = 52.5 Y
  - Edge = 52.5 - 54 = -1.5 Y ❌ (LOSS!)
```

### Math Formula for Edge:

**For a trade where AMM sells X (trader buys X):**
```
Edge = amount_x × true_price - amount_y
```

**For a trade where AMM buys X (trader sells X):**
```
Edge = amount_y - amount_x × true_price
```

**Total Score:**
```
Total Edge = Σ (Edge from all trades)
```

**Goal:** Maximize Total Edge!

---

## 🎲 Part 3: The Market Simulation

### Two Types of Traders:

#### 1. **Retail Traders (Uninformed)**
- Arrive randomly via **Poisson process**
- Don't know the true price
- Trade for reasons unrelated to arbitrage
- **Generate positive edge** for the AMM ✅

#### 2. **Arbitrageurs (Informed)**
- Watch for price differences
- Trade when: `|AMM_price - true_price| > fee`
- Extract value from the AMM
- **Generate negative edge** ❌

### True Price Process: Geometric Brownian Motion (GBM)

**Formula:**
```
S(t+1) = S(t) × exp(-σ²/2 + σ × Z)
```

Where:
- `S(t)` = true price at time t
- `σ` = volatility (randomly sampled: 0.088% to 0.101% per step)
- `Z` = random number from standard normal distribution

**Visual:**
```
True Price Over Time:
    │
1.05│     ╱╲
    │    ╱  ╲    ╱╲
1.04│   ╱    ╲  ╱  ╲
    │  ╱      ╲╱    ╲
1.03│ ╱            ╲
    └─────────────────→ Time
```

**Key Insight:** The AMM price drifts away from true price over time. Arbitrageurs correct this, but only when the mispricing exceeds the fee.

---

## 🎯 Part 4: Why Dynamic Fees?

### The Problem with Static Fees:

**Scenario 1: Low Volatility (Calm Market)**
```
True price barely moves → AMM price stays close
→ Arbitrageurs rarely trade (misprice < fee)
→ Retail traders happy with low fees
→ ✅ Good: Low fees attract volume, minimal arbitrage
```

**Scenario 2: High Volatility (Chaotic Market)**
```
True price moves rapidly → AMM price drifts far
→ Arbitrageurs trade frequently (misprice > fee)
→ Large losses from arbitrage
→ ❌ Bad: Low fees don't protect against arbitrage
```

### Solution: Dynamic Fees

**High Volatility → Higher Fees:**
- Protects against arbitrage losses
- Creates larger "no-trade region"

**Low Volatility → Lower Fees:**
- Attracts retail volume
- Maximizes revenue from uninformed traders

### The No-Trade Region Concept:

**Visual:**
```
AMM Price: 1.05 Y per X
Fee: 0.3% (0.003)

No-Trade Region: [1.047, 1.053]
  │───────────────│
  │   No Arbitrage│
  │───────────────│
  
If true price is 1.046 → Arbitrageur trades (outside region)
If true price is 1.050 → No arbitrage (inside region)
```

**Math:**
```
No-Trade Region = [AMM_price × (1 - fee), AMM_price × (1 + fee)]
```

**Key Insight:** Larger fees = larger no-trade region = fewer arbitrage trades, but also less retail volume. Optimal fee balances these!

---

## 📊 Part 5: What Data Do We Have?

### TradeInfo Struct (What We See After Each Trade):

```solidity
struct TradeInfo {
    bool isBuy;          // true if AMM bought X (trader sold X)
    uint256 amountX;     // Amount of X traded
    uint256 amountY;     // Amount of Y traded
    uint256 timestamp;   // Simulation step number
    uint256 reserveX;    // Post-trade X reserves
    uint256 reserveY;    // Post-trade Y reserves
}
```

### What We Can Calculate:

**1. Current AMM Price:**
```
AMM_price = reserveY / reserveX
```

**2. Price Change:**
```
price_change = (current_price - previous_price) / previous_price
```

**3. Volatility (Realized):**
```
volatility = sqrt(Σ(price_change²) / window_size)
```

**4. Pool Imbalance:**
```
imbalance = |reserveX - reserveY| / (reserveX + reserveY)
```

**5. Trade Size:**
```
trade_size = amountX (or amountY)
```

---

## 🧠 Part 6: Strategy Design Principles

### Principle 1: Volatility-Based Fees

**Intuition:** When prices move fast, raise fees to protect against arbitrage.

**Formula:**
```
fee = base_fee × (1 + volatility_multiplier × realized_volatility)
```

**Example:**
```
base_fee = 30 bps (0.3%)
volatility_multiplier = 10
realized_volatility = 0.05% (0.0005)

fee = 0.003 × (1 + 10 × 0.0005) = 0.003 × 1.005 = 0.3015% ≈ 30.15 bps
```

### Principle 2: Inventory-Based Fees

**Intuition:** When pool is imbalanced, raise fees (similar to Curve Finance).

**Formula:**
```
imbalance = |reserveX - reserveY| / (reserveX + reserveY)
fee = base_fee × (1 + imbalance_multiplier × imbalance)
```

**Example:**
```
reserveX = 1200, reserveY = 800
imbalance = |1200 - 800| / (1200 + 800) = 400 / 2000 = 0.2 (20%)

fee = 0.003 × (1 + 2 × 0.2) = 0.003 × 1.4 = 0.42% = 42 bps
```

### Principle 3: Trade Size-Based Fees

**Intuition:** Large trades might be arbitrageurs, small trades are likely retail.

**Formula:**
```
normalized_size = trade_size / average_trade_size
fee = base_fee × (1 + size_multiplier × max(0, normalized_size - 1))
```

**Example:**
```
average_trade_size = 100 X
current_trade = 500 X
normalized_size = 500 / 100 = 5

fee = 0.003 × (1 + 0.1 × (5 - 1)) = 0.003 × 1.4 = 0.42% = 42 bps
```

### Principle 4: Time Decay

**Intuition:** After raising fees, gradually lower them back to base level.

**Formula:**
```
fee = base_fee + (current_fee - base_fee) × decay_factor^(time_since_adjustment)
```

**Example:**
```
base_fee = 30 bps
current_fee = 50 bps (raised due to volatility)
decay_factor = 0.95
time_since_adjustment = 3 steps

fee = 30 + (50 - 30) × 0.95³ = 30 + 20 × 0.857 = 30 + 17.14 = 47.14 bps
```

---

## 🎯 Part 7: Our First Strategy Design

### Strategy: "Volatility + Imbalance Adaptive Fees"

**Core Idea:**
1. Track realized volatility over recent trades
2. Track pool imbalance
3. Adjust fees based on both factors
4. Use time decay to return to base fee

### Formula:

```
base_fee = 30 bps (0.3%)

// Calculate volatility (EWMA)
volatility = α × |price_change| + (1 - α) × previous_volatility

// Calculate imbalance
imbalance = |reserveX - reserveY| / (reserveX + reserveY)

// Calculate fee multiplier
volatility_factor = 1 + volatility_multiplier × volatility
imbalance_factor = 1 + imbalance_multiplier × imbalance

// Combined fee
fee = base_fee × volatility_factor × imbalance_factor

// Apply time decay
fee = base_fee + (fee - base_fee) × decay_factor^(steps_since_last_trade)
```

### Parameters to Tune:

- `base_fee`: 30 bps (starting point)
- `volatility_multiplier`: 50-200 (how sensitive to volatility)
- `imbalance_multiplier`: 1-5 (how sensitive to imbalance)
- `decay_factor`: 0.95-0.99 (how fast fees decay)
- `α` (EWMA smoothing): 0.1-0.3 (how much weight on recent data)

### Storage Slots Usage:

```
slots[0] = last_price (WAD)
slots[1] = realized_volatility (WAD)
slots[2] = last_timestamp
slots[3] = last_fee (WAD)
```

---

## 🔧 Part 8: Implementation Checklist

### Step 1: Initialize State
- Store initial reserves
- Set initial price
- Set initial volatility estimate
- Return initial fees

### Step 2: After Each Trade
1. Calculate current AMM price from reserves
2. Calculate price change from last trade
3. Update volatility (EWMA)
4. Calculate imbalance
5. Compute new fee using formula
6. Apply time decay
7. Clamp fee to [0, MAX_FEE]
8. Store state in slots
9. Return (bidFee, askFee)

### Step 3: Gas Optimization
- Use efficient math (avoid expensive operations)
- Cache calculations
- Minimize storage reads/writes

---

## 📈 Part 9: Expected Behavior

### Scenario 1: Calm Market (Low Volatility)
```
Volatility: 0.05%
Imbalance: 5%
→ Fee: ~30-35 bps (close to base)
→ Attracts retail volume
→ Minimal arbitrage
→ ✅ Positive edge
```

### Scenario 2: Volatile Market
```
Volatility: 0.15%
Imbalance: 20%
→ Fee: ~50-70 bps (raised)
→ Protects against arbitrage
→ Still attracts some retail
→ ✅ Minimizes losses
```

### Scenario 3: Extreme Imbalance
```
Volatility: 0.08%
Imbalance: 40%
→ Fee: ~60-80 bps (raised)
→ Protects against large arbitrage
→ Gradually decays back
→ ✅ Adaptive protection
```

---

## 🎓 Key Takeaways

1. **AMM Price = reserveY / reserveX** (from constant product formula)
2. **Edge = profit/loss vs true price** (what we maximize)
3. **Dynamic fees protect against arbitrage** while attracting retail
4. **Volatility + Imbalance** are key signals for fee adjustment
5. **Time decay** prevents fees from staying too high
6. **Storage is limited** (32 slots) - be efficient!
7. **Gas is limited** (250k) - optimize calculations!

---

## 🚀 Next Steps

1. **Implement the strategy** in `AMMTemplate.sol`
2. **Test with simulator** and observe scores
3. **Tune parameters** based on results
4. **Iterate** and improve!

---

## 📚 Additional Resources

- See `RESEARCH_SUMMARY.md` for academic papers and advanced strategies
- Challenge website: https://www.ammchallenge.com/about
- Uniswap V2 docs: https://docs.uniswap.org/contracts/v2/overview
