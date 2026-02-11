// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

/// @title Sapient Strategy V27 — V26 with activity terms zeroed (isolate test)
/// @notice Same as V26 but LAMBDA_COEF, FLOW_SIZE_COEF, ACT_COEF = 0. Activity state and step logic still run; they just don't add to the fee. Tests whether the 40 edge is from the activity *terms* or from the activity *logic* (step/blend/slots).
/// @dev If V27 ≈ V23 (380): activity terms caused the regression. If V27 ≈ 40: step/state logic affects something else.
contract Strategy is AMMStrategyBase {
    /*//////////////////////////////////////////////////////////////
                         CONSTANTS (V23 base)
    //////////////////////////////////////////////////////////////*/

    uint256 constant BASE_LOW = 3e14;
    uint256 constant SIGMA_COEF = 15e18;
    uint256 constant IMB_COEF = 100e14;
    uint256 constant VOL_COEF = 15e18;
    uint256 constant ALPHA = 25e16;
    uint256 constant DECAY_FACTOR = 96e16;
    uint256 constant MAX_FEE_CAP = 75e14;
    uint256 constant FLOOR_IMB_SCALE = 500e14;
    uint256 constant ASYMM = 60e16;

    uint256 constant TOX_CAP = 20e16;
    uint256 constant TOX_ALPHA = 10e16;
    uint256 constant PHAT_ALPHA = 26e16;
    uint256 constant SIGMA_DECAY = 824e15;
    uint256 constant GATE_SIGMA_MULT = 10e18;
    uint256 constant MIN_GATE = 3e16;
    uint256 constant TOX_COEF = 25e14;
    uint256 constant TOX_QUAD_COEF = 60e14;
    uint256 constant RET_CAP = 10e16;

    uint256 constant SYM_TOX_COEF = 12e14;
    uint256 constant SYM_TOX_QUAD = 30e14;
    uint256 constant SYM_HIGH_THRESH = 15e15;
    uint256 constant SYM_HIGH_COEF = 25e14;

    uint256 constant DIR_RET_THRESHOLD = 5e15;
    uint256 constant DIR_BPS_PER_UNIT_RET = 250e14;
    uint256 constant CAP_DIR_BPS = 30e14;

    uint256 constant SURGE_BASE = 15e14;
    uint256 constant SURGE_COEF = 2e18;
    uint256 constant CAP_SURGE = 40e14;

    uint256 constant K_SIZE = 50e14;
    uint256 constant CAP_SIZE_BPS = 20e14;
    uint256 constant TRADE_RATIO_CAP = 20e16;

    uint256 constant TRADE_TOX_BOOST = 25e14;
    uint256 constant CAP_TRADE_BOOST = 25e14;

    uint256 constant TAIL_KNEE = 5e14;
    uint256 constant TAIL_SLOPE_PROTECT = 93e16;
    uint256 constant TAIL_SLOPE_ATTRACT = 955e15;

    /*//////////////////////////////////////////////////////////////
                    ACTIVITY IN BASE (scaled for our pipeline)
    //////////////////////////////////////////////////////////////*/

    uint256 constant ELAPSED_CAP = 8;
    uint256 constant SIGNAL_THRESHOLD = 2e15; // WAD/500 ~= 0.2% of reserve
    uint256 constant ACT_DECAY = 7e17;        // 0.70
    uint256 constant SIZE_DECAY = 7e17;       // 0.70
    uint256 constant LAMBDA_DECAY = 99e16;    // 0.99
    uint256 constant LAMBDA_CAP = 5e18;       // max 5 trades/step
    uint256 constant STEP_COUNT_CAP = 64;
    uint256 constant LAMBDA_COEF = 0;         // zeroed: activity state runs but does not add to fee (isolate test)
    uint256 constant FLOW_SIZE_COEF = 0;
    uint256 constant ACT_COEF = 0;
    uint256 constant SIZE_BLEND_DECAY = 818e15; // 0.818
    uint256 constant ACT_BLEND_DECAY = 985e15;  // 0.985

    /*//////////////////////////////////////////////////////////////
                            STORAGE SLOT INDICES
    //////////////////////////////////////////////////////////////*/

    uint256 constant SLOT_PHAT = 0;
    uint256 constant SLOT_VOLATILITY = 1;
    uint256 constant SLOT_TIMESTAMP = 2;
    uint256 constant SLOT_SIGMA = 3;
    uint256 constant SLOT_TOX_EMA = 4;
    uint256 constant SLOT_LAMBDA_HAT = 5;
    uint256 constant SLOT_SIZE_HAT = 6;
    uint256 constant SLOT_ACT_EMA = 7;
    uint256 constant SLOT_STEP_TRADE_COUNT = 8;

    uint256 constant ONE_WAD = 1e18;

    uint256 constant SLOT_TEMP_RESERVE_X = 10;
    uint256 constant SLOT_TEMP_RESERVE_Y = 11;
    uint256 constant SLOT_TEMP_TIMESTAMP = 12;
    uint256 constant SLOT_TEMP_IS_BUY = 13;
    uint256 constant SLOT_TEMP_AMOUNT_Y = 14;
    uint256 constant SLOT_TEMP_VOL = 15;
    uint256 constant SLOT_TEMP_SPOT = 16;
    uint256 constant SLOT_TEMP_RET = 17;
    uint256 constant SLOT_TEMP_GATE = 18;

    function _wmul(uint256 x, uint256 y) private pure returns (uint256) { return (x * y) / ONE_WAD; }
    function _wdiv(uint256 x, uint256 y) private pure returns (uint256) { return (x * ONE_WAD) / y; }
    function _abs(uint256 a, uint256 b) private pure returns (uint256) { return a > b ? a - b : b - a; }
    function _clampFee(uint256 fee) private pure returns (uint256) { return fee > MAX_FEE_CAP ? MAX_FEE_CAP : fee; }

    /// @dev decay^exp in WAD (exp is elapsed steps, typically small)
    function _powWad(uint256 factor, uint256 exp) private pure returns (uint256 result) {
        result = ONE_WAD;
        while (exp > 0) {
            if (exp & 1 == 1) result = _wmul(result, factor);
            factor = _wmul(factor, factor);
            exp >>= 1;
        }
    }

    /// @dev On new step: decay actEma, sizeHat; update lambdaHat from stepTradeCount/elapsed; reset stepTradeCount. Reads/writes slots 2,5,6,7,8.
    function _applyStepDecayAndLambda(uint256 lastTs, uint256 timestamp) private {
        if (timestamp <= lastTs) return;
        uint256 elapsedRaw = timestamp - lastTs;
        uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;
        uint256 la = slots[SLOT_LAMBDA_HAT];
        uint256 sz = slots[SLOT_SIZE_HAT];
        uint256 ac = slots[SLOT_ACT_EMA];
        uint256 st = slots[SLOT_STEP_TRADE_COUNT];
        ac = _wmul(ac, _powWad(ACT_DECAY, elapsed));
        sz = _wmul(sz, _powWad(SIZE_DECAY, elapsed));
        if (st > 0 && elapsedRaw > 0) {
            uint256 lambdaInst = (st * ONE_WAD) / elapsedRaw;
            if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
            la = _wmul(la, LAMBDA_DECAY) + _wmul(lambdaInst, ONE_WAD - LAMBDA_DECAY);
        }
        slots[SLOT_LAMBDA_HAT] = la;
        slots[SLOT_SIZE_HAT] = sz;
        slots[SLOT_ACT_EMA] = ac;
        slots[SLOT_STEP_TRADE_COUNT] = 0;
    }

    /// @dev Blend actEma and sizeHat when tradeRatio > threshold. Reads/writes slots 6,7.
    function _blendActivityOnTrade(uint256 tradeRatio) private {
        if (tradeRatio <= SIGNAL_THRESHOLD) return;
        uint256 ac = slots[SLOT_ACT_EMA];
        uint256 sz = slots[SLOT_SIZE_HAT];
        ac = _wmul(ac, ACT_BLEND_DECAY) + _wmul(tradeRatio, ONE_WAD - ACT_BLEND_DECAY);
        sz = _wmul(sz, SIZE_BLEND_DECAY) + _wmul(tradeRatio, ONE_WAD - SIZE_BLEND_DECAY);
        if (sz > ONE_WAD) sz = ONE_WAD;
        slots[SLOT_ACT_EMA] = ac;
        slots[SLOT_SIZE_HAT] = sz;
    }

    /// @dev Compute spot, update pHat/sigma, store spot/ret/adaptiveGate in temp slots; returns new sigmaHat.
    function _computeSpotPhatRetGate(uint256 reserveX, uint256 reserveY, uint256 oldPHat, uint256 sigmaHat) private returns (uint256) {
        uint256 spot = reserveX > 0 ? _wdiv(reserveY, reserveX) : oldPHat;
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
        slots[SLOT_PHAT] = pHat;
        slots[SLOT_TEMP_SPOT] = spot;
        slots[SLOT_TEMP_RET] = ret;
        slots[SLOT_TEMP_GATE] = adaptiveGate;
        return sigmaHat;
    }

    function _compressTailWithSlope(uint256 fee, uint256 slope) private pure returns (uint256) {
        if (fee <= TAIL_KNEE) return fee;
        return TAIL_KNEE + _wmul(fee - TAIL_KNEE, slope);
    }

    function _applyTailCompression(uint256 bidFeeOut, uint256 askFeeOut) private view returns (uint256, uint256) {
        bool bidIsProtect = slots[SLOT_TEMP_RESERVE_Y] >= slots[SLOT_TEMP_RESERVE_X];
        if (bidIsProtect) {
            bidFeeOut = _clampFee(_compressTailWithSlope(bidFeeOut, TAIL_SLOPE_PROTECT));
            askFeeOut = _clampFee(_compressTailWithSlope(askFeeOut, TAIL_SLOPE_ATTRACT));
        } else {
            askFeeOut = _clampFee(_compressTailWithSlope(askFeeOut, TAIL_SLOPE_PROTECT));
            bidFeeOut = _clampFee(_compressTailWithSlope(bidFeeOut, TAIL_SLOPE_ATTRACT));
        }
        return (bidFeeOut, askFeeOut);
    }

    /// @dev Base fee = BASE_LOW + sigma + imb + vol + symTox + activity (lambda + flowSize + actEma). Activity read from slots 5–7.
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
        // Activity in base (scaled)
        uint256 lambdaHat = slots[SLOT_LAMBDA_HAT];
        uint256 sizeHat = slots[SLOT_SIZE_HAT];
        uint256 actEma = slots[SLOT_ACT_EMA];
        rawFee = rawFee + _wmul(LAMBDA_COEF, lambdaHat);
        rawFee = rawFee + _wmul(FLOW_SIZE_COEF, _wmul(lambdaHat, sizeHat));
        rawFee = rawFee + _wmul(ACT_COEF, actEma);

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

    function _applyTradeAlignedBoost(
        uint256 bidFeeOut,
        uint256 askFeeOut,
        uint256 spot,
        uint256 pHat,
        uint256 tradeRatio,
        bool isBuy
    ) private pure returns (uint256, uint256) {
        bool tradeAligned = (isBuy && spot >= pHat) || (!isBuy && spot < pHat);
        if (tradeAligned) {
            uint256 boost = _wmul(TRADE_TOX_BOOST, tradeRatio);
            if (boost > CAP_TRADE_BOOST) boost = CAP_TRADE_BOOST;
            if (isBuy) {
                bidFeeOut = _clampFee(bidFeeOut + boost);
            } else {
                askFeeOut = _clampFee(askFeeOut + boost);
            }
        }
        return (bidFeeOut, askFeeOut);
    }

    function _applyTradeBoostFromSlots(uint256 bidFeeOut, uint256 askFeeOut, uint256 spot, uint256 pHat) private view returns (uint256, uint256) {
        uint256 reserveY = slots[SLOT_TEMP_RESERVE_Y];
        uint256 amountY = slots[SLOT_TEMP_AMOUNT_Y];
        bool isBuy = slots[SLOT_TEMP_IS_BUY] != 0;
        uint256 tradeRatio = reserveY > 0 ? _wdiv(amountY, reserveY) : 0;
        if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;
        return _applyTradeAlignedBoost(bidFeeOut, askFeeOut, spot, pHat, tradeRatio, isBuy);
    }

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256 bidFee, uint256 askFee) {
        uint256 initialPrice = initialX > 0 ? _wdiv(initialY, initialX) : ONE_WAD;
        slots[SLOT_PHAT] = initialPrice;
        slots[SLOT_VOLATILITY] = 0;
        slots[SLOT_TIMESTAMP] = 0;
        slots[SLOT_SIGMA] = 95e13;
        slots[SLOT_TOX_EMA] = 0;
        slots[SLOT_LAMBDA_HAT] = 8e17;   // 0.8 initial (YQ)
        slots[SLOT_SIZE_HAT] = 2e15;    // 0.2% initial (YQ)
        slots[SLOT_ACT_EMA] = 0;
        slots[SLOT_STEP_TRADE_COUNT] = 0;
        return (BASE_LOW, BASE_LOW);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256 bidFee, uint256 askFee) {
        uint256 oldVol = slots[SLOT_VOLATILITY];
        uint256 lastTs = slots[SLOT_TIMESTAMP];
        uint256 sigmaHat = slots[SLOT_SIGMA];
        uint256 toxEma = slots[SLOT_TOX_EMA];

        _applyStepDecayAndLambda(lastTs, trade.timestamp);

        uint256 tradeRatio = trade.reserveY > 0 ? _wdiv(trade.amountY, trade.reserveY) : 0;
        if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;
        _blendActivityOnTrade(tradeRatio);

        uint256 stepTradeCount = slots[SLOT_STEP_TRADE_COUNT] + 1;
        if (stepTradeCount > STEP_COUNT_CAP) stepTradeCount = STEP_COUNT_CAP;
        slots[SLOT_STEP_TRADE_COUNT] = stepTradeCount;

        sigmaHat = _computeSpotPhatRetGate(trade.reserveX, trade.reserveY, slots[SLOT_PHAT], sigmaHat);

        uint256 spot = slots[SLOT_TEMP_SPOT];
        uint256 ret = slots[SLOT_TEMP_RET];
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
        uint256 toxPremium = _wmul(TOX_COEF, toxEma) + _wmul(TOX_QUAD_COEF, _wmul(toxEma, toxEma));
        uint256 bidFeeOut = slots[SLOT_TEMP_RESERVE_Y] >= slots[SLOT_TEMP_RESERVE_X]
            ? _clampFee(_wmul(baseFee + toxPremium, ONE_WAD + ASYMM)) : baseFee;
        uint256 askFeeOut = slots[SLOT_TEMP_RESERVE_Y] >= slots[SLOT_TEMP_RESERVE_X]
            ? baseFee : _clampFee(_wmul(baseFee + toxPremium, ONE_WAD + ASYMM));

        (bidFeeOut, askFeeOut) = _applyDirSurgeAndSize(ret, slots[SLOT_TEMP_GATE], spot, slots[SLOT_PHAT], bidFeeOut, askFeeOut);
        (bidFeeOut, askFeeOut) = _applyTradeBoostFromSlots(bidFeeOut, askFeeOut, spot, slots[SLOT_PHAT]);
        (bidFeeOut, askFeeOut) = _applyTailCompression(bidFeeOut, askFeeOut);

        slots[SLOT_VOLATILITY] = slots[SLOT_TEMP_VOL];
        slots[SLOT_TIMESTAMP] = slots[SLOT_TEMP_TIMESTAMP];
        slots[SLOT_SIGMA] = sigmaHat;
        slots[SLOT_TOX_EMA] = toxEma;

        return (bidFeeOut, askFeeOut);
    }

    function getName() external pure override returns (string memory) {
        return "Sapient v27 - (V26 activity terms zeroed)";
    }
}
