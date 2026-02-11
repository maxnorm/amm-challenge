// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

/// @title Sapient Strategy V16 — V14 with cap at protocol max (10%)
/// @notice Same as V14 (low base + additive) but MAX_FEE_CAP = 10% (1e17), the maximum allowed by AMMStrategyBase.
/// @dev Base allows up to MAX_FEE = WAD/10 = 1e17. Test whether higher cap improves edge vs V14 (75 bps).
contract Strategy is AMMStrategyBase {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 constant BASE_LOW = 8e14;            // 8 bps base (additive build-up)
    uint256 constant SIGMA_COEF = 15e18;        // ~15 bps per 1% sigma (WAD)
    uint256 constant IMB_COEF = 100e14;          // bps per WAD imbalance
    uint256 constant VOL_COEF = 15e18;           // ~15 bps per 1% vol (WAD)
    uint256 constant ALPHA = 25e16;              // 0.25 EWMA for volatility
    uint256 constant DECAY_FACTOR = 96e16;       // 0.96 decay toward floor
    uint256 constant MAX_FEE_CAP = 1e17;        // 10% — protocol max (AMMStrategyBase.MAX_FEE = WAD/10)
    uint256 constant FLOOR_IMB_SCALE = 500e14;   // Imbalance floor scale
    uint256 constant ASYMM = 60e16;              // 60% extra on vulnerable side

    // Toxicity
    uint256 constant TOX_CAP = 20e16;
    uint256 constant TOX_ALPHA = 10e16;
    uint256 constant PHAT_ALPHA = 26e16;
    uint256 constant SIGMA_DECAY = 824e15;
    uint256 constant GATE_SIGMA_MULT = 10e18;
    uint256 constant MIN_GATE = 3e16;
    uint256 constant TOX_COEF = 25e14;           // 25 bps per unit tox (vulnerable side)
    uint256 constant TOX_QUAD_COEF = 60e14;      // 60 bps per tox^2 (vulnerable side)
    uint256 constant RET_CAP = 10e16;

    // Symmetric toxicity
    uint256 constant SYM_TOX_COEF = 12e14;       // 12 bps per unit tox
    uint256 constant SYM_TOX_QUAD = 30e14;       // 30 bps per tox^2
    uint256 constant SYM_HIGH_THRESH = 15e15;    // 1.5% — extra sym term above this
    uint256 constant SYM_HIGH_COEF = 25e14;      // 25 bps per unit above threshold

    // Directionality: only when ret <= gate (no overlap with surge)
    uint256 constant DIR_RET_THRESHOLD = 5e15;   // 0.5% in WAD
    uint256 constant DIR_BPS_PER_UNIT_RET = 250e14; // ~25 bps per 10% move
    uint256 constant CAP_DIR_BPS = 30e14;        // Cap 30 bps

    // V7 — Scaled surge (not fixed)
    uint256 constant SURGE_BASE = 15e14;         // 15 bps minimum
    uint256 constant SURGE_COEF = 2e18;          // 2 bps per 1% above gate (WAD)
    uint256 constant CAP_SURGE = 40e14;          // 40 bps max

    // V7 — Trade-size bump
    uint256 constant K_SIZE = 50e14;             // 50 bps per 100% ratio
    uint256 constant CAP_SIZE_BPS = 20e14;       // 20 bps max bump
    uint256 constant TRADE_RATIO_CAP = 20e16;   // 20% cap in WAD

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

    uint256 constant SLOT_TEMP_RESERVE_X = 10;
    uint256 constant SLOT_TEMP_RESERVE_Y = 11;
    uint256 constant SLOT_TEMP_TIMESTAMP = 12;
    uint256 constant SLOT_TEMP_IS_BUY = 13;
    uint256 constant SLOT_TEMP_AMOUNT_Y = 14;
    uint256 constant SLOT_TEMP_VOL = 15;

    /// @dev Computes raw fee (additive base): BASE_LOW + sigma + imb + vol + symTox; floor and decay from temp slots
    function _computeRawFeeAdditive(uint256 vol, uint256 sigmaHat, uint256 toxEma, uint256 lastTs) private view returns (uint256 rawFee) {
        uint256 reserveX = slots[SLOT_TEMP_RESERVE_X];
        uint256 reserveY = slots[SLOT_TEMP_RESERVE_Y];
        uint256 timestamp = slots[SLOT_TEMP_TIMESTAMP];
        uint256 totalReserves = reserveX + reserveY;
        uint256 imbalance = totalReserves > 0 ? _wdiv(_abs(reserveX, reserveY), totalReserves) : 0;

        rawFee = BASE_LOW;
        rawFee = rawFee + _wmul(SIGMA_COEF, sigmaHat);
        rawFee = rawFee + _wmul(IMB_COEF, imbalance);
        rawFee = rawFee + _wmul(VOL_COEF, vol);
        rawFee = rawFee + _wmul(SYM_TOX_COEF, toxEma) + _wmul(SYM_TOX_QUAD, _wmul(toxEma, toxEma));
        if (toxEma >= SYM_HIGH_THRESH) {
            rawFee = rawFee + _wmul(SYM_HIGH_COEF, toxEma - SYM_HIGH_THRESH);
        }
        uint256 imbFloor = BASE_LOW + _wmul(imbalance, FLOOR_IMB_SCALE);
        if (rawFee < imbFloor) rawFee = imbFloor;
        if (timestamp > lastTs && lastTs > 0 && rawFee > imbFloor) {
            uint256 steps = timestamp - lastTs;
            uint256 decay = _wmul(steps, ONE_WAD - DECAY_FACTOR);
            if (decay > ONE_WAD) decay = ONE_WAD;
            uint256 excess = rawFee - imbFloor;
            rawFee = imbFloor + _wmul(ONE_WAD - decay, excess);
        }
    }

    /// @dev Applies directionality, scaled surge, and trade-size bump; reads isBuy, reserveY, amountY from temp slots
    function _applyDirSurgeAndSize(
        uint256 ret,
        uint256 adaptiveGate,
        uint256 spot,
        uint256 pHat,
        uint256 bidFeeOut,
        uint256 askFeeOut
    ) private view returns (uint256, uint256) {
        bool isBuy = slots[SLOT_TEMP_IS_BUY] != 0;
        uint256 reserveY = slots[SLOT_TEMP_RESERVE_Y];
        uint256 amountY = slots[SLOT_TEMP_AMOUNT_Y];
        if (ret <= adaptiveGate && ret >= DIR_RET_THRESHOLD) {
            uint256 dirPremium = _wmul(ret, DIR_BPS_PER_UNIT_RET);
            if (dirPremium > CAP_DIR_BPS) dirPremium = CAP_DIR_BPS;
            if (spot >= pHat) {
                askFeeOut = _clampFee(askFeeOut + dirPremium);
            } else {
                bidFeeOut = _clampFee(bidFeeOut + dirPremium);
            }
        }
        if (ret > adaptiveGate) {
            uint256 excessRet = ret - adaptiveGate;
            uint256 surge = SURGE_BASE + _wmul(SURGE_COEF, excessRet);
            if (surge > CAP_SURGE) surge = CAP_SURGE;
            if (isBuy) {
                bidFeeOut = _clampFee(bidFeeOut + surge);
            } else {
                askFeeOut = _clampFee(askFeeOut + surge);
            }
        }
        uint256 tradeRatio = reserveY > 0 ? _wdiv(amountY, reserveY) : 0;
        if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;
        uint256 sizeBps = _wmul(K_SIZE, tradeRatio);
        if (sizeBps > CAP_SIZE_BPS) sizeBps = CAP_SIZE_BPS;
        if (isBuy) {
            bidFeeOut = _clampFee(bidFeeOut + sizeBps);
        } else {
            askFeeOut = _clampFee(askFeeOut + sizeBps);
        }
        return (bidFeeOut, askFeeOut);
    }

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
        return (BASE_LOW, BASE_LOW);
    }

    /*//////////////////////////////////////////////////////////////
                          FEE CALCULATION FUNCTION
    //////////////////////////////////////////////////////////////*/

    /// @notice V16: V14 with MAX_FEE_CAP = 10% (protocol max)
    function afterSwap(TradeInfo calldata trade) external override returns (uint256 bidFee, uint256 askFee) {
        uint256 oldVol = slots[SLOT_VOLATILITY];
        uint256 lastTs = slots[SLOT_TIMESTAMP];
        uint256 sigmaHat = slots[SLOT_SIGMA];
        uint256 toxEma = slots[SLOT_TOX_EMA];

        uint256 spot;
        uint256 pHat;
        uint256 ret;
        uint256 adaptiveGate;
        {
            uint256 oldPHat = slots[SLOT_PHAT];
            spot = trade.reserveX > 0 ? _wdiv(trade.reserveY, trade.reserveX) : oldPHat;
            pHat = oldPHat;
            if (pHat == 0) pHat = spot;
            ret = pHat > 0 ? _wdiv(_abs(spot, pHat), pHat) : 0;
            if (ret > RET_CAP) ret = RET_CAP;
            adaptiveGate = _wmul(sigmaHat, GATE_SIGMA_MULT);
            if (adaptiveGate < MIN_GATE) adaptiveGate = MIN_GATE;
            if (ret <= adaptiveGate) {
                pHat = _wmul(ONE_WAD - PHAT_ALPHA, pHat) + _wmul(PHAT_ALPHA, spot);
            }
            sigmaHat = _wmul(SIGMA_DECAY, sigmaHat) + _wmul(ONE_WAD - SIGMA_DECAY, ret);
        }

        slots[SLOT_TEMP_VOL] = _wmul(ALPHA, slots[SLOT_PHAT] > 0 ? _wdiv(_abs(spot, slots[SLOT_PHAT]), slots[SLOT_PHAT]) : 0) + _wmul(ONE_WAD - ALPHA, oldVol);

        uint256 tox = ret > TOX_CAP ? TOX_CAP : ret;
        toxEma = _wmul(ONE_WAD - TOX_ALPHA, toxEma) + _wmul(TOX_ALPHA, tox);

        slots[SLOT_TEMP_RESERVE_X] = trade.reserveX;
        slots[SLOT_TEMP_RESERVE_Y] = trade.reserveY;
        slots[SLOT_TEMP_TIMESTAMP] = trade.timestamp;
        slots[SLOT_TEMP_IS_BUY] = trade.isBuy ? 1 : 0;
        slots[SLOT_TEMP_AMOUNT_Y] = trade.amountY;
        uint256 rawFee = _computeRawFeeAdditive(slots[SLOT_TEMP_VOL], sigmaHat, toxEma, lastTs);
        uint256 baseFee = rawFee > MAX_FEE_CAP ? MAX_FEE_CAP : rawFee;

        // Toxicity premium on vulnerable side only
        uint256 toxPremium = _wmul(TOX_COEF, toxEma) + _wmul(TOX_QUAD_COEF, _wmul(toxEma, toxEma));
        uint256 bidFeeOut = slots[SLOT_TEMP_RESERVE_Y] >= slots[SLOT_TEMP_RESERVE_X]
            ? _clampFee(_wmul(baseFee + toxPremium, ONE_WAD + ASYMM)) : baseFee;
        uint256 askFeeOut = slots[SLOT_TEMP_RESERVE_Y] >= slots[SLOT_TEMP_RESERVE_X]
            ? baseFee : _clampFee(_wmul(baseFee + toxPremium, ONE_WAD + ASYMM));

        (bidFeeOut, askFeeOut) = _applyDirSurgeAndSize(ret, adaptiveGate, spot, pHat, bidFeeOut, askFeeOut);

        slots[SLOT_PHAT] = pHat;
        slots[SLOT_VOLATILITY] = slots[SLOT_TEMP_VOL];
        slots[SLOT_TIMESTAMP] = slots[SLOT_TEMP_TIMESTAMP];
        slots[SLOT_SIGMA] = sigmaHat;
        slots[SLOT_TOX_EMA] = toxEma;

        return (bidFeeOut, askFeeOut);
    }

    /*//////////////////////////////////////////////////////////////
                            UTILITY FUNCTION
    //////////////////////////////////////////////////////////////*/

    function getName() external pure override returns (string memory) {
        return "Sapient v16 - (V14 cap 10%)";
    }
}
