"""Trade data classes."""

from dataclasses import dataclass
from decimal import Decimal
from enum import Enum
from typing import Literal


class TradeSide(Enum):
    """Side of a trade from the AMM's perspective."""
    BUY = "buy"    # AMM buys X (trader sells X)
    SELL = "sell"  # AMM sells X (trader buys X)


@dataclass(frozen=True)
class FeeQuote:
    """Fee quote returned by an AMM strategy.

    Fees are expressed as decimals (e.g., 0.003 = 30bps).
    """
    bid_fee: Decimal  # Fee when AMM buys X
    ask_fee: Decimal  # Fee when AMM sells X

    def __post_init__(self) -> None:
        if self.bid_fee < 0:
            raise ValueError(f"bid_fee must be >= 0, got {self.bid_fee}")
        if self.ask_fee < 0:
            raise ValueError(f"ask_fee must be >= 0, got {self.ask_fee}")

    @classmethod
    def symmetric(cls, fee: Decimal) -> "FeeQuote":
        """Create a symmetric fee quote (same bid and ask)."""
        return cls(bid_fee=fee, ask_fee=fee)


@dataclass(frozen=True)
class TradeInfo:
    """Information about an executed trade, provided to AMM strategies.

    This is the only information strategies receive about market activity.
    Strategies cannot see external prices, other AMM states, or any other data.
    """
    side: Literal["buy", "sell"]  # From AMM's perspective
    amount_x: Decimal             # Amount of X traded
    amount_y: Decimal             # Amount of Y traded
    timestamp: int                # Simulation step number
    reserve_x: Decimal            # Post-trade X reserves
    reserve_y: Decimal            # Post-trade Y reserves

    @property
    def implied_price(self) -> Decimal:
        """The effective price of this trade (Y per X)."""
        if self.amount_x == 0:
            return Decimal("0")
        return self.amount_y / self.amount_x
