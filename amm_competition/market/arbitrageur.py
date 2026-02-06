"""Arbitrageur logic for extracting profit from mispriced AMMs."""

import math
from dataclasses import dataclass
from decimal import Decimal
from typing import Optional

from amm_competition.core.amm import AMM


@dataclass
class ArbResult:
    """Result of an arbitrage attempt."""
    amm: AMM
    profit: Decimal
    side: str  # "buy" or "sell" from AMM perspective
    amount_x: Decimal
    amount_y: Decimal


class Arbitrageur:
    """Finds and executes optimal arbitrage trades.

    Uses closed-form solutions for constant product AMMs.
    For reserves (x, y), k=xy, fee f (fee-on-input), γ = 1 - f, and fair price p (Y per X):
    - Buy X from AMM (AMM sells X): Δx_out = x - sqrt(k / (γ·p))  (profit-maximizing)
    - Sell X to AMM (AMM buys X): Δx_in = (sqrt(k·γ / p) - x) / γ (profit-maximizing, Δx_in is gross input)
    """

    def find_arb_opportunity(
        self, amm: AMM, fair_price: Decimal
    ) -> Optional[ArbResult]:
        """Find the optimal arbitrage trade for an AMM.

        If AMM price < fair price: buy X from AMM, sell at fair price
        If AMM price > fair price: sell X to AMM, buy at fair price

        Args:
            amm: The AMM to arbitrage
            fair_price: The true/fair market price (Y per X)

        Returns:
            ArbResult with optimal trade, or None if no profitable arb
        """
        x, y = amm.reserve_x, amm.reserve_y
        spot_price = y / x

        if spot_price < fair_price:
            # AMM underprices X - buy X from AMM (AMM sells X)
            return self._compute_buy_arb(amm, fair_price)
        elif spot_price > fair_price:
            # AMM overprices X - sell X to AMM (AMM buys X)
            return self._compute_sell_arb(amm, fair_price)
        return None

    def _compute_buy_arb(self, amm: AMM, fair_price: Decimal) -> Optional[ArbResult]:
        """Compute optimal trade when buying X from AMM (AMM sells X).

        Maximize profit = Δx * p - Y_paid
        Closed-form (fee-on-input): Δx_out = x - sqrt(k / (γ·p))
        """
        # Use float for fast math
        x_f = float(amm.reserve_x)
        y_f = float(amm.reserve_y)
        k_f = x_f * y_f
        f_f = float(amm.current_fees.ask_fee)
        p_f = float(fair_price)

        gamma = 1.0 - f_f
        if gamma <= 0.0 or p_f <= 0.0:
            return None

        # Optimal trade size using float
        new_x_f = math.sqrt(k_f / (gamma * p_f))
        amount_x_f = x_f - new_x_f

        if amount_x_f <= 0:
            return None

        # Cap at 99% of reserves and convert back to Decimal
        amount_x_f = min(amount_x_f, x_f * 0.99)
        amount_x = Decimal(str(amount_x_f))

        # Use fast quote to compute profit
        total_y, _ = amm._fast_quote_sell_x(amount_x_f)
        if total_y <= 0:
            return None

        # Profit = value of X at fair price - Y paid (all in float)
        profit_f = amount_x_f * p_f - total_y
        profit = Decimal(str(profit_f))

        if profit <= 0:
            return None

        return ArbResult(
            amm=amm,
            profit=profit,
            side="sell",  # AMM sells X
            amount_x=amount_x,
            amount_y=Decimal(str(total_y)),
        )

    def _compute_sell_arb(self, amm: AMM, fair_price: Decimal) -> Optional[ArbResult]:
        """Compute optimal trade when selling X to AMM (AMM buys X).

        Maximize profit = Y_received - Δx * p
        Closed-form (fee-on-input): Δx_in = (sqrt(k·γ / p) - x) / γ
        """
        # Use float for fast math
        x_f = float(amm.reserve_x)
        y_f = float(amm.reserve_y)
        k_f = x_f * y_f
        f_f = float(amm.current_fees.bid_fee)
        p_f = float(fair_price)

        gamma = 1.0 - f_f
        if gamma <= 0.0 or p_f <= 0.0:
            return None

        # Optimal trade size (gross input) using float:
        # x + γ·Δx_in = sqrt(k·γ/p)  =>  Δx_in = (sqrt(k·γ/p) - x) / γ
        x_virtual_f = math.sqrt(k_f * gamma / p_f)
        net_x_f = x_virtual_f - x_f
        amount_x_f = net_x_f / gamma

        if amount_x_f <= 0:
            return None

        # Use fast quote to compute profit
        y_out, _ = amm._fast_quote_buy_x(amount_x_f)
        if y_out <= 0:
            return None

        # Profit = Y received - cost of X at fair price (all in float)
        profit_f = y_out - amount_x_f * p_f
        profit = Decimal(str(profit_f))
        amount_x = Decimal(str(amount_x_f))

        if profit <= 0:
            return None

        return ArbResult(
            amm=amm,
            profit=profit,
            side="buy",  # AMM buys X
            amount_x=amount_x,
            amount_y=Decimal(str(y_out)),
        )

    def execute_arb(
        self, amm: AMM, fair_price: Decimal, timestamp: int
    ) -> Optional[ArbResult]:
        """Find and execute the optimal arbitrage trade.

        Args:
            amm: The AMM to arbitrage
            fair_price: The fair market price
            timestamp: Current simulation step

        Returns:
            ArbResult if arb was executed, None otherwise
        """
        opportunity = self.find_arb_opportunity(amm, fair_price)

        if opportunity is None:
            return None

        # Execute the trade
        if opportunity.side == "sell":  # AMM sells X
            trade = amm.execute_sell_x(opportunity.amount_x, timestamp)
        else:  # AMM buys X
            trade = amm.execute_buy_x(opportunity.amount_x, timestamp)

        if trade is None:
            return None

        return opportunity

    def arbitrage_all(
        self, amms: list[AMM], fair_price: Decimal, timestamp: int
    ) -> list[ArbResult]:
        """Execute arbitrage on all AMMs.

        Args:
            amms: List of AMMs to arbitrage
            fair_price: The fair market price
            timestamp: Current simulation step

        Returns:
            List of successful arbitrage results
        """
        results = []
        for amm in amms:
            result = self.execute_arb(amm, fair_price, timestamp)
            if result:
                results.append(result)
        return results
