// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

/// @title Sapient Strategy V10 — V8 + activity/flow in base (lambdaHat, sizeHat, stepTradeCount)
/// @notice V8 pipeline plus: lambdaHat (trades per step), sizeHat (smoothed trade size), flow terms in base fee (LAMBDA_COEF, FLOW_SIZE_COEF).
/// @dev See /docs/2025-02-09-Sapient-V10-changelog.md, /docs/2025-02-09-Sapient-audit-380-vs-526.md
contract Strategy is AMMStrategyBase {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 constant BASE_FEE = 35e14;           // 35 bps base
    uint256 constant K_IMB = 2e18;               // Imbalance multiplier
    uint256 constant K_VOL = 15e18;             // Volatility multiplier
    uint256 constant ALPHA = 25e16;              // 0.25 EWMA for volatility
    uint256 constant DECAY_FACTOR = 96e16;       // 0.96 decay toward floor
    uint256 constant MAX_FEE_CAP = 85e14;        // 85 bps cap
    uint256 constant FLOOR_IMB_SCALE = 500e14;  // Imbalance floor scale
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

    // Sigma×tox and cubic tox (vulnerable side)
    uint256 constant SIGMA_TOX_COEF = 50e14;     // 50 bps per sigma×tox
    uint256 constant TOX_CUBIC_COEF = 15e14;     // 15 bps per tox^3

    // Symmetric toxicity
    uint256 constant SYM_TOX_COEF = 12e14;      // 12 bps per unit tox
    uint256 constant SYM_TOX_QUAD = 30e14;       // 30 bps per tox^2
    uint256 constant SYM_HIGH_THRESH = 15e15;    // 1.5% — extra sym term above this
    uint256 constant SYM_HIGH_COEF = 25e14;     // 25 bps per unit above threshold

    // Directionality
    uint256 constant DIR_RET_THRESHOLD = 5e15;   // 0.5% in WAD
    uint256 constant DIR_BPS_PER_UNIT_RET = 250e14; // ~25 bps per 10% move
    uint256 constant CAP_DIR_BPS = 30e14;        // Cap 30 bps

    // Scaled surge
    uint256 constant SURGE_BASE = 15e14;         // 15 bps minimum
    uint256 constant SURGE_COEF = 2e18;          // 2 bps per 1% above gate (WAD)
    uint256 constant CAP_SURGE = 40e14;         // 40 bps max

    // Trade-size bump
    uint256 constant K_SIZE = 50e14;             // 50 bps per 100% ratio
    uint256 constant CAP_SIZE_BPS = 20e14;      // 20 bps max bump
    uint256 constant TRADE_RATIO_CAP = 20e16;   // 20% cap in WAD

    // Trade-aligned toxicity boost
    uint256 constant TRADE_TOX_BOOST = 25e14;   // 25 bps per unit trade ratio
    uint256 constant CAP_TRADE_BOOST = 25e14;   // 25 bps max

    // Stale + attract
    uint256 constant STALE_COEF = 68e14;         // 68 bps per unit toxEma
    uint256 constant ATTRACT_FRAC = 1124e15;     // 1.124 in WAD

    // dirState and time-consistent decay
    uint256 constant ELAPSED_CAP = 8;
    uint256 constant DIR_DECAY = 80e16;          // 0.80 decay toward WAD per elapsed step
    uint256 constant TOX_DECAY = 91e16;          // 0.91 for time-consistent toxEma decay
    uint256 constant SIGNAL_THRESHOLD = 2e15;    // 0.2% trade ratio to push dirState
    uint256 constant DIR_IMPACT_MULT = 2e18;     // push = tradeRatio * mult (capped)
    uint256 constant DIR_PUSH_CAP = 25e16;       // max push 25% of WAD
    uint256 constant DIR_COEF = 20e14;           // 20 bps per unit dirDev
    uint256 constant DIR_TOX_COEF = 10e14;      // 10 bps per dirDev*toxEma

    // V10 — Activity/flow in base
    uint256 constant LAMBDA_DECAY = 99e16;       // 0.99
    uint256 constant LAMBDA_COEF = 12e14;        // 12 bps per unit lambdaHat
    uint256 constant LAMBDA_CAP = 5e18;         // max 5 trades/step (WAD)
    uint256 constant SIZE_DECAY = 70e16;         // 0.70 per elapsed step
    uint256 constant SIZE_BLEND_DECAY = 818e15; // 0.818 blend for sizeHat
    uint256 constant STEP_COUNT_CAP = 64;
    uint256 constant FLOW_SIZE_COEF = 48e14;     // 48 bps per unit flowSize (scaled down from YQ)

    /*//////////////////////////////////////////////////////////////
                            STORAGE SLOT INDICES
    //////////////////////////////////////////////////////////////*/

    uint256 constant SLOT_PHAT = 0;
    uint256 constant SLOT_VOLATILITY = 1;
    uint256 constant SLOT_TIMESTAMP = 2;
    uint256 constant SLOT_SIGMA = 3;
    uint256 constant SLOT_TOX_EMA = 4;
    uint256 constant SLOT_PREV_BID = 5;
    uint256 constant SLOT_PREV_ASK = 6;
    uint256 constant SLOT_DIR_STATE = 7;
    uint256 constant SLOT_LAMBDA_HAT = 8;
    uint256 constant SLOT_SIZE_HAT = 9;

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
    uint256 constant SLOT_STEP_TRADE_COUNT = 16;

    /// @dev Computes raw fee (before cap); reads reserveX, reserveY, timestamp from temp slots
    function _computeRawFee(uint256 vol, uint256 toxEma, uint256 lastTs) private view returns (uint256 rawFee) {
        uint256 reserveX = slots[SLOT_TEMP_RESERVE_X];
        uint256 reserveY = slots[SLOT_TEMP_RESERVE_Y];
        uint256 timestamp = slots[SLOT_TEMP_TIMESTAMP];
        uint256 totalReserves = reserveX + reserveY;
        uint256 imbalance = totalReserves > 0 ? _wdiv(_abs(reserveX, reserveY), totalReserves) : 0;
        uint256 volFactor = ONE_WAD + _wmul(K_VOL, vol);
        uint256 imbFactor = ONE_WAD + _wmul(K_IMB, imbalance);
        rawFee = _wmul(BASE_FEE, _wmul(volFactor, imbFactor));
        rawFee = rawFee + _wmul(SYM_TOX_COEF, toxEma) + _wmul(SYM_TOX_QUAD, _wmul(toxEma, toxEma));
        if (toxEma >= SYM_HIGH_THRESH) {
            rawFee = rawFee + _wmul(SYM_HIGH_COEF, toxEma - SYM_HIGH_THRESH);
        }
        uint256 imbFloor = BASE_FEE + _wmul(imbalance, FLOOR_IMB_SCALE);
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

    /// @dev Applies trade-aligned toxicity boost and stale+attract spread
    function _applyTradeBoostAndStaleAttract(
        uint256 bidFeeOut,
        uint256 askFeeOut,
        uint256 spot,
        uint256 pHat,
        uint256 toxEma,
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
        uint256 staleShift = _wmul(STALE_COEF, toxEma);
        uint256 attractShift = _wmul(staleShift, ATTRACT_FRAC);
        if (spot >= pHat) {
            bidFeeOut = _clampFee(bidFeeOut + staleShift);
            askFeeOut = askFeeOut > attractShift ? askFeeOut - attractShift : 0;
        } else {
            askFeeOut = _clampFee(askFeeOut + staleShift);
            bidFeeOut = bidFeeOut > attractShift ? bidFeeOut - attractShift : 0;
        }
        return (bidFeeOut, askFeeOut);
    }

    /// @dev WAD exponentiation: factor^exp (exp integer, factor in WAD)
    function _powWad(uint256 factor, uint256 exp) private pure returns (uint256 result) {
        result = ONE_WAD;
        while (exp > 0) {
            if (exp & 1 == 1) result = _wmul(result, factor);
            factor = _wmul(factor, factor);
            exp >>= 1;
        }
    }

    /// @dev Decay centered value toward WAD by decayFactor^elapsed
    function _decayCentered(uint256 centered, uint256 decayFactor, uint256 elapsed) private pure returns (uint256) {
        uint256 mul = _powWad(decayFactor, elapsed);
        if (centered >= ONE_WAD) {
            return ONE_WAD + _wmul(centered - ONE_WAD, mul);
        }
        uint256 below = _wmul(ONE_WAD - centered, mul);
        return below < ONE_WAD ? ONE_WAD - below : 0;
    }

    /// @dev Applies dirState skew: protect side under pressure (higher fee), attract other (lower fee)
    function _applyDirStateSkew(uint256 bidFeeOut, uint256 askFeeOut, uint256 dirState, uint256 toxEma) private pure returns (uint256, uint256) {
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
        slots[SLOT_PREV_BID] = BASE_FEE;
        slots[SLOT_PREV_ASK] = BASE_FEE;
        slots[SLOT_DIR_STATE] = ONE_WAD;
        slots[SLOT_LAMBDA_HAT] = 8e17;   // 0.8 initial (like YQ)
        slots[SLOT_SIZE_HAT] = 2e15;     // 0.2% initial
        slots[SLOT_STEP_TRADE_COUNT] = 0;
        return (BASE_FEE, BASE_FEE);
    }

    /*//////////////////////////////////////////////////////////////
                          FEE CALCULATION FUNCTION
    //////////////////////////////////////////////////////////////*/

    /// @notice V10: V8 + lambdaHat, sizeHat, stepTradeCount; flow terms (LAMBDA_COEF, FLOW_SIZE_COEF) in base fee
    function afterSwap(TradeInfo calldata trade) external override returns (uint256 bidFee, uint256 askFee) {
        uint256 oldVol = slots[SLOT_VOLATILITY];
        uint256 lastTs = slots[SLOT_TIMESTAMP];
        uint256 sigmaHat = slots[SLOT_SIGMA];
        uint256 toxEma = slots[SLOT_TOX_EMA];
        uint256 dirState = slots[SLOT_DIR_STATE];
        uint256 prevBid = slots[SLOT_PREV_BID];
        uint256 prevAsk = slots[SLOT_PREV_ASK];
        uint256 lambdaHat = slots[SLOT_LAMBDA_HAT];
        uint256 sizeHat = slots[SLOT_SIZE_HAT];
        uint256 stepTradeCount = slots[SLOT_STEP_TRADE_COUNT];

        bool isNewStep = trade.timestamp > lastTs;
        if (isNewStep) {
            uint256 elapsedRaw = trade.timestamp - lastTs;
            uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;
            dirState = _decayCentered(dirState, DIR_DECAY, elapsed);
            toxEma = _wmul(toxEma, _powWad(TOX_DECAY, elapsed));
            // Activity/flow: update lambdaHat from previous step count, decay sizeHat
            if (stepTradeCount > 0 && elapsedRaw > 0) {
                uint256 lambdaInst = (stepTradeCount * ONE_WAD) / elapsedRaw;
                if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
                lambdaHat = _wmul(lambdaHat, LAMBDA_DECAY) + _wmul(lambdaInst, ONE_WAD - LAMBDA_DECAY);
            }
            sizeHat = _wmul(sizeHat, _powWad(SIZE_DECAY, elapsed));
            stepTradeCount = 0;
        }

        uint256 spot = trade.reserveX > 0 ? _wdiv(trade.reserveY, trade.reserveX) : slots[SLOT_PHAT];
        uint256 pHat = slots[SLOT_PHAT];
        if (pHat == 0) pHat = spot;

        uint256 feeUsed = trade.isBuy ? prevBid : prevAsk;
        uint256 gamma = feeUsed < ONE_WAD ? ONE_WAD - feeUsed : 0;
        uint256 pImplied = gamma == 0 ? spot : (trade.isBuy ? _wmul(spot, gamma) : _wdiv(spot, gamma));

        uint256 ret = pHat > 0 ? _wdiv(_abs(pImplied, pHat), pHat) : 0;
        if (ret > RET_CAP) ret = RET_CAP;
        uint256 adaptiveGate = _wmul(sigmaHat, GATE_SIGMA_MULT);
        if (adaptiveGate < MIN_GATE) adaptiveGate = MIN_GATE;
        if (ret <= adaptiveGate) {
            pHat = _wmul(ONE_WAD - PHAT_ALPHA, pHat) + _wmul(PHAT_ALPHA, pImplied);
        }
        sigmaHat = _wmul(SIGMA_DECAY, sigmaHat) + _wmul(ONE_WAD - SIGMA_DECAY, ret);

        slots[SLOT_TEMP_VOL] = _wmul(ALPHA, pHat > 0 ? _wdiv(_abs(spot, pHat), pHat) : 0) + _wmul(ONE_WAD - ALPHA, oldVol);

        uint256 tox = pHat > 0 ? _wdiv(_abs(spot, pHat), pHat) : 0;
        if (tox > TOX_CAP) tox = TOX_CAP;
        toxEma = _wmul(ONE_WAD - TOX_ALPHA, toxEma) + _wmul(TOX_ALPHA, tox);

        slots[SLOT_TEMP_RESERVE_X] = trade.reserveX;
        slots[SLOT_TEMP_RESERVE_Y] = trade.reserveY;
        slots[SLOT_TEMP_TIMESTAMP] = trade.timestamp;
        slots[SLOT_TEMP_IS_BUY] = trade.isBuy ? 1 : 0;
        slots[SLOT_TEMP_AMOUNT_Y] = trade.amountY;

        uint256 tradeRatioForDir = trade.reserveY > 0 ? _wdiv(trade.amountY, trade.reserveY) : 0;
        if (tradeRatioForDir > TRADE_RATIO_CAP) tradeRatioForDir = TRADE_RATIO_CAP;
        if (tradeRatioForDir > SIGNAL_THRESHOLD) {
            uint256 push = _wmul(tradeRatioForDir, DIR_IMPACT_MULT);
            if (push > DIR_PUSH_CAP) push = DIR_PUSH_CAP;
            if (trade.isBuy) {
                dirState = dirState + push;
                if (dirState > 2 * ONE_WAD) dirState = 2 * ONE_WAD;
            } else {
                dirState = dirState > push ? dirState - push : 0;
            }
            sizeHat = _wmul(sizeHat, SIZE_BLEND_DECAY) + _wmul(tradeRatioForDir, ONE_WAD - SIZE_BLEND_DECAY);
            if (sizeHat > ONE_WAD) sizeHat = ONE_WAD;
        }
        stepTradeCount = stepTradeCount + 1;
        if (stepTradeCount > STEP_COUNT_CAP) stepTradeCount = STEP_COUNT_CAP;

        uint256 rawFee = _computeRawFee(slots[SLOT_TEMP_VOL], toxEma, lastTs);
        uint256 flowSize = _wmul(lambdaHat, sizeHat);
        rawFee = rawFee + _wmul(LAMBDA_COEF, lambdaHat) + _wmul(FLOW_SIZE_COEF, flowSize);
        uint256 baseFee = rawFee > MAX_FEE_CAP ? MAX_FEE_CAP : rawFee;

        uint256 toxPremium = _wmul(TOX_COEF, toxEma) + _wmul(TOX_QUAD_COEF, _wmul(toxEma, toxEma));
        toxPremium = toxPremium + _wmul(SIGMA_TOX_COEF, _wmul(sigmaHat, toxEma));
        toxPremium = toxPremium + _wmul(TOX_CUBIC_COEF, _wmul(toxEma, _wmul(toxEma, toxEma)));

        uint256 bidFeeOut = slots[SLOT_TEMP_RESERVE_Y] >= slots[SLOT_TEMP_RESERVE_X]
            ? _clampFee(_wmul(baseFee + toxPremium, ONE_WAD + ASYMM)) : baseFee;
        uint256 askFeeOut = slots[SLOT_TEMP_RESERVE_Y] >= slots[SLOT_TEMP_RESERVE_X]
            ? baseFee : _clampFee(_wmul(baseFee + toxPremium, ONE_WAD + ASYMM));

        (bidFeeOut, askFeeOut) = _applyDirSurgeAndSize(ret, adaptiveGate, spot, pHat, bidFeeOut, askFeeOut);

        (bidFeeOut, askFeeOut) = _applyTradeBoostAndStaleAttract(
            bidFeeOut, askFeeOut, spot, pHat, toxEma, tradeRatioForDir, trade.isBuy
        );
        (bidFeeOut, askFeeOut) = _applyDirStateSkew(bidFeeOut, askFeeOut, dirState, toxEma);

        slots[SLOT_PHAT] = pHat;
        slots[SLOT_VOLATILITY] = slots[SLOT_TEMP_VOL];
        slots[SLOT_TIMESTAMP] = slots[SLOT_TEMP_TIMESTAMP];
        slots[SLOT_SIGMA] = sigmaHat;
        slots[SLOT_TOX_EMA] = toxEma;
        slots[SLOT_DIR_STATE] = dirState;
        slots[SLOT_PREV_BID] = bidFeeOut;
        slots[SLOT_PREV_ASK] = askFeeOut;
        slots[SLOT_LAMBDA_HAT] = lambdaHat;
        slots[SLOT_SIZE_HAT] = sizeHat;
        slots[SLOT_STEP_TRADE_COUNT] = stepTradeCount;

        return (bidFeeOut, askFeeOut);
    }

    /*//////////////////////////////////////////////////////////////
                            UTILITY FUNCTION
    //////////////////////////////////////////////////////////////*/

    function getName() external pure override returns (string memory) {
        return "Sapient v10 - (V8 + lambdaHat + sizeHat + flow in base)";
    }
}
