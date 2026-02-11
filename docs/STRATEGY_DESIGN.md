# Strategy Design: Volatility + Imbalance Adaptive Fees

## 🎯 Strategy Overview

**Name:** "Volatility + Imbalance Adaptive Fees" (VIAF)

**Core Concept:**
- Adjust fees dynamically based on **realized volatility** and **pool imbalance**
- Use **exponential decay** to return fees toward base level over time
- Protect against arbitrage during volatile/imbalanced periods
- Attract retail volume during calm periods

---

## 📐 Mathematical Framework

### 1. AMM Price Calculation

```
AMM_price = reserveY / reserveX
```

**In Solidity (WAD precision):**
```solidity
uint256 ammPrice = wdiv(trade.reserveY, trade.reserveX);
```

### 2. Price Change (Log Return)

```
price_change = ln(current_price / previous_price)
```

**Approximation (for small changes):**
```
price_change ≈ (current_price - previous_price) / previous_price
```

**In Solidity:**
```solidity
uint256 priceChange = wdiv(
    absDiff(ammPrice, lastPrice),
    lastPrice
);
```

### 3. Volatility Estimation (EWMA)

**Exponentially Weighted Moving Average:**

```
volatility_t = α × |price_change_t| + (1 - α) × volatility_{t-1}
```

Where:
- `α` = smoothing factor (0.1 to 0.3, typically 0.2)
- `volatility_t` = current volatility estimate
- `volatility_{t-1}` = previous volatility estimate

**In Solidity:**
```solidity
// α = 0.2 means 20% weight on new data, 80% on old
uint256 alpha = 2e17; // 0.2 in WAD
uint256 newVolatility = wmul(alpha, priceChange) + 
                        wmul(WAD - alpha, oldVolatility);
```

### 4. Pool Imbalance

```
imbalance = |reserveX - reserveY| / (reserveX + reserveY)
```

**Range:** [0, 1]
- `0` = perfectly balanced (reserveX = reserveY)
- `1` = completely imbalanced (one reserve is 0)

**In Solidity:**
```solidity
uint256 totalReserves = trade.reserveX + trade.reserveY;
uint256 imbalance = wdiv(
    absDiff(trade.reserveX, trade.reserveY),
    totalReserves
);
```

### 5. Fee Calculation

**Base Formula:**
```
fee = base_fee × volatility_factor × imbalance_factor
```

**Where:**
```
volatility_factor = 1 + volatility_multiplier × volatility
imbalance_factor = 1 + imbalance_multiplier × imbalance
```

**In Solidity:**
```solidity
uint256 volatilityFactor = WAD + wmul(volatilityMultiplier, volatility);
uint256 imbalanceFactor = WAD + wmul(imbalanceMultiplier, imbalance);
uint256 fee = wmul(baseFee, wmul(volatilityFactor, imbalanceFactor));
```

### 6. Time Decay

**Exponential Decay:**
```
fee_t = base_fee + (fee_{t-1} - base_fee) × decay_factor^Δt
```

Where:
- `Δt` = steps since last trade
- `decay_factor` = 0.95 to 0.99 (typically 0.98)

**In Solidity:**
```solidity
uint256 stepsSinceLastTrade = trade.timestamp - lastTimestamp;
uint256 decayFactor = 98e16; // 0.98 in WAD

// Approximate: decay_factor^steps ≈ 1 - steps × (1 - decay_factor)
// For small steps, use linear approximation
uint256 decayAmount = wmul(
    stepsSinceLastTrade,
    WAD - decayFactor
);
uint256 decayedFee = lastFee - wmul(decayAmount, lastFee - baseFee);
```

---

## 🗄️ Storage Layout

**Slot Usage:**
```
slots[0] = lastPrice (WAD) - AMM price after last trade
slots[1] = realizedVolatility (WAD) - Current volatility estimate
slots[2] = lastTimestamp - Timestamp of last trade
slots[3] = lastFee (WAD) - Fee from last trade (for decay calculation)
```

**Constants (hardcoded):**
```solidity
uint256 constant BASE_FEE = 30e14; // 30 bps = 0.3%
uint256 constant VOLATILITY_MULTIPLIER = 100e18; // 100x sensitivity
uint256 constant IMBALANCE_MULTIPLIER = 2e18; // 2x sensitivity
uint256 constant ALPHA = 2e17; // 0.2 EWMA smoothing
uint256 constant DECAY_FACTOR = 98e16; // 0.98 per step
```

---

## 🔄 Algorithm Flow

### Initialization (`afterInitialize`)

```
1. Calculate initial AMM price: price = initialY / initialX
2. Initialize volatility to 0 (or small value like 0.0001)
3. Store initial state:
   - slots[0] = price
   - slots[1] = 0 (or small initial volatility)
   - slots[2] = 0 (timestamp)
   - slots[3] = BASE_FEE
4. Return (BASE_FEE, BASE_FEE)
```

### After Trade (`afterSwap`)

```
1. Read previous state from slots
2. Calculate current AMM price: price = reserveY / reserveX
3. Calculate price change: |price - lastPrice| / lastPrice
4. Update volatility (EWMA): volatility = α × priceChange + (1-α) × oldVolatility
5. Calculate imbalance: |reserveX - reserveY| / (reserveX + reserveY)
6. Calculate fee multipliers:
   - volatility_factor = 1 + volatility_multiplier × volatility
   - imbalance_factor = 1 + imbalance_multiplier × imbalance
7. Calculate base fee: fee = BASE_FEE × volatility_factor × imbalance_factor
8. Apply time decay:
   - steps = timestamp - lastTimestamp
   - decayed_fee = BASE_FEE + (base_fee - BASE_FEE) × decay_factor^steps
9. Clamp fee: fee = clamp(decayed_fee, 0, MAX_FEE)
10. Store new state in slots
11. Return (fee, fee) [same for bid and ask]
```

---

## 🎛️ Parameter Tuning Guide

### Base Fee (`BASE_FEE`)
- **Range:** 20-50 bps
- **Lower:** More volume, more arbitrage risk
- **Higher:** Less volume, better protection
- **Start:** 30 bps

### Volatility Multiplier (`VOLATILITY_MULTIPLIER`)
- **Range:** 50-300
- **Lower:** Less responsive to volatility
- **Higher:** More aggressive fee increases
- **Start:** 100

### Imbalance Multiplier (`IMBALANCE_MULTIPLIER`)
- **Range:** 1-5
- **Lower:** Less responsive to imbalance
- **Higher:** More aggressive fee increases
- **Start:** 2

### EWMA Alpha (`ALPHA`)
- **Range:** 0.1-0.3
- **Lower:** Smoother, slower to react
- **Higher:** More reactive, noisier
- **Start:** 0.2

### Decay Factor (`DECAY_FACTOR`)
- **Range:** 0.95-0.99
- **Lower:** Faster decay back to base
- **Higher:** Slower decay, fees stay elevated longer
- **Start:** 0.98

---

## ⚡ Gas Optimization Tips

1. **Cache calculations:** Store intermediate values
2. **Avoid repeated storage reads:** Read slots once at start
3. **Use efficient math:** Leverage `wmul`, `wdiv` helpers
4. **Minimize storage writes:** Only write final values
5. **Simplify decay:** Use linear approximation for small steps

---

## 🧪 Testing Strategy

### Test Cases:

1. **Low Volatility, Balanced Pool**
   - Expected: Fee ≈ BASE_FEE (30 bps)

2. **High Volatility, Balanced Pool**
   - Expected: Fee > BASE_FEE (40-50 bps)

3. **Low Volatility, Imbalanced Pool**
   - Expected: Fee > BASE_FEE (35-45 bps)

4. **High Volatility, Imbalanced Pool**
   - Expected: Fee >> BASE_FEE (50-70 bps)

5. **Time Decay**
   - After raising fee, wait several steps
   - Expected: Fee decreases toward BASE_FEE

---

## 📊 Expected Performance

### Strengths:
- ✅ Adapts to market conditions
- ✅ Protects against arbitrage
- ✅ Attracts retail volume in calm markets
- ✅ Simple and gas-efficient

### Potential Improvements:
- Add trade size detection (large trades = higher fees)
- Add directional bias (fees higher on one side)
- Add adaptive parameter learning
- Add volatility regime detection

---

## 🚀 Implementation Priority

1. **Phase 1:** Basic volatility + imbalance calculation
2. **Phase 2:** Add time decay
3. **Phase 3:** Tune parameters based on simulator results
4. **Phase 4:** Add advanced features (if needed)

---

## 📝 Code Structure

```solidity
contract Strategy is AMMStrategyBase {
    // Constants
    uint256 constant BASE_FEE = 30e14;
    uint256 constant VOLATILITY_MULTIPLIER = 100e18;
    uint256 constant IMBALANCE_MULTIPLIER = 2e18;
    uint256 constant ALPHA = 2e17;
    uint256 constant DECAY_FACTOR = 98e16;
    
    // Slot indices
    uint256 constant SLOT_PRICE = 0;
    uint256 constant SLOT_VOLATILITY = 1;
    uint256 constant SLOT_TIMESTAMP = 2;
    uint256 constant SLOT_LAST_FEE = 3;
    
    function afterInitialize(...) { ... }
    function afterSwap(...) { ... }
    function getName() { ... }
}
```

---

## 🎓 Next Steps

1. **Implement** the algorithm in `AMMTemplate.sol`
2. **Test** with the simulator
3. **Analyze** results and edge scores
4. **Tune** parameters iteratively
5. **Optimize** gas usage if needed
