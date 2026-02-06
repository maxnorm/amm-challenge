"""Tests for competition framework."""

import pytest
from decimal import Decimal

import amm_sim_rs

from amm_competition.competition.match import MatchRunner, HyperparameterVariance
from amm_competition.competition.elo import EloRating
from amm_competition.competition.scoring import calculate_pnl, calculate_return, AMMState


class TestScoring:
    def test_calculate_pnl_no_change(self):
        initial = AMMState(
            name="test",
            reserve_x=Decimal("100"),
            reserve_y=Decimal("10000"),
            spot_price=Decimal("100"),
        )
        final = AMMState(
            name="test",
            reserve_x=Decimal("100"),
            reserve_y=Decimal("10000"),
            spot_price=Decimal("100"),
        )

        pnl = calculate_pnl(initial, final, Decimal("100"), Decimal("100"))
        assert pnl == Decimal("0")

    def test_calculate_pnl_with_gain(self):
        initial = AMMState(
            name="test",
            reserve_x=Decimal("100"),
            reserve_y=Decimal("10000"),
            spot_price=Decimal("100"),
        )
        final = AMMState(
            name="test",
            reserve_x=Decimal("100"),
            reserve_y=Decimal("10500"),  # +500 Y
            spot_price=Decimal("105"),
        )

        pnl = calculate_pnl(initial, final, Decimal("100"), Decimal("100"))
        assert pnl == Decimal("500")

    def test_calculate_pnl_price_increase(self):
        """Test PNL when holding X and price increases."""
        initial = AMMState(
            name="test",
            reserve_x=Decimal("100"),
            reserve_y=Decimal("10000"),
            spot_price=Decimal("100"),
        )
        final = AMMState(
            name="test",
            reserve_x=Decimal("100"),
            reserve_y=Decimal("10000"),
            spot_price=Decimal("100"),
        )

        # Price doubled - should have 10000 gain from X appreciation
        pnl = calculate_pnl(initial, final, Decimal("100"), Decimal("200"))
        assert pnl == Decimal("10000")

    def test_calculate_return(self):
        ret = calculate_return(Decimal("100"), Decimal("1000"))
        assert ret == Decimal("0.1")

    def test_calculate_return_zero_initial(self):
        ret = calculate_return(Decimal("100"), Decimal("0"))
        assert ret == Decimal("0")


class TestEloRating:
    def test_initial_rating(self):
        elo = EloRating(initial_rating=1500)
        rating = elo.get_rating("player1")
        assert rating.rating == 1500
        assert rating.matches_played == 0

    def test_expected_score_equal_ratings(self):
        elo = EloRating()
        expected = elo.expected_score(1500, 1500)
        assert abs(expected - 0.5) < 0.001

    def test_expected_score_higher_rating(self):
        elo = EloRating()
        expected = elo.expected_score(1600, 1400)
        assert expected > 0.5

    def test_update_ratings_winner_gains(self):
        elo = EloRating()
        initial_a = elo.get_rating("A").rating
        initial_b = elo.get_rating("B").rating

        # A wins 7-2
        elo.update_ratings("A", "B", 7, 2)

        assert elo.get_rating("A").rating > initial_a
        assert elo.get_rating("B").rating < initial_b

    def test_update_ratings_tracks_wins(self):
        elo = EloRating()
        elo.update_ratings("A", "B", 7, 2)

        assert elo.get_rating("A").wins == 1
        assert elo.get_rating("A").losses == 0
        assert elo.get_rating("B").wins == 0
        assert elo.get_rating("B").losses == 1

    def test_update_ratings_draw(self):
        elo = EloRating()
        initial_a = elo.get_rating("A").rating

        elo.update_ratings("A", "B", 5, 5)

        assert elo.get_rating("A").draws == 1
        assert elo.get_rating("B").draws == 1

    def test_leaderboard_sorted(self):
        elo = EloRating()
        # Create some ratings
        elo.ratings["C"] = elo.get_rating("C")
        elo.ratings["C"].rating = 1600
        elo.ratings["A"] = elo.get_rating("A")
        elo.ratings["A"].rating = 1400
        elo.ratings["B"] = elo.get_rating("B")
        elo.ratings["B"].rating = 1500

        leaderboard = elo.get_leaderboard()
        assert leaderboard[0].name == "C"
        assert leaderboard[1].name == "B"
        assert leaderboard[2].name == "A"

    def test_margin_multiplier_increases_with_margin(self):
        elo = EloRating(mov_factor=0.5)
        mult_close = elo.margin_multiplier(6, 5, 11)
        mult_wide = elo.margin_multiplier(9, 2, 11)
        assert mult_wide > mult_close


class TestMatchRunner:
    def test_run_match(self, vanilla_bytecode_and_abi):
        from amm_competition.evm.adapter import EVMStrategyAdapter

        config = amm_sim_rs.SimulationConfig(
            n_steps=50,
            initial_price=100.0,
            initial_x=100.0,
            initial_y=10000.0,
            gbm_mu=0.0,
            gbm_sigma=0.02,
            gbm_dt=1 / 252,
            retail_arrival_rate=5.0,
            retail_mean_size=2.0,
            retail_size_sigma=0.7,
            retail_buy_prob=0.5,
            seed=42,
        )
        variance = HyperparameterVariance(
            retail_mean_size_min=2.0,
            retail_mean_size_max=2.0,
            vary_retail_mean_size=False,
            retail_arrival_rate_min=5.0,
            retail_arrival_rate_max=5.0,
            vary_retail_arrival_rate=False,
            gbm_sigma_min=0.02,
            gbm_sigma_max=0.02,
            vary_gbm_sigma=False,
        )
        runner = MatchRunner(n_simulations=5, config=config, n_workers=1, variance=variance)

        bytecode, abi = vanilla_bytecode_and_abi
        strategy_a = EVMStrategyAdapter(bytecode=bytecode, abi=abi)
        strategy_b = EVMStrategyAdapter(bytecode=bytecode, abi=abi, name="Vanilla_30bps")

        result = runner.run_match(strategy_a, strategy_b)

        assert result.total_games == 5
        assert result.wins_a + result.wins_b + result.draws == 5
        assert result.strategy_a == "Vanilla_30bps"
        assert result.strategy_b == "Vanilla_30bps"

    def test_match_winner(self, vanilla_bytecode_and_abi):
        from amm_competition.evm.adapter import EVMStrategyAdapter

        config = amm_sim_rs.SimulationConfig(
            n_steps=50,
            initial_price=100.0,
            initial_x=100.0,
            initial_y=10000.0,
            gbm_mu=0.0,
            gbm_sigma=0.02,
            gbm_dt=1 / 252,
            retail_arrival_rate=5.0,
            retail_mean_size=2.0,
            retail_size_sigma=0.7,
            retail_buy_prob=0.5,
            seed=42,
        )
        variance = HyperparameterVariance(
            retail_mean_size_min=2.0,
            retail_mean_size_max=2.0,
            vary_retail_mean_size=False,
            retail_arrival_rate_min=5.0,
            retail_arrival_rate_max=5.0,
            vary_retail_arrival_rate=False,
            gbm_sigma_min=0.02,
            gbm_sigma_max=0.02,
            vary_gbm_sigma=False,
        )
        runner = MatchRunner(n_simulations=11, config=config, n_workers=1, variance=variance)

        bytecode, abi = vanilla_bytecode_and_abi
        strategy_a = EVMStrategyAdapter(bytecode=bytecode, abi=abi)
        strategy_b = EVMStrategyAdapter(bytecode=bytecode, abi=abi)

        result = runner.run_match(strategy_a, strategy_b)

        # Winner can be either, but total should be 11
        assert result.total_games == 11

    def test_pnl_accumulated(self, vanilla_bytecode_and_abi):
        from amm_competition.evm.adapter import EVMStrategyAdapter

        config = amm_sim_rs.SimulationConfig(
            n_steps=50,
            initial_price=100.0,
            initial_x=100.0,
            initial_y=10000.0,
            gbm_mu=0.0,
            gbm_sigma=0.02,
            gbm_dt=1 / 252,
            retail_arrival_rate=5.0,
            retail_mean_size=2.0,
            retail_size_sigma=0.7,
            retail_buy_prob=0.5,
            seed=42,
        )
        variance = HyperparameterVariance(
            retail_mean_size_min=2.0,
            retail_mean_size_max=2.0,
            vary_retail_mean_size=False,
            retail_arrival_rate_min=5.0,
            retail_arrival_rate_max=5.0,
            vary_retail_arrival_rate=False,
            gbm_sigma_min=0.02,
            gbm_sigma_max=0.02,
            vary_gbm_sigma=False,
        )
        runner = MatchRunner(n_simulations=5, config=config, n_workers=1, variance=variance)

        bytecode, abi = vanilla_bytecode_and_abi
        strategy_a = EVMStrategyAdapter(bytecode=bytecode, abi=abi)
        strategy_b = EVMStrategyAdapter(bytecode=bytecode, abi=abi, name="Vanilla_50bps")

        result = runner.run_match(strategy_a, strategy_b)

        # PNL should be accumulated across simulations
        assert result.total_pnl_a != Decimal("0") or result.total_pnl_b != Decimal("0")

    def test_store_results(self, vanilla_bytecode_and_abi):
        from amm_competition.evm.adapter import EVMStrategyAdapter

        config = amm_sim_rs.SimulationConfig(
            n_steps=50,
            initial_price=100.0,
            initial_x=100.0,
            initial_y=10000.0,
            gbm_mu=0.0,
            gbm_sigma=0.02,
            gbm_dt=1 / 252,
            retail_arrival_rate=5.0,
            retail_mean_size=2.0,
            retail_size_sigma=0.7,
            retail_buy_prob=0.5,
            seed=42,
        )
        variance = HyperparameterVariance(
            retail_mean_size_min=2.0,
            retail_mean_size_max=2.0,
            vary_retail_mean_size=False,
            retail_arrival_rate_min=5.0,
            retail_arrival_rate_max=5.0,
            vary_retail_arrival_rate=False,
            gbm_sigma_min=0.02,
            gbm_sigma_max=0.02,
            vary_gbm_sigma=False,
        )
        runner = MatchRunner(n_simulations=3, config=config, n_workers=1, variance=variance)

        bytecode, abi = vanilla_bytecode_and_abi
        strategy_a = EVMStrategyAdapter(bytecode=bytecode, abi=abi)
        strategy_b = EVMStrategyAdapter(bytecode=bytecode, abi=abi, name="Vanilla_30bps")

        result = runner.run_match(strategy_a, strategy_b, store_results=True)

        assert len(result.simulation_results) == 3

    def test_same_name_strategies_no_collision(self, vanilla_bytecode_and_abi):
        """Test that strategies with the same getName() don't cause HashMap collision."""
        from amm_competition.evm.adapter import EVMStrategyAdapter

        config = amm_sim_rs.SimulationConfig(
            n_steps=50,
            initial_price=100.0,
            initial_x=100.0,
            initial_y=10000.0,
            gbm_mu=0.0,
            gbm_sigma=0.02,
            gbm_dt=1 / 252,
            retail_arrival_rate=5.0,
            retail_mean_size=2.0,
            retail_size_sigma=0.7,
            retail_buy_prob=0.5,
            seed=42,
        )
        variance = HyperparameterVariance(
            retail_mean_size_min=2.0,
            retail_mean_size_max=2.0,
            vary_retail_mean_size=False,
            retail_arrival_rate_min=5.0,
            retail_arrival_rate_max=5.0,
            vary_retail_arrival_rate=False,
            gbm_sigma_min=0.02,
            gbm_sigma_max=0.02,
            vary_gbm_sigma=False,
        )
        runner = MatchRunner(n_simulations=5, config=config, n_workers=1, variance=variance)

        # Both strategies use same bytecode and will have same getName() return value
        # Without the fix, this would cause a HashMap key collision
        bytecode, abi = vanilla_bytecode_and_abi
        strategy_a = EVMStrategyAdapter(bytecode=bytecode, abi=abi)
        strategy_b = EVMStrategyAdapter(bytecode=bytecode, abi=abi)

        # Both should return "Vanilla_30bps" from get_name()
        assert strategy_a.get_name() == strategy_b.get_name() == "Vanilla_30bps"

        result = runner.run_match(strategy_a, strategy_b, store_results=True)

        # Should complete without errors and have valid results
        assert result.total_games == 5
        # Since both strategies are identical, results should be a draw or close
        # The important thing is that we get results for both, not zeros
        assert len(result.simulation_results) == 5
        # Check that simulation results contain data for both strategies
        first_sim = result.simulation_results[0]
        assert len(first_sim.pnl) == 2  # Should have PnL for both strategies
