// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

/// @title VIAF Strategy V5 — Directionality + inventory-toxicity + surge
/// @notice Research-backed: asymmetric fees mimic price direction (Alexander & Fritz 2024);
///         toxicity only on vulnerable side; surge on gate breach (Aegis-style).
/// @dev See /docs/Sapient-v5-research-and-redesign.md
contract Strategy is AMMStrategyBase {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 constant BASE_FEE = 30e14;           // 30 bps base
    uint256 constant K_IMB = 2e18;               // Imbalance multiplier
    uint256 constant K_VOL = 15e18;               // Volatility multiplier
    uint256 constant ALPHA = 25e16;              // 0.25 EWMA for volatility
    uint256 constant DECAY_FACTOR = 96e16;        // 0.96 decay toward floor
    uint256 constant MAX_FEE_CAP = 100e14;       // Cap at 100 bps
    uint256 constant FLOOR_IMB_SCALE = 500e14;   // Imbalance floor scale
    uint256 constant ASYMM = 60e16;               // 60% extra on vulnerable side

    // Toxicity (v4-style, but applied only to vulnerable side)
    uint256 constant TOX_CAP = 20e16;
    uint256 constant TOX_ALPHA = 10e16;
    uint256 constant PHAT_ALPHA = 26e16;
    uint256 constant SIGMA_DECAY = 824e15;
    uint256 constant GATE_SIGMA_MULT = 10e18;
    uint256 constant MIN_GATE = 3e16;
    uint256 constant TOX_COEF = 25e14;           // 25 bps per unit tox
    uint256 constant TOX_QUAD_COEF = 60e14;      // 60 bps per tox^2
    uint256 constant RET_CAP = 10e16;
    // V5: no TRADE_TOX_BOOST — toxicity only on vulnerable side

    // V5 — Directionality-mimicking asymmetry (Alexander & Fritz)
    uint256 constant DIR_BPS_PER_UNIT_RET = 200e14;  // ~20 bps per 10% move
    uint256 constant CAP_DIR_BPS = 20e14;             // Cap directional premium at 20 bps

    // V5 — Surge on gate breach (Aegis-style cap event)
    uint256 constant SURGE_BPS = 15e14;              // 15 bps one-shot when ret > gate

    /*//////////////////////////////////////////////////////////////
                            STORAGE SLOT INDICES
    //////////////////////////////////////////////////////////////*/

    uint256 constant SLOT_PHAT = 0;
    uint256 constant SLOT_VOLATILITY = 1;
    uint256 constant SLOT_TIMESTAMP = 2;
    uint256 constant SLOT_SIGMA = 3;
    uint256 constant SLOT_TOX_EMA = 4;

    uint256 constant ONE_WAD = 1e18;

    function _wmul(uint256 x, uint256 y) private pure returns (uint256) { return (x * y) / ONE_WAD; }
    function _wdiv(uint256 x, uint256 y) private pure returns (uint256) { return (x * ONE_WAD) / y; }
    function _abs(uint256 a, uint256 b) private pure returns (uint256) { return a > b ? a - b : b - a; }
    function _clampFee(uint256 fee) private pure returns (uint256) { return fee > MAX_FEE_CAP ? MAX_FEE_CAP : fee; }

    /*//////////////////////////////////////////////////////////////
                         INITIALIZATION FUNCTION
    //////////////////////////////////////////////////////////////*/

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256 bidFee, uint256 askFee) {
        uint256 initialPrice = initialX > 0 ? _wdiv(initialY, initialX) : ONE_WAD;
        slots[SLOT_PHAT] = initialPrice;
        slots[SLOT_VOLATILITY] = 0;
        slots[SLOT_TIMESTAMP] = 0;
        slots[SLOT_SIGMA] = 95e13;
        slots[SLOT_TOX_EMA] = 0;
        return (BASE_FEE, BASE_FEE);
    }

    /*//////////////////////////////////////////////////////////////
                          FEE CALCULATION FUNCTION
    //////////////////////////////////////////////////////////////*/

    /// @notice V5: base (vol+imb+floor+decay) + toxicity on vulnerable side only + directionality + surge on gate breach
    function afterSwap(TradeInfo calldata trade) external override returns (uint256 bidFee, uint256 askFee) {
        uint256 oldPHat = slots[SLOT_PHAT];
        uint256 oldVol = slots[SLOT_VOLATILITY];
        uint256 lastTs = slots[SLOT_TIMESTAMP];
        uint256 sigmaHat = slots[SLOT_SIGMA];
        uint256 toxEma = slots[SLOT_TOX_EMA];

        uint256 spot = trade.reserveX > 0 ? _wdiv(trade.reserveY, trade.reserveX) : oldPHat;
        uint256 pHat = oldPHat;
        if (pHat == 0) pHat = spot;

        uint256 ret = pHat > 0 ? _wdiv(_abs(spot, pHat), pHat) : 0;
        if (ret > RET_CAP) ret = RET_CAP;
        uint256 adaptiveGate = _wmul(sigmaHat, GATE_SIGMA_MULT);
        if (adaptiveGate < MIN_GATE) adaptiveGate = MIN_GATE;

        if (ret <= adaptiveGate) {
            pHat = _wmul(ONE_WAD - PHAT_ALPHA, pHat) + _wmul(PHAT_ALPHA, spot);
        }
        sigmaHat = _wmul(SIGMA_DECAY, sigmaHat) + _wmul(ONE_WAD - SIGMA_DECAY, ret);

        uint256 priceCh = oldPHat > 0 ? _wdiv(_abs(spot, oldPHat), oldPHat) : 0;
        uint256 vol = _wmul(ALPHA, priceCh) + _wmul(ONE_WAD - ALPHA, oldVol);

        uint256 tox = ret > TOX_CAP ? TOX_CAP : ret;
        toxEma = _wmul(ONE_WAD - TOX_ALPHA, toxEma) + _wmul(TOX_ALPHA, tox);

        uint256 totalReserves = trade.reserveX + trade.reserveY;
        uint256 imbalance = totalReserves > 0 ? _wdiv(_abs(trade.reserveX, trade.reserveY), totalReserves) : 0;

        // Base raw fee: vol and imbalance only (no symmetric toxicity)
        uint256 volFactor = ONE_WAD + _wmul(K_VOL, vol);
        uint256 imbFactor = ONE_WAD + _wmul(K_IMB, imbalance);
        uint256 rawFee = _wmul(BASE_FEE, _wmul(volFactor, imbFactor));

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

        // Toxicity premium — applied only to vulnerable side (inventory-toxicity)
        uint256 toxPremium = _wmul(TOX_COEF, toxEma) + _wmul(TOX_QUAD_COEF, _wmul(toxEma, toxEma));
        bool richInY = trade.reserveY >= trade.reserveX;

        uint256 bidFeeOut;
        uint256 askFeeOut;
        if (richInY) {
            bidFeeOut = _clampFee(_wmul(baseFee + toxPremium, ONE_WAD + ASYMM));
            askFeeOut = baseFee;
        } else {
            askFeeOut = _clampFee(_wmul(baseFee + toxPremium, ONE_WAD + ASYMM));
            bidFeeOut = baseFee;
        }

        // V5 — Directionality: mimic price direction (Alexander & Fritz)
        uint256 dirPremium = _wmul(ret, DIR_BPS_PER_UNIT_RET);
        if (dirPremium > CAP_DIR_BPS) dirPremium = CAP_DIR_BPS;
        if (spot >= pHat) {
            askFeeOut = _clampFee(askFeeOut + dirPremium);
        } else {
            bidFeeOut = _clampFee(bidFeeOut + dirPremium);
        }

        // V5 — Surge on gate breach (one-shot)
        if (ret > adaptiveGate) {
            if (trade.isBuy) {
                bidFeeOut = _clampFee(bidFeeOut + SURGE_BPS);
            } else {
                askFeeOut = _clampFee(askFeeOut + SURGE_BPS);
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
        return "Sapient v5 - (directionality + inventory-tox + surge)";
    }
}
