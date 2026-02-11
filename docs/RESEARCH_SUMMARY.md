# Dynamic Fee Strategy Research Summary

## Overview
This document summarizes academic papers, protocol research, and implementation approaches for dynamic fee strategies in Automated Market Makers (AMMs).

---

## 1. Key Academic Papers

### 1.1 Optimal Dynamic Fees in Automated Market Makers (Baggiani et al., 2025)
**Paper**: [arXiv:2506.02869](https://arxiv.org/html/2506.02869v1)

**Key Findings**:
- **Two distinct fee regimes identified**:
  1. **High-fee regime**: AMM imposes higher fees to deter arbitrageurs
  2. **Low-fee regime**: Fees are lowered to increase volatility and attract noise traders
  
- **Optimal fee structure**: Dynamic fees that are:
  - **Linear in inventory** (reserve levels)
  - **Sensitive to external price changes**
  - Approximate optimal structure well

- **Control problem formulation**: Uses stochastic control theory (inspired by Avellaneda-Stoikov market making) to maximize total fees collected

- **Key insight**: Optimal fees balance two objectives:
  - Maximize per-trade revenue
  - Increase quadratic variation of marginal price to attract noise trading

**Relevance to Challenge**: 
- Directly addresses the problem we're solving
- Shows that optimal fees depend on inventory levels and external price movements
- Provides theoretical foundation for dynamic fee strategies

---

### 1.2 am-AMM: Auction-Managed Automated Market Maker (Adams et al., 2024)
**Paper**: [arXiv:2403.03367](https://moallemi.com/ciamac/papers/mm-amm-2024.pdf)

**Key Findings**:
- **Auction mechanism**: Uses onchain auction to determine pool manager who sets fees dynamically
- **Manager incentives**: Manager captures arbitrage profits (trades with zero fee) and sets fees to maximize revenue
- **Equilibrium result**: Under certain assumptions, am-AMM achieves higher liquidity than any fixed-fee AMM

**Fee Optimization Formula**:
```
f* ∈ argmax_{f∈[0,fmax]} fH₀(f, L) - AE₀(f)
```
Where:
- `H₀(f, L)` = noise trader volume per unit pool value
- `AE₀(f)` = arbitrageur excess (profit forgone by manager)

**Key Insight**: Optimal fee balances noise trader revenue against arbitrageur excess, typically higher than pure revenue-maximizing fee

**Relevance to Challenge**:
- Shows importance of distinguishing informed vs uninformed flow
- Demonstrates fee should be set to maximize: `fee_revenue - arbitrage_losses`
- Manager effectively trades with zero fee, capturing small arbitrages

---

### 1.3 Automated Market Making and Arbitrage Profits in the Presence of Fees (Milionis et al., 2023)
**Paper**: [LVR Fee Model](https://moallemi.com/ciamac/papers/lvr-fee-model-2023.pdf)

**Key Findings**:
- **LVR (Loss-Versus-Rebalancing)**: Quantifies adverse selection costs from arbitrageurs
- **Fee impact**: Fees create a "no-trade region" around the AMM price
- **Arbitrage profit formula** (fast block regime):
  ```
  ARB ≈ LVR × P_trade
  ```
  Where `P_trade = 1 / (1 + √(2λγ/σ))` is the probability of profitable arbitrage

- **Key parameters**:
  - `γ` = fee level
  - `σ` = volatility
  - `λ` = block arrival rate (or arbitrageur arrival rate)
  - `η = √(2λγ/σ)` = composite parameter

**Stationary Distribution of Mispricing**:
- Mispricing `z = log(P_market / P_amm)` follows a jump-diffusion process
- Outside no-trade region `[-γ, +γ]`: exponential tails
- Inside no-trade region: uniform distribution

**Relevance to Challenge**:
- Provides exact formulas for arbitrage profits given fees
- Shows how volatility and block time affect optimal fees
- Demonstrates that fees scale arbitrage profits by `P_trade` factor

---

## 2. Protocol Implementations

### 2.1 Uniswap V4 Dynamic Fees
**Documentation**: [Uniswap V4 Docs](https://docs.uniswap.org/contracts/v4/concepts/dynamic-fees)

**Features**:
- Dynamic fees managed through hooks
- Fees can adjust in real-time based on market conditions
- Can change per-swap basis
- Common implementations:
  - **Volatility-based**: Adjust fees based on asset volatility
  - **Volume-based**: Lower fees during high-volume periods
  - **Time-based**: Vary fees by time of day/week
  - **Market depth-based**: Adjust based on liquidity depth
  - **Oracle-based**: Use price oracles to determine fees

**Implementation Pattern**:
- Pool initialized with `LP_FEE = 0x800000` (dynamic fee flag)
- Hook implements `beforeSwap` to calculate fee
- Fee returned from hook determines swap fee

**Relevance**: Shows practical implementation patterns we can adapt

---

### 2.2 Curve Finance Dynamic Fees
**Research**: [Curve Tricrypto Dynamic Fee Research](https://gov.curve.fi/t/tricrypto-dynamic-fee-parameters-research-and-proposal/9588)

**Approach**:
- Dynamic fee structure: `mid_fee`, `out_fee`, `fee_gamma`
- Fees increase when pool is imbalanced (assets deviate from peg)
- Formula: Fee scales with deviation from balanced state

**Key Insight**: Higher fees when liquidity is imbalanced protect LPs and improve pool stability

**Results**:
- Tricrypto pools achieved 3-5% APY before admin fees
- Dynamic fees generated 10% more revenue than fixed fees (as of Feb 2024)
- Reduces sandwich attack profitability (though limited effect on frequency)

**Relevance**: Shows practical benefits of dynamic fees in production

---

## 3. Key Theoretical Insights

### 3.1 Fee-Volume Trade-off
**Core Problem**: Fees must be:
- **Low enough** to attract trading volume
- **High enough** to generate revenue and offset arbitrage losses

**Optimal Solution**: Dynamic fees that adjust to market conditions

**Research Finding**: Under normal conditions, optimal fees remain stable and competitive with CEX costs. During high volatility, fees should increase substantially to protect LPs.

---

### 3.2 Informed vs Uninformed Flow
**Two Types of Traders**:
1. **Noise/Uninformed Traders**: Generate fee income (positive edge)
2. **Arbitrageurs/Informed Traders**: Extract value (negative edge)

**Optimal Strategy**: 
- Maximize revenue from uninformed flow
- Minimize losses to informed flow
- This requires distinguishing between the two types

**Challenge**: Must infer trader type from observed trades (size, timing, price impact)

---

### 3.3 Volatility Estimation
**Key Insight**: Volatility directly affects:
- Rate at which AMM price drifts from market price
- Frequency of arbitrage opportunities exceeding fee threshold
- Optimal fee level

**From Challenge Specs**:
- Volatility σ ~ U[0.088%, 0.101%] per step
- Price follows GBM: `S(t+1) = S(t) · exp(-σ²/2 + σZ)`
- Must estimate volatility from observed trades

**Estimation Approaches**:
- Historical price variance
- Trade size patterns
- Time between trades
- Reserve movements

---

### 3.4 No-Trade Region Concept
**Key Concept**: With fee `f`, arbitrageurs only trade when mispricing exceeds `f`

**No-Trade Region**: `[-f, +f]` around current AMM price

**Implications**:
- Larger fees → larger no-trade region → fewer arbitrage trades
- But also → less retail volume
- Optimal fee balances these effects

**Probability of Trade**:
```
P_trade = 1 / (1 + √(2λf/σ))
```
Where:
- `λ` = arrival rate
- `f` = fee
- `σ` = volatility

---

## 4. Practical Strategies from Research

### 4.1 Volatility-Based Fees
**Approach**: Estimate volatility and adjust fees accordingly
- **High volatility** → Higher fees (protect against arbitrage)
- **Low volatility** → Lower fees (attract volume)

**Implementation**:
- Track price changes over time windows
- Calculate realized volatility
- Scale base fee by volatility factor

---

### 4.2 Inventory-Based Fees
**Approach**: Adjust fees based on reserve imbalances
- **Imbalanced reserves** → Higher fees (similar to Curve)
- **Balanced reserves** → Lower fees

**Rationale**: Imbalanced pools are more vulnerable to arbitrage

---

### 4.3 Trade Size-Based Fees
**Approach**: Differentiate between retail and arbitrage by trade size
- **Large trades** → Higher fees (likely arbitrage)
- **Small trades** → Lower fees (likely retail)

**Challenge**: Must distinguish size thresholds dynamically

---

### 4.4 Time-Decay Fees
**Approach**: Fees decay back to base level over time
- After large trade → Increase fee
- Over time → Decay back to base fee

**Rationale**: Large trades may indicate informed flow, but need to return to competitive levels

---

### 4.5 Adaptive Learning
**Approach**: Learn optimal fee from observed outcomes
- Track edge per trade
- Adjust fees based on whether edge was positive/negative
- Use exponential moving averages or similar

---

## 5. Mathematical Framework

### 5.1 Edge Calculation
From challenge specs:
```
Edge = Σ (amount_x × true_price - amount_y)   for sells (AMM sells X)
     + Σ (amount_y - amount_x × true_price)   for buys  (AMM buys X)
```

**Key Insight**: True price is what arbitrageurs trade to → can infer from trade patterns

---

### 5.2 Optimal Fee Formula (from am-AMM)
```
f* = argmax_{f} [f × H(f, L) - ARB_EXCESS(f, L)]
```

Where:
- `H(f, L)` = noise trader volume (decreasing in f)
- `ARB_EXCESS(f, L)` = arbitrage profits not captured (decreasing in f)

---

### 5.3 Arbitrage Profit Scaling (from LVR paper)
```
ARB ≈ LVR × P_trade
P_trade = 1 / (1 + √(2λf/σ))
```

**Implication**: Higher fees exponentially reduce arbitrage frequency

---

## 6. Implementation Considerations

### 6.1 Storage Constraints
- Only 32 slots (1KB) available
- Must track: volatility estimates, recent trades, fee history, etc.
- Need efficient data structures

### 6.2 Gas Constraints
- 250,000 gas limit per function call
- Complex calculations may be expensive
- Need efficient algorithms

### 6.3 No External Calls
- Cannot use oracles
- Must infer everything from trade data
- Must estimate volatility, true price, etc. from observations

---

## 7. Recommended Research Directions

### 7.1 Volatility Estimation
- **EWMA (Exponentially Weighted Moving Average)** of price changes
- **GARCH-like models** for volatility clustering
- **Trade-based volatility** from trade sizes and frequencies

### 7.2 True Price Inference
- **Arbitrage boundary**: When mispricing exceeds fee, arbitrageurs trade
- **Post-arbitrage price**: After arbitrage, price should be near true price
- **Track price movements** to infer true price

### 7.3 Adaptive Fee Algorithms
- **Multi-armed bandit**: Learn optimal fee through exploration/exploitation
- **Gradient descent**: Adjust fees based on edge gradient
- **Threshold-based**: Different fees for different market regimes

### 7.4 Trade Classification
- **Size-based**: Large trades → likely arbitrage
- **Timing-based**: Trades after price moves → likely arbitrage
- **Pattern-based**: Sequence of trades → classify flow type

---

## 8. Key Takeaways for Challenge

1. **Dynamic fees outperform static fees** - Research consistently shows this

2. **Volatility is crucial** - Optimal fees depend heavily on volatility

3. **Balance two objectives**:
   - Maximize revenue from retail (uninformed) flow
   - Minimize losses to arbitrage (informed) flow

4. **Fee should adapt to market conditions**:
   - High volatility → Higher fees
   - Large trades → Higher fees (temporarily)
   - Imbalanced reserves → Higher fees

5. **Learn from observed trades**:
   - Estimate volatility from price movements
   - Infer true price from arbitrage boundaries
   - Classify trades as retail vs arbitrage

6. **Simple approximations work**:
   - Linear-in-inventory fees approximate optimal well
   - Time-decay mechanisms are effective
   - Threshold-based strategies are practical

---

## 9. References

1. Baggiani, L., Herdegen, M., & Sánchez-Betancourt, L. (2025). Optimal Dynamic Fees in Automated Market Makers. arXiv:2506.02869

2. Adams, A., Moallemi, C. C., Reynolds, S., & Robinson, D. (2024). am-AMM: An Auction-Managed Automated Market Maker. arXiv:2403.03367

3. Milionis, J., Moallemi, C. C., & Roughgarden, T. (2023). Automated Market Making and Arbitrage Profits in the Presence of Fees.

4. Uniswap V4 Documentation: Dynamic Fees

5. Curve Finance: Tricrypto Dynamic Fee Research

6. Various other papers on LVR, volatility estimation, and AMM design

---

## Next Steps

1. **Implement volatility estimation** from trade data
2. **Design adaptive fee algorithm** based on research findings
3. **Test different strategies**:
   - Volatility-based
   - Inventory-based
   - Trade-size-based
   - Hybrid approaches
4. **Optimize for gas and storage** constraints
5. **Validate against challenge simulation** parameters
