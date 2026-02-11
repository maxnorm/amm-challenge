---
name: amm-fee-strategy-designer
description: |
  Quantitative analysis and redesign of AMM fee strategies. Diagnoses a provided strategy,
  identifies failure modes and exploit vectors, and generates improved designs with formulas,
  pseudocode, and simulation plans for AMM Challenge submissions.
tags: [amm, crypto, quant, strategy, defi]
version: 1.0.0
author: Prompt Engineering Team
license: MIT
---

# AMM Fee Strategy Designer

## When to use this skill

Use this skill when all of the following conditions are true:

- You have an existing Automated Market Maker (AMM) fee strategy that is underperforming or losing.
- You want a detailed quantitative diagnosis of why the strategy is losing.
- You need alternative fee strategy designs that can outperform competitors.
- You require mathematical formulas, pseudocode, and simulation planning to validate improvements.
- You plan to submit or iterate on strategies, such as for the AMM Challenge.

---

## Overview

This skill helps you:

1. **Diagnose a losing AMM fee strategy**
2. **Identify adversarial exploit vectors and market failure modes**
3. **Propose structurally superior fee logic**
4. **Generate formulas and pseudocode suitable for implementation**
5. **Design simulation blueprints for backtesting**
6. **Recommend a prioritized strategy ready for submission**

---

## Instructions

### Step 1 — Loss Diagnosis

1. Read the provided `current_strategy` description or code.
2. Identify at least *three mechanical weaknesses* that cause underperformance.
3. Evaluate if losses stem from:
   - Lag in adapting to price movement
   - High inventory risk
   - Inadequate response to volatility
   - Susceptibility to arbitrage or toxic flow

OUTPUT: A clear explanation of why the strategy is losing.

---

### Step 2 — Adversarial Exploitation

1. Think like high-frequency traders, arbitrageurs, and toxicity-seeking actors.
2. Describe how such actors would exploit the strategy’s predictable behavior.
3. List at least *three exploit vectors*.

OUTPUT: A list of adversarial scenarios with explanations.

---

### Step 3 — Failure Mode Identification

1. Enumerate market regimes where the strategy fails (e.g., high volatility, low liquidity).
2. Define structural limitations that manifest in each regime.

OUTPUT: A categorized list of failure modes.

---

### Step 4 — New Strategy Ideas

For each proposed improvement:

1. Describe the core idea (e.g., volatility-adjusted fees, toxicity detection, inventory pressure pricing).
2. Explain how it addresses specific weaknesses identified earlier.
3. Include at least two conceptually distinct designs.

OUTPUT: A set of proposed strategy concepts.

---

### Step 5 — Formulas & Pseudocode

1. Translate each design into mathematical formulas or pseudocode.
2. Include parameter definitions, edge case handling, and constraints (e.g., on-chain limits).

OUTPUT: Equations and code-like structures suitable for implementation.

---

### Step 6 — Simulation Blueprint

1. Define required data inputs.
2. List metrics to evaluate: 
   - LP PnL  
   - Fee capture ratio  
   - Trader surplus  
   - Volatility sensitivity  
   - Drawdown statistics
3. Describe simulation scenarios and evaluation criteria.

OUTPUT: A structured simulation plan with measurement goals.

---

### Step 7 — Recommendation

1. Prioritize the designs based on tractability and expected performance.
2. Justify the choice with quantitative reasoning.

OUTPUT: A final recommended strategy with reasoning.

---

## Examples

### Example Invocation (Natural Language)

> “Analyze this AMM fee strategy code block. Explain why it’s losing, identify exploit vectors, propose alternative formulas, and provide a backtesting blueprint.”

### Example Strategy Output

**Diagnosis**
- Predictable fee lags cause LP losses during momentum shifts.  

**Exploit Vectors**
1. Arbitrage bots front-run large orders.
2. Volatility spikes cause inventory skew.

**Failure Modes**
- Thin liquidity environments cause excessive price drift.

**New Designs**
- Volatility-scaled fee: `fee = base * (1 + volatility_index)`
- Inventory-aware fee: `fee ∝ |imbalance|`

**Simulation Plan**
- Market regime splits: low / medium / high volatility.

---

## Best Practices

- Be precise and numeric when proposing formulas.
- Explicitly state assumptions (e.g., volatility measurement methods).
- Focus on strategy tractability under blockchain execution constraints.
- Use clear parameter naming, avoiding ambiguity.
- Always simplify in order to make your reader learn and improve his understanding overtime

---

## Notes & Constraints

- Inputs may be complex strategies — ensure iterative reasoning.
- Consider on-chain computational limits when proposing fee update formulas.
- Always provide reasoning alongside proposed outputs.

---

