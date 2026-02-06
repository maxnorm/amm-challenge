"""Utility to load the default 30bps strategy used as the normalizer AMM."""

from pathlib import Path
from typing import Optional, Tuple

from amm_competition.evm.adapter import EVMStrategyAdapter
from amm_competition.evm.compiler import SolidityCompiler

_CACHED_BYTECODE: Optional[bytes] = None
_CACHED_ABI: Optional[list] = None


def get_vanilla_bytecode_and_abi() -> Tuple[bytes, list]:
    """Compile VanillaStrategy.sol once and cache.

    Returns:
        Tuple of (bytecode, abi) for the VanillaStrategy contract.

    Raises:
        RuntimeError: If compilation fails.
    """
    global _CACHED_BYTECODE, _CACHED_ABI
    if _CACHED_BYTECODE is None:
        contracts_dir = Path(__file__).parent.parent.parent / "contracts" / "src"
        source = (contracts_dir / "VanillaStrategy.sol").read_text()
        compiler = SolidityCompiler()
        result = compiler.compile(source, contract_name="VanillaStrategy")
        if not result.success:
            raise RuntimeError(f"Failed to compile VanillaStrategy: {result.errors}")
        _CACHED_BYTECODE = result.bytecode
        _CACHED_ABI = result.abi
    return _CACHED_BYTECODE, _CACHED_ABI


def load_vanilla_strategy() -> EVMStrategyAdapter:
    """Load the default 30bps strategy used as the normalizer AMM.

    The normalizer AMM prevents degenerate strategies (like extreme fees)
    from appearing profitable by providing competition for retail flow.

    Returns:
        EVMStrategyAdapter wrapping the compiled VanillaStrategy.sol (30 bps).
    """
    bytecode, abi = get_vanilla_bytecode_and_abi()
    return EVMStrategyAdapter(bytecode=bytecode, abi=abi)
