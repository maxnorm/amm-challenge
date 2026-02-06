"""Pytest fixtures for AMM competition tests."""

import pytest

from amm_competition.evm.baseline import get_vanilla_bytecode_and_abi, load_vanilla_strategy
from amm_competition.evm.adapter import EVMStrategyAdapter


@pytest.fixture(scope="session")
def vanilla_bytecode_and_abi():
    """Compile VanillaStrategy.sol once per test session."""
    return get_vanilla_bytecode_and_abi()


@pytest.fixture
def vanilla_strategy(vanilla_bytecode_and_abi):
    """Create a fresh VanillaStrategy instance (30 bps)."""
    bytecode, abi = vanilla_bytecode_and_abi
    return EVMStrategyAdapter(bytecode=bytecode, abi=abi)
