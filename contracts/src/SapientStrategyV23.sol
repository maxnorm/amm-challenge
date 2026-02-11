// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

/// @title Sapient Strategy V23 — V21 + tail compression only
/// @notice Isolate test: same as V21 (V20 baseline) but replace hard 75 bps cap with knee + slope compression, then clamp. No pImplied, flow, regimes, or dirState.
/// @dev Used to check if tail alone preserves edge (~380) or if other V22 additions cause the 128 regression.
contract Strategy is AMMStrategyBase {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS (V21)
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

    // V23 — Tail compression only (knee + slope, then clamp; like V15)
    uint256 constant TAIL_KNEE = 5e14;
    uint256 constant TAIL_SLOPE_PROTECT = 93e16;
    uint256 constant TAIL_SLOPE_ATTRACT = 955e15;

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

    function _compressTailWithSlope(uint256 fee, uint256 slope) private pure returns (uint256) {
        if (fee <= TAIL_KNEE) return fee;
        return TAIL_KNEE + _wmul(fee - TAIL_KNEE, slope);
    }

    /// @dev Applies tail compression using protect/attract from reserve imbalance; reads temp reserve slots
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

    uint256 constant SLOT_TEMP_RESERVE_X = 10;
    uint256 constant SLOT_TEMP_RESERVE_Y = 11;
    uint256 constant SLOT_TEMP_TIMESTAMP = 12;
    uint256 constant SLOT_TEMP_IS_BUY = 13;
    uint256 constant SLOT_TEMP_AMOUNT_Y = 14;
    uint256 constant SLOT_TEMP_VOL = 15;

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
        return (BASE_LOW, BASE_LOW);
    }

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

        uint256 toxPremium = _wmul(TOX_COEF, toxEma) + _wmul(TOX_QUAD_COEF, _wmul(toxEma, toxEma));
        uint256 bidFeeOut = slots[SLOT_TEMP_RESERVE_Y] >= slots[SLOT_TEMP_RESERVE_X]
            ? _clampFee(_wmul(baseFee + toxPremium, ONE_WAD + ASYMM)) : baseFee;
        uint256 askFeeOut = slots[SLOT_TEMP_RESERVE_Y] >= slots[SLOT_TEMP_RESERVE_X]
            ? baseFee : _clampFee(_wmul(baseFee + toxPremium, ONE_WAD + ASYMM));

        (bidFeeOut, askFeeOut) = _applyDirSurgeAndSize(ret, adaptiveGate, spot, pHat, bidFeeOut, askFeeOut);
        (bidFeeOut, askFeeOut) = _applyTradeBoostFromSlots(bidFeeOut, askFeeOut, spot, pHat);
        (bidFeeOut, askFeeOut) = _applyTailCompression(bidFeeOut, askFeeOut);

        slots[SLOT_PHAT] = pHat;
        slots[SLOT_VOLATILITY] = slots[SLOT_TEMP_VOL];
        slots[SLOT_TIMESTAMP] = slots[SLOT_TEMP_TIMESTAMP];
        slots[SLOT_SIGMA] = sigmaHat;
        slots[SLOT_TOX_EMA] = toxEma;

        return (bidFeeOut, askFeeOut);
    }

    function getName() external pure override returns (string memory) {
        return "Sapient v23 - (V21 + tail compression only)";
    }
}
