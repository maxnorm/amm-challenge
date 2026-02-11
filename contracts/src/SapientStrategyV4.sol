// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

/// @title Volatility + Imbalance Adaptive Fees Strategy (VIAF) v4
/// @notice v3 + toxicity from filtered price (pHat): charge more when flow is far from fair
/// @dev Inspired by toxicity concepts; keeps imbalance floor, decay, single-rule asymmetry
contract Strategy is AMMStrategyBase {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 constant BASE_FEE = 30e14;           // 30 bps base
    uint256 constant K_IMB = 2e18;               // Imbalance multiplier
    uint256 constant K_VOL = 15e18;              // Volatility multiplier
    uint256 constant ALPHA = 25e16;              // 0.25 EWMA for volatility
    uint256 constant DECAY_FACTOR = 96e16;      // 0.96 decay toward floor
    uint256 constant MAX_FEE_CAP = 100e14;      // Cap at 100 bps (v3 level; avoid over-charge)
    uint256 constant FLOOR_IMB_SCALE = 500e14;  // Imbalance floor scale
    uint256 constant ASYMM = 60e16;             // 60% extra on vulnerable side

    // --- Toxicity (v4) ---
    uint256 constant TOX_CAP = 20e16;            // Cap toxicity at 20%
    uint256 constant TOX_ALPHA = 10e16;          // 0.1 EWMA for toxicity
    uint256 constant PHAT_ALPHA = 26e16;        // 0.26 for filtered price update
    uint256 constant SIGMA_DECAY = 824e15;      // 0.824 for sigma EWMA
    uint256 constant GATE_SIGMA_MULT = 10e18;   // Adaptive gate = sigmaHat * this
    uint256 constant MIN_GATE = 3e16;           // Min gate 3%
    uint256 constant TOX_COEF = 25e14;           // 25 bps per unit tox (modest; was 50)
    uint256 constant TOX_QUAD_COEF = 60e14;      // 60 bps per tox^2 (modest; was 120)
    uint256 constant RET_CAP = 10e16;            // Cap return at 10% for sigma
    uint256 constant TRADE_TOX_BOOST = 18e14;    // 18 bps * toxEma on trade-aligned toxic flow
    uint256 constant TOX_BOOST_THRESHOLD = 1e16; // Only boost when toxEma >= 1%

    /*//////////////////////////////////////////////////////////////
                            STORAGE SLOT INDICES
    //////////////////////////////////////////////////////////////*/

    uint256 constant SLOT_PHAT = 0;              // Filtered fair price
    uint256 constant SLOT_VOLATILITY = 1;
    uint256 constant SLOT_TIMESTAMP = 2;
    uint256 constant SLOT_SIGMA = 3;             // Return vol (for gate)
    uint256 constant SLOT_TOX_EMA = 4;          // Toxicity EWMA

    uint256 constant ONE_WAD = 1e18;

    function _wmul(uint256 x, uint256 y) private pure returns (uint256) { return (x * y) / ONE_WAD; }
    function _wdiv(uint256 x, uint256 y) private pure returns (uint256) { return (x * ONE_WAD) / y; }
    function _abs(uint256 a, uint256 b) private pure returns (uint256) { return a > b ? a - b : b - a; }
    function _clampFee(uint256 fee) private pure returns (uint256) { return fee > MAX_FEE_CAP ? MAX_FEE_CAP : fee; }

    /*//////////////////////////////////////////////////////////////
                         INITIALIZATION FUNCTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize the strategy with starting reserves
    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256 bidFee, uint256 askFee) {
        uint256 initialPrice = initialX > 0 ? _wdiv(initialY, initialX) : ONE_WAD;
        slots[SLOT_PHAT] = initialPrice;
        slots[SLOT_VOLATILITY] = 0;
        slots[SLOT_TIMESTAMP] = 0;
        slots[SLOT_SIGMA] = 95e13;   // 0.095% initial sigma for gate
        slots[SLOT_TOX_EMA] = 0;
        return (BASE_FEE, BASE_FEE);
    }

    /*//////////////////////////////////////////////////////////////
                          FEE CALCULATION FUNCTION
    //////////////////////////////////////////////////////////////*/

    /// @notice After each trade: vol + imbalance + toxicity; floor; decay; single-rule asymmetry
    function afterSwap(TradeInfo calldata trade) external override returns (uint256 bidFee, uint256 askFee) {
        uint256 oldPHat = slots[SLOT_PHAT];
        uint256 oldVol = slots[SLOT_VOLATILITY];
        uint256 lastTs = slots[SLOT_TIMESTAMP];
        uint256 sigmaHat = slots[SLOT_SIGMA];
        uint256 toxEma = slots[SLOT_TOX_EMA];

        uint256 spot = trade.reserveX > 0 ? _wdiv(trade.reserveY, trade.reserveX) : oldPHat;
        uint256 pHat = oldPHat;
        if (pHat == 0) pHat = spot;

        // Return (for gate and sigma): |spot - pHat| / pHat
        uint256 ret = pHat > 0 ? _wdiv(_abs(spot, pHat), pHat) : 0;
        if (ret > RET_CAP) ret = RET_CAP;
        uint256 adaptiveGate = _wmul(sigmaHat, GATE_SIGMA_MULT);
        if (adaptiveGate < MIN_GATE) adaptiveGate = MIN_GATE;

        // Update filtered price only when move is within gate (reduce manipulation)
        if (ret <= adaptiveGate) {
            pHat = _wmul(ONE_WAD - PHAT_ALPHA, pHat) + _wmul(PHAT_ALPHA, spot);
        }
        sigmaHat = _wmul(SIGMA_DECAY, sigmaHat) + _wmul(ONE_WAD - SIGMA_DECAY, ret);

        // Volatility: |spot - oldPHat| / oldPHat
        uint256 priceCh = oldPHat > 0 ? _wdiv(_abs(spot, oldPHat), oldPHat) : 0;
        uint256 vol = _wmul(ALPHA, priceCh) + _wmul(ONE_WAD - ALPHA, oldVol);

        // Toxicity: deviation from fair (capped), then EWMA
        uint256 tox = ret > TOX_CAP ? TOX_CAP : ret;
        toxEma = _wmul(ONE_WAD - TOX_ALPHA, toxEma) + _wmul(TOX_ALPHA, tox);

        uint256 totalReserves = trade.reserveX + trade.reserveY;
        uint256 imbalance = totalReserves > 0 ? _wdiv(_abs(trade.reserveX, trade.reserveY), totalReserves) : 0;

        // Base raw fee: vol and imbalance factors
        uint256 volFactor = ONE_WAD + _wmul(K_VOL, vol);
        uint256 imbFactor = ONE_WAD + _wmul(K_IMB, imbalance);
        uint256 rawFee = _wmul(BASE_FEE, _wmul(volFactor, imbFactor));

        // Toxicity add-on (linear + quadratic)
        rawFee = rawFee + _wmul(TOX_COEF, toxEma) + _wmul(TOX_QUAD_COEF, _wmul(toxEma, toxEma));

        // Imbalance floor
        uint256 imbFloor = BASE_FEE + _wmul(imbalance, FLOOR_IMB_SCALE);
        if (rawFee < imbFloor) rawFee = imbFloor;

        // Decay toward floor over no-trade steps
        if (trade.timestamp > lastTs && lastTs > 0 && rawFee > imbFloor) {
            uint256 steps = trade.timestamp - lastTs;
            uint256 decay = _wmul(steps, ONE_WAD - DECAY_FACTOR);
            if (decay > ONE_WAD) decay = ONE_WAD;
            uint256 excess = rawFee - imbFloor;
            rawFee = imbFloor + _wmul(ONE_WAD - decay, excess);
        }

        uint256 baseFee = rawFee > MAX_FEE_CAP ? MAX_FEE_CAP : rawFee;

        // Single-rule asymmetry: rich in Y => raise bid; else raise ask
        bool richInY = trade.reserveY >= trade.reserveX;
        uint256 bidFeeOut;
        uint256 askFeeOut;
        if (richInY) {
            bidFeeOut = _clampFee(_wmul(baseFee, ONE_WAD + ASYMM));
            askFeeOut = baseFee;
        } else {
            askFeeOut = _clampFee(_wmul(baseFee, ONE_WAD + ASYMM));
            bidFeeOut = baseFee;
        }

        // Trade-aligned toxicity boost: only when toxEma >= threshold (avoid boosting benign flow)
        bool tradeAligned = (trade.isBuy && spot >= oldPHat) || (!trade.isBuy && spot < oldPHat);
        if (tradeAligned && toxEma >= TOX_BOOST_THRESHOLD) {
            uint256 boost = _wmul(TRADE_TOX_BOOST, toxEma);
            if (trade.isBuy) {
                bidFeeOut = _clampFee(bidFeeOut + boost);
            } else {
                askFeeOut = _clampFee(askFeeOut + boost);
            }
        }

        slots[SLOT_PHAT] = pHat;
        slots[SLOT_VOLATILITY] = vol;
        slots[SLOT_TIMESTAMP] = trade.timestamp;
        slots[SLOT_SIGMA] = sigmaHat;
        slots[SLOT_TOX_EMA] = toxEma;

        return (bidFeeOut, askFeeOut);
    }

    /*//////////////////////////////////////////////////////////////
                            UTILITY FUNCTION
    //////////////////////////////////////////////////////////////*/

    function getName() external pure override returns (string memory) {
        return "Sapient v4 - (toxicity + imbalance-floor + asym)";
    }
}
