// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

/// @title Sapient Strategy V22 — Full upgrade: tail compression, two regimes, activity/flow, pImplied, dirState, stale/attract
/// @notice One contract with all report-recommended concepts. No first-in-step.
/// @dev See /docs/2025-02-10-Sapient-V22-full-upgrade-changelog.md
contract Strategy is AMMStrategyBase {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS (V21 base)
    //////////////////////////////////////////////////////////////*/

    uint256 constant BASE_LOW = 8e14;
    uint256 constant SIGMA_COEF = 15e18;
    uint256 constant IMB_COEF = 100e14;
    uint256 constant VOL_COEF = 15e18;
    uint256 constant ALPHA = 25e16;
    uint256 constant DECAY_FACTOR = 96e16;
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
    uint256 constant DIR_BPS_PER_UNIT_RET = 350e14;  // Top3: stronger price-deviation asymmetry (~35 bps per 10% ret)
    uint256 constant CAP_DIR_BPS = 40e14;            // 40 bps cap

    uint256 constant SURGE_BASE = 15e14;
    uint256 constant SURGE_COEF = 2e18;
    uint256 constant CAP_SURGE = 40e14;

    uint256 constant K_SIZE = 50e14;
    uint256 constant CAP_SIZE_BPS = 20e14;
    uint256 constant TRADE_RATIO_CAP = 20e16;

    uint256 constant TRADE_TOX_BOOST = 25e14;
    uint256 constant CAP_TRADE_BOOST = 25e14;

    /*//////////////////////////////////////////////////////////////
                    CONSTANTS (V22: tail, regimes, flow, dirState, stale)
    //////////////////////////////////////////////////////////////*/

    uint256 constant MAX_FEE_CAP = 75e14;   // Top3: lower stress cap to favor retail

    uint256 constant TAIL_KNEE = 5e14;
    uint256 constant TAIL_SLOPE_PROTECT = 93e16;
    uint256 constant TAIL_SLOPE_ATTRACT = 955e15;

    // Hysteresis: enter calm when strict, exit when loose (stable post-retail per Top3)
    uint256 constant SIGMA_CALM_ENTER = 4e15;   // 0.4% — enter calm only when low
    uint256 constant TOX_CALM_ENTER = 4e15;
    uint256 constant SIGMA_CALM_EXIT = 7e15;    // 0.7% — leave calm only when higher
    uint256 constant TOX_CALM_EXIT = 7e15;
    uint256 constant FEE_CALM = 12e14;

    uint256 constant ELAPSED_CAP = 8;
    uint256 constant LAMBDA_CAP = 5e18;
    uint256 constant LAMBDA_DECAY = 99e16;
    uint256 constant LAMBDA_DECAY_CALM = 95e16; // faster decay in calm
    uint256 constant SIZE_DECAY = 70e16;
    uint256 constant SIZE_DECAY_CALM = 50e16;   // faster decay in calm
    uint256 constant SIZE_BLEND_DECAY = 818e15;
    uint256 constant LAMBDA_COEF = 5e14;        // trimmed flow impact (was 8 bps)
    uint256 constant FLOW_SIZE_COEF = 10e14;    // trimmed flow impact (was 20 bps)
    uint256 constant SIGNAL_THRESHOLD = 2e15;
    uint256 constant STEP_COUNT_CAP = 64;

    uint256 constant DIR_DECAY = 80e16;
    uint256 constant DIR_IMPACT_MULT = 2e18;
    uint256 constant DIR_PUSH_CAP = 25e16;
    uint256 constant DIR_COEF = 15e14;   // Top3: slightly lower flow-based skew so ret-based leads
    uint256 constant DIR_TOX_COEF = 6e14;

    uint256 constant TOX_DECAY = 91e16;
    uint256 constant TOX_DECAY_CALM = 80e16;    // faster toxicity decay in calm
    uint256 constant STALE_DIR_COEF = 50e14;
    uint256 constant STALE_ATTRACT_FRAC = 1124e15;

    /*//////////////////////////////////////////////////////////////
                            SLOT LAYOUT (V22)
    //////////////////////////////////////////////////////////////*/

    uint256 constant SLOT_PREV_BID = 0;
    uint256 constant SLOT_PREV_ASK = 1;
    uint256 constant SLOT_TIMESTAMP = 2;
    uint256 constant SLOT_DIR_STATE = 3;
    uint256 constant SLOT_PHAT = 4;
    uint256 constant SLOT_VOLATILITY = 5;
    uint256 constant SLOT_SIGMA = 6;
    uint256 constant SLOT_TOX_EMA = 7;
    uint256 constant SLOT_LAMBDA_HAT = 8;
    uint256 constant SLOT_SIZE_HAT = 9;
    uint256 constant SLOT_STEP_TRADE_COUNT = 10;

    uint256 constant SLOT_TEMP_RESERVE_X = 11;
    uint256 constant SLOT_TEMP_RESERVE_Y = 12;
    uint256 constant SLOT_TEMP_TIMESTAMP = 13;
    uint256 constant SLOT_TEMP_IS_BUY = 14;
    uint256 constant SLOT_TEMP_AMOUNT_Y = 15;
    uint256 constant SLOT_TEMP_VOL = 16;
    uint256 constant SLOT_TEMP_RET = 17;
    uint256 constant SLOT_TEMP_GATE = 18;
    uint256 constant SLOT_TEMP_SPOT = 19;
    uint256 constant SLOT_TEMP_PIMPLIED = 20;

    uint256 constant ONE_WAD = 1e18;

    function _wmul(uint256 x, uint256 y) private pure returns (uint256) { return (x * y) / ONE_WAD; }
    function _wdiv(uint256 x, uint256 y) private pure returns (uint256) { return (x * ONE_WAD) / y; }
    function _abs(uint256 a, uint256 b) private pure returns (uint256) { return a > b ? a - b : b - a; }
    function _clampFee(uint256 fee) private pure returns (uint256) { return fee > MAX_FEE_CAP ? MAX_FEE_CAP : fee; }

    function _compressTailWithSlope(uint256 fee, uint256 slope) private pure returns (uint256) {
        if (fee <= TAIL_KNEE) return fee;
        return TAIL_KNEE + _wmul(fee - TAIL_KNEE, slope);
    }

    function _powWad(uint256 factor, uint256 exp) private pure returns (uint256 result) {
        result = ONE_WAD;
        while (exp > 0) {
            if (exp & 1 == 1) result = _wmul(result, factor);
            factor = _wmul(factor, factor);
            exp >>= 1;
        }
    }

    function _decayCentered(uint256 centered, uint256 decayFactor, uint256 elapsed) private pure returns (uint256) {
        uint256 mul = _powWad(decayFactor, elapsed);
        if (centered >= ONE_WAD) {
            return ONE_WAD + _wmul(centered - ONE_WAD, mul);
        }
        uint256 below = _wmul(ONE_WAD - centered, mul);
        return below < ONE_WAD ? ONE_WAD - below : 0;
    }

    /// @dev Raw base fee: BASE_LOW + sigma + imb + vol + symTox + flow terms; floor and decay from temp slots
    function _computeRawFeeAdditive(
        uint256 vol,
        uint256 sigmaHat,
        uint256 toxEma,
        uint256 lastTs,
        uint256 lambdaHat,
        uint256 sizeHat
    ) private view returns (uint256 rawFee) {
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
        uint256 flowSize = _wmul(lambdaHat, sizeHat);
        rawFee = rawFee + _wmul(LAMBDA_COEF, lambdaHat) + _wmul(FLOW_SIZE_COEF, flowSize);

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

    /// @dev dirState skew: protect side +skew, attract -skew
    function _applyDirStateSkew(
        uint256 bidFeeOut,
        uint256 askFeeOut,
        uint256 dirState,
        uint256 toxEma
    ) private pure returns (uint256, uint256) {
        uint256 dirDev = dirState >= ONE_WAD ? dirState - ONE_WAD : ONE_WAD - dirState;
        uint256 skew = _wmul(DIR_COEF, dirDev) + _wmul(DIR_TOX_COEF, _wmul(dirDev, toxEma));
        if (dirState >= ONE_WAD) {
            bidFeeOut = _clampFee(bidFeeOut + skew);
            askFeeOut = askFeeOut > skew ? askFeeOut - skew : 0;
        } else {
            askFeeOut = _clampFee(askFeeOut + skew);
            bidFeeOut = bidFeeOut > skew ? bidFeeOut - skew : 0;
        }
        return (bidFeeOut, askFeeOut);
    }

    /// @dev Stale (vulnerable side +shift) and attract (other side -shift)
    function _applyStaleAttract(
        uint256 bidFeeOut,
        uint256 askFeeOut,
        uint256 spot,
        uint256 pHat,
        uint256 toxEma
    ) private pure returns (uint256, uint256) {
        uint256 staleShift = _wmul(STALE_DIR_COEF, toxEma);
        uint256 attractShift = _wmul(staleShift, STALE_ATTRACT_FRAC);
        if (spot >= pHat) {
            bidFeeOut = _clampFee(bidFeeOut + staleShift);
            askFeeOut = askFeeOut > attractShift ? askFeeOut - attractShift : 0;
        } else {
            askFeeOut = _clampFee(askFeeOut + staleShift);
            bidFeeOut = bidFeeOut > attractShift ? bidFeeOut - attractShift : 0;
        }
        return (bidFeeOut, askFeeOut);
    }

    /// @dev Dir (ret<=gate), surge (ret>gate), size bump; reads from temp slots
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

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256 bidFee, uint256 askFee) {
        uint256 initialPrice = initialX > 0 ? _wdiv(initialY, initialX) : ONE_WAD;
        slots[SLOT_PREV_BID] = BASE_LOW;
        slots[SLOT_PREV_ASK] = BASE_LOW;
        slots[SLOT_TIMESTAMP] = 0;
        slots[SLOT_DIR_STATE] = ONE_WAD;
        slots[SLOT_PHAT] = initialPrice;
        slots[SLOT_VOLATILITY] = 0;
        slots[SLOT_SIGMA] = 95e13;
        slots[SLOT_TOX_EMA] = 0;
        slots[SLOT_LAMBDA_HAT] = 8e17;
        slots[SLOT_SIZE_HAT] = 2e15;
        slots[SLOT_STEP_TRADE_COUNT] = 0;
        return (BASE_LOW, BASE_LOW);
    }

    /// @dev New-step decay: dirState, sizeHat, toxEma, lambdaHat; reset stepTradeCount. Reads temp timestamp and slots 2,3,6,7,8,9,10.
    function _onNewStepDecay() private {
        uint256 lastTs = slots[SLOT_TIMESTAMP];
        uint256 ts = slots[SLOT_TEMP_TIMESTAMP];
        if (ts <= lastTs) return;
        uint256 elapsedRaw = ts - lastTs;
        uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;
        bool isCalmPrev = (slots[SLOT_PREV_BID] == FEE_CALM && slots[SLOT_PREV_ASK] == FEE_CALM);
        uint256 sizeDecay = isCalmPrev ? SIZE_DECAY_CALM : SIZE_DECAY;
        uint256 toxDecay = isCalmPrev ? TOX_DECAY_CALM : TOX_DECAY;
        uint256 lambdaDecay = isCalmPrev ? LAMBDA_DECAY_CALM : LAMBDA_DECAY;
        slots[SLOT_DIR_STATE] = _decayCentered(slots[SLOT_DIR_STATE], DIR_DECAY, elapsed);
        slots[SLOT_SIZE_HAT] = _wmul(slots[SLOT_SIZE_HAT], _powWad(sizeDecay, elapsed));
        slots[SLOT_TOX_EMA] = _wmul(slots[SLOT_TOX_EMA], _powWad(toxDecay, elapsed));
        uint256 stepTradeCount = slots[SLOT_STEP_TRADE_COUNT];
        uint256 lambdaHat = slots[SLOT_LAMBDA_HAT];
        if (stepTradeCount > 0 && elapsedRaw > 0) {
            uint256 lambdaInst = (stepTradeCount * ONE_WAD) / elapsedRaw;
            if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
            lambdaHat = _wmul(lambdaHat, lambdaDecay) + _wmul(lambdaInst, ONE_WAD - lambdaDecay);
        }
        slots[SLOT_LAMBDA_HAT] = lambdaHat;
        slots[SLOT_STEP_TRADE_COUNT] = 0;
    }

    /// @dev pImplied, ret, pHat/sigma/vol/tox, dirState/sizeHat/stepCount. Reads trade from temp 11-15; writes state and temp 16-20.
    function _onTradeUpdateSignals() private {
        uint256 reserveX = slots[SLOT_TEMP_RESERVE_X];
        uint256 reserveY = slots[SLOT_TEMP_RESERVE_Y];
        uint256 pHat = slots[SLOT_PHAT];
        uint256 spot = reserveX > 0 ? _wdiv(reserveY, reserveX) : pHat;
        if (pHat == 0) pHat = spot;
        slots[SLOT_TEMP_SPOT] = spot;
        bool isBuy = slots[SLOT_TEMP_IS_BUY] != 0;
        uint256 feeUsed = isBuy ? slots[SLOT_PREV_BID] : slots[SLOT_PREV_ASK];
        uint256 gamma = feeUsed < ONE_WAD ? ONE_WAD - feeUsed : 0;
        uint256 pImplied = gamma == 0 ? spot : (isBuy ? _wmul(spot, gamma) : _wdiv(spot, gamma));
        slots[SLOT_TEMP_PIMPLIED] = pImplied;
        uint256 ret = pHat > 0 ? _wdiv(_abs(pImplied, pHat), pHat) : 0;
        if (ret > RET_CAP) ret = RET_CAP;
        uint256 sigmaHat = slots[SLOT_SIGMA];
        uint256 gate = _wmul(sigmaHat, GATE_SIGMA_MULT);
        if (gate < MIN_GATE) gate = MIN_GATE;
        if (ret <= gate) {
            pHat = _wmul(ONE_WAD - PHAT_ALPHA, pHat) + _wmul(PHAT_ALPHA, pImplied);
        }
        sigmaHat = _wmul(SIGMA_DECAY, sigmaHat) + _wmul(ONE_WAD - SIGMA_DECAY, ret);
        slots[SLOT_PHAT] = pHat;
        slots[SLOT_SIGMA] = sigmaHat;
        slots[SLOT_TEMP_RET] = ret;
        slots[SLOT_TEMP_GATE] = gate;
        uint256 vol = _wmul(ALPHA, pHat > 0 ? _wdiv(_abs(spot, pHat), pHat) : 0)
            + _wmul(ONE_WAD - ALPHA, slots[SLOT_VOLATILITY]);
        // Use spot vs pHat for toxicity (avoid amplifying pImplied-based ret)
        uint256 toxSpot = pHat > 0 ? _wdiv(_abs(spot, pHat), pHat) : 0;
        if (toxSpot > TOX_CAP) toxSpot = TOX_CAP;
        slots[SLOT_VOLATILITY] = vol;
        slots[SLOT_TOX_EMA] = _wmul(ONE_WAD - TOX_ALPHA, slots[SLOT_TOX_EMA]) + _wmul(TOX_ALPHA, toxSpot);
        slots[SLOT_TEMP_VOL] = vol;
        uint256 tradeRatio = reserveY > 0 ? _wdiv(slots[SLOT_TEMP_AMOUNT_Y], reserveY) : 0;
        if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;
        uint256 dirState = slots[SLOT_DIR_STATE];
        uint256 sizeHat = slots[SLOT_SIZE_HAT];
        if (tradeRatio > SIGNAL_THRESHOLD) {
            uint256 push = _wmul(tradeRatio, DIR_IMPACT_MULT);
            if (push > DIR_PUSH_CAP) push = DIR_PUSH_CAP;
            if (isBuy) {
                dirState = dirState + push;
                if (dirState > 2 * ONE_WAD) dirState = 2 * ONE_WAD;
            } else {
                dirState = dirState > push ? dirState - push : 0;
            }
            sizeHat = _wmul(sizeHat, SIZE_BLEND_DECAY) + _wmul(tradeRatio, ONE_WAD - SIZE_BLEND_DECAY);
            if (sizeHat > ONE_WAD) sizeHat = ONE_WAD;
        }
        uint256 stepTradeCount = slots[SLOT_STEP_TRADE_COUNT] + 1;
        if (stepTradeCount > STEP_COUNT_CAP) stepTradeCount = STEP_COUNT_CAP;
        slots[SLOT_DIR_STATE] = dirState;
        slots[SLOT_SIZE_HAT] = sizeHat;
        slots[SLOT_STEP_TRADE_COUNT] = stepTradeCount;
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256 bidFee, uint256 askFee) {
        slots[SLOT_TEMP_RESERVE_X] = trade.reserveX;
        slots[SLOT_TEMP_RESERVE_Y] = trade.reserveY;
        slots[SLOT_TEMP_TIMESTAMP] = trade.timestamp;
        slots[SLOT_TEMP_IS_BUY] = trade.isBuy ? 1 : 0;
        slots[SLOT_TEMP_AMOUNT_Y] = trade.amountY;
        _onNewStepDecay();
        _onTradeUpdateSignals();

        // Hysteresis: stay calm until sigma/tox exceed EXIT; only enter calm when below ENTER (Top3 stable post-retail)
        bool lastCalm = (slots[SLOT_PREV_BID] == FEE_CALM && slots[SLOT_PREV_ASK] == FEE_CALM);
        uint256 sigma = slots[SLOT_SIGMA];
        uint256 tox = slots[SLOT_TOX_EMA];
        bool isCalm = lastCalm
            ? (sigma <= SIGMA_CALM_EXIT && tox <= TOX_CALM_EXIT)
            : (sigma <= SIGMA_CALM_ENTER && tox <= TOX_CALM_ENTER);
        if (isCalm) {
            slots[SLOT_PREV_BID] = FEE_CALM;
            slots[SLOT_PREV_ASK] = FEE_CALM;
            slots[SLOT_TIMESTAMP] = trade.timestamp;
            return (FEE_CALM, FEE_CALM);
        }

        uint256 rawFee = _computeRawFeeAdditive(
            slots[SLOT_TEMP_VOL],
            slots[SLOT_SIGMA],
            slots[SLOT_TOX_EMA],
            slots[SLOT_TIMESTAMP],
            slots[SLOT_LAMBDA_HAT],
            slots[SLOT_SIZE_HAT]
        );
        uint256 baseFee = rawFee > MAX_FEE_CAP ? MAX_FEE_CAP : rawFee;
        uint256 toxEma = slots[SLOT_TOX_EMA];
        uint256 toxPremium = _wmul(TOX_COEF, toxEma) + _wmul(TOX_QUAD_COEF, _wmul(toxEma, toxEma));
        uint256 bidFeeOut = slots[SLOT_TEMP_RESERVE_Y] >= slots[SLOT_TEMP_RESERVE_X]
            ? _clampFee(_wmul(baseFee + toxPremium, ONE_WAD + ASYMM)) : baseFee;
        uint256 askFeeOut = slots[SLOT_TEMP_RESERVE_Y] >= slots[SLOT_TEMP_RESERVE_X]
            ? baseFee : _clampFee(_wmul(baseFee + toxPremium, ONE_WAD + ASYMM));

        uint256 dirState = slots[SLOT_DIR_STATE];
        (bidFeeOut, askFeeOut) = _applyDirStateSkew(bidFeeOut, askFeeOut, dirState, toxEma);
        (bidFeeOut, askFeeOut) = _applyDirSurgeAndSize(
            slots[SLOT_TEMP_RET],
            slots[SLOT_TEMP_GATE],
            slots[SLOT_TEMP_SPOT],
            slots[SLOT_PHAT],
            bidFeeOut,
            askFeeOut
        );
        uint256 tradeRatio = slots[SLOT_TEMP_RESERVE_Y] > 0
            ? _wdiv(slots[SLOT_TEMP_AMOUNT_Y], slots[SLOT_TEMP_RESERVE_Y]) : 0;
        if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;
        (bidFeeOut, askFeeOut) = _applyTradeAlignedBoost(
            bidFeeOut, askFeeOut, slots[SLOT_TEMP_SPOT], slots[SLOT_PHAT], tradeRatio, slots[SLOT_TEMP_IS_BUY] != 0
        );

        bool sellPressure = dirState >= ONE_WAD;
        if (sellPressure) {
            bidFeeOut = _clampFee(_compressTailWithSlope(bidFeeOut, TAIL_SLOPE_PROTECT));
            askFeeOut = _clampFee(_compressTailWithSlope(askFeeOut, TAIL_SLOPE_ATTRACT));
        } else {
            askFeeOut = _clampFee(_compressTailWithSlope(askFeeOut, TAIL_SLOPE_PROTECT));
            bidFeeOut = _clampFee(_compressTailWithSlope(bidFeeOut, TAIL_SLOPE_ATTRACT));
        }

        slots[SLOT_PREV_BID] = bidFeeOut;
        slots[SLOT_PREV_ASK] = askFeeOut;
        slots[SLOT_TIMESTAMP] = trade.timestamp;
        return (bidFeeOut, askFeeOut);
    }

    function getName() external pure override returns (string memory) {
        return "Sapient v22 - (tail + regimes + flow + pImplied + dirState)";
    }
}
