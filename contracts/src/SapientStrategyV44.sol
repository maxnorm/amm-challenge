// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

/// @title Sapient Strategy V44 — V43 + HydraSwap-style velocity discount
/// @notice Same as V43 (V34 + two-speed pHat) plus: subtract a fee term when activity (lambdaHat×sizeHat) is high, so fee goes down in high-turnover regimes (attract flow).
/// @dev HydraSwap: percentFee = volatility_drag / velocity; we adapt with velocity proxy = flowSize. Formula: fBase -= VELOCITY_DISCOUNT×min(flowSize, VELOCITY_CAP); fBase = max(BASE_FEE, fBase).
contract Strategy is AMMStrategyBase {
    // --- decay / update constants ---
    uint256 constant ELAPSED_CAP = 8;
    uint256 constant SIGNAL_THRESHOLD = WAD / 500; // ~20 bps of reserve
    uint256 constant DIR_DECAY = 800000000000000000; // 0.80
    uint256 constant ACT_DECAY = 700000000000000000; // 0.70
    uint256 constant SIZE_DECAY = 700000000000000000; // 0.70
    uint256 constant TOX_DECAY = 910000000000000000; // 0.91
    uint256 constant SIGMA_DECAY = 824000000000000000; // 0.824
    uint256 constant LAMBDA_DECAY = 990000000000000000; // 0.99
    uint256 constant SIZE_BLEND_DECAY = 818000000000000000; // 0.818
    uint256 constant TOX_BLEND_DECAY = 51000000000000000; // 0.051
    uint256 constant ACT_BLEND_DECAY = 985000000000000000; // 0.985
    uint256 constant PHAT_ALPHA = 260000000000000000; // 0.26
    uint256 constant PHAT_ALPHA_RETAIL = 50000000000000000; // 0.05
    uint256 constant PHAT_SLOW_ALPHA = 50000000000000000; // 0.05 — slow EMA of fair price
    uint256 constant DIR_IMPACT_MULT = 2;

    // --- Adaptive Shock Gate ---
    uint256 constant GATE_SIGMA_MULT = 10 * WAD;
    uint256 constant MIN_GATE = 30000000000000000; // 0.03 WAD

    // --- Two-speed pHat (angle 2.7): gap = |pHat - pHat_slow|/pHat_slow ---
    uint256 constant GAP_THRESH = 1e16; // 1% — add fee only when gap above this
    uint256 constant GAP_CAP = 1e17; // 10%
    uint256 constant GAP_COEF = 10 * BPS; // fee per WAD of gap

    // --- Cubic Toxicity ---
    uint256 constant TOX_CUBIC_COEF = 15000 * BPS;

    // --- Trade-Tox Boost ---
    uint256 constant TRADE_TOX_BOOST = 2500 * BPS;

    // --- Asymmetric Stale Dir ---
    uint256 constant STALE_ATTRACT_FRAC = 1124000000000000000; // 1.124

    // --- state caps ---
    uint256 constant RET_CAP = WAD / 10; // 10%
    uint256 constant TOX_CAP = WAD / 5; // 20%
    uint256 constant TRADE_RATIO_CAP = WAD / 5; // 20%
    uint256 constant LAMBDA_CAP = 5 * WAD; // max 5 trades/step estimate
    uint256 constant STEP_COUNT_CAP = 64; // guardrail

    // --- fee model constants ---
    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant SIGMA_COEF = 200000000000000000; // 0.20
    uint256 constant LAMBDA_COEF = 12 * BPS;
    uint256 constant FLOW_SIZE_COEF = 4842 * BPS;
    uint256 constant TOX_COEF = 250 * BPS;
    uint256 constant TOX_QUAD_COEF = 11700 * BPS;
    uint256 constant ACT_COEF = 91843 * BPS;
    uint256 constant DIR_COEF = 20 * BPS;
    uint256 constant DIR_TOX_COEF = 100 * BPS;
    uint256 constant STALE_DIR_COEF = 6850 * BPS;
    uint256 constant SIGMA_TOX_COEF = 500 * BPS;
    uint256 constant TAIL_KNEE = 500 * BPS;
    uint256 constant TAIL_SLOPE_PROTECT = 930000000000000000; // 0.93
    uint256 constant TAIL_SLOPE_ATTRACT = 955000000000000000; // 0.955

    // --- velocity discount (HydraSwap-style) ---
    uint256 constant VELOCITY_DISCOUNT = 500 * BPS; // 5 bps per WAD of capped flowSize
    uint256 constant VELOCITY_CAP = WAD / 2; // 0.5 WAD cap on flowSize for discount

    // slots[0] = bid fee
    // slots[1] = ask fee
    // slots[2] = last timestamp
    // slots[3] = dirState
    // slots[4] = actEma
    // slots[5] = pHat (fast)
    // slots[6] = sigmaHat
    // slots[7] = lambdaHat
    // slots[8] = sizeHat
    // slots[9] = toxEma
    // slots[10] = stepTradeCount
    // slots[11] = pHat_slow

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256, uint256) {
        uint256 p0 = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;
        slots[0] = BASE_FEE;
        slots[1] = BASE_FEE;
        slots[2] = 0;
        slots[3] = WAD;
        slots[4] = 0;
        slots[5] = p0;
        slots[6] = 950000000000000;
        slots[7] = 800000000000000000;
        slots[8] = 2000000000000000;
        slots[9] = 0;
        slots[10] = 0;
        slots[11] = p0; // pHat_slow = same as pHat initially
        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256 prevBidFee = slots[0];
        uint256 prevAskFee = slots[1];
        uint256 lastTs = slots[2];
        uint256 dirState = slots[3];
        uint256 actEma = slots[4];
        uint256 pHat = slots[5];
        uint256 lambdaHat = slots[7];
        uint256 sizeHat = slots[8];
        uint256 toxEma = slots[9];
        uint256 stepTradeCount = slots[10];

        bool isNewStep = trade.timestamp > lastTs;
        if (isNewStep) {
            uint256 elapsedRaw = trade.timestamp - lastTs;
            uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;

            dirState = _decayCentered(dirState, DIR_DECAY, elapsed);
            actEma = wmul(actEma, _powWad(ACT_DECAY, elapsed));
            sizeHat = wmul(sizeHat, _powWad(SIZE_DECAY, elapsed));
            toxEma = wmul(toxEma, _powWad(TOX_DECAY, elapsed));

            if (stepTradeCount > 0 && elapsedRaw > 0) {
                uint256 lambdaInst = (stepTradeCount * WAD) / elapsedRaw;
                if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
                lambdaHat = wmul(lambdaHat, LAMBDA_DECAY) + wmul(lambdaInst, WAD - LAMBDA_DECAY);
            }

            stepTradeCount = 0;
        }

        bool firstInStep = stepTradeCount == 0;

        uint256 spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : pHat;
        if (pHat == 0) pHat = spot;

        uint256 feeUsed = trade.isBuy ? prevBidFee : prevAskFee;
        uint256 gamma = feeUsed < WAD ? WAD - feeUsed : 0;
        uint256 pImplied;
        if (gamma == 0) {
            pImplied = spot;
        } else {
            pImplied = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
        }

        uint256 sigmaHat;
        {
            sigmaHat = slots[6];
            uint256 ret = pHat > 0 ? wdiv(absDiff(pImplied, pHat), pHat) : 0;
            uint256 alpha = firstInStep ? PHAT_ALPHA : PHAT_ALPHA_RETAIL;
            uint256 adaptiveGate = wmul(sigmaHat, GATE_SIGMA_MULT);
            if (adaptiveGate < MIN_GATE) adaptiveGate = MIN_GATE;
            if (ret <= adaptiveGate) {
                pHat = wmul(pHat, WAD - alpha) + wmul(pImplied, alpha);
                _updatePhatSlowV44(pImplied);
            }
            if (firstInStep) {
                if (ret > RET_CAP) ret = RET_CAP;
                sigmaHat = wmul(sigmaHat, SIGMA_DECAY) + wmul(ret, WAD - SIGMA_DECAY);
            }
        }

        uint256 tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
        if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;

        if (tradeRatio > SIGNAL_THRESHOLD) {
            uint256 push = tradeRatio * DIR_IMPACT_MULT;
            if (push > WAD / 4) push = WAD / 4;

            if (trade.isBuy) {
                dirState = dirState + push;
                if (dirState > 2 * WAD) dirState = 2 * WAD;
            } else {
                dirState = dirState > push ? dirState - push : 0;
            }

            actEma = wmul(actEma, ACT_BLEND_DECAY) + wmul(tradeRatio, WAD - ACT_BLEND_DECAY);

            sizeHat = wmul(sizeHat, SIZE_BLEND_DECAY) + wmul(tradeRatio, WAD - SIZE_BLEND_DECAY);
            if (sizeHat > WAD) sizeHat = WAD;
        }

        uint256 tox = pHat > 0 ? wdiv(absDiff(spot, pHat), pHat) : 0;
        if (tox > TOX_CAP) tox = TOX_CAP;
        toxEma = wmul(toxEma, TOX_BLEND_DECAY) + wmul(tox, WAD - TOX_BLEND_DECAY);
        uint256 toxSignal = toxEma;

        stepTradeCount = stepTradeCount + 1;
        if (stepTradeCount > STEP_COUNT_CAP) stepTradeCount = STEP_COUNT_CAP;

        uint256 fBase = _computeBaseFeeWithVelocityDiscount(sigmaHat, lambdaHat, sizeHat);
        uint256 fMid = fBase + wmul(TOX_COEF, toxSignal) + wmul(TOX_QUAD_COEF, wmul(toxSignal, toxSignal)) + wmul(ACT_COEF, actEma);

        fMid = fMid + wmul(SIGMA_TOX_COEF, wmul(sigmaHat, toxSignal));

        {
            uint256 toxCubed = wmul(toxSignal, wmul(toxSignal, toxSignal));
            fMid = fMid + wmul(TOX_CUBIC_COEF, toxCubed);
        }

        if (slots[11] > 0) {
            uint256 gap = wdiv(absDiff(pHat, slots[11]), slots[11]);
            if (gap > GAP_CAP) gap = GAP_CAP;
            if (gap > GAP_THRESH) fMid = fMid + wmul(GAP_COEF, gap);
        }

        uint256 dirDev;
        bool sellPressure;
        if (dirState >= WAD) {
            dirDev = dirState - WAD;
            sellPressure = true;
        } else {
            dirDev = WAD - dirState;
            sellPressure = false;
        }

        uint256 skew = wmul(DIR_COEF, dirDev) + wmul(DIR_TOX_COEF, wmul(dirDev, toxSignal));

        uint256 bidFee;
        uint256 askFee;
        if (sellPressure) {
            bidFee = fMid + skew;
            askFee = fMid > skew ? fMid - skew : 0;
        } else {
            askFee = fMid + skew;
            bidFee = fMid > skew ? fMid - skew : 0;
        }

        {
            uint256 staleShift = wmul(STALE_DIR_COEF, toxSignal);
            uint256 attractShift = wmul(staleShift, STALE_ATTRACT_FRAC);
            if (spot >= pHat) {
                bidFee = bidFee + staleShift;
                askFee = askFee > attractShift ? askFee - attractShift : 0;
            } else {
                askFee = askFee + staleShift;
                bidFee = bidFee > attractShift ? bidFee - attractShift : 0;
            }
        }

        {
            bool tradeAligned = (trade.isBuy && spot >= pHat) || (!trade.isBuy && spot < pHat);
            if (tradeAligned) {
                uint256 tradeBoost = wmul(TRADE_TOX_BOOST, tradeRatio);
                if (trade.isBuy) {
                    bidFee = bidFee + tradeBoost;
                } else {
                    askFee = askFee + tradeBoost;
                }
            }
        }

        if (sellPressure) {
            bidFee = clampFee(_compressTailWithSlope(bidFee, TAIL_SLOPE_PROTECT));
            askFee = clampFee(_compressTailWithSlope(askFee, TAIL_SLOPE_ATTRACT));
        } else {
            askFee = clampFee(_compressTailWithSlope(askFee, TAIL_SLOPE_PROTECT));
            bidFee = clampFee(_compressTailWithSlope(bidFee, TAIL_SLOPE_ATTRACT));
        }

        slots[0] = bidFee;
        slots[1] = askFee;
        slots[2] = trade.timestamp;
        slots[3] = dirState;
        slots[4] = actEma;
        slots[5] = pHat;
        slots[6] = sigmaHat;
        slots[7] = lambdaHat;
        slots[8] = sizeHat;
        slots[9] = toxEma;
        slots[10] = stepTradeCount;

        return (bidFee, askFee);
    }

    function _updatePhatSlowV44(uint256 pImplied) internal {
        slots[11] = wmul(slots[11], WAD - PHAT_SLOW_ALPHA) + wmul(pImplied, PHAT_SLOW_ALPHA);
    }

    function _computeBaseFeeWithVelocityDiscount(uint256 sigmaHat, uint256 lambdaHat, uint256 sizeHat) internal pure returns (uint256) {
        uint256 flowSize = wmul(lambdaHat, sizeHat);
        uint256 fBase = BASE_FEE + wmul(SIGMA_COEF, sigmaHat) + wmul(LAMBDA_COEF, lambdaHat) + wmul(FLOW_SIZE_COEF, flowSize);
        uint256 cappedFlow = flowSize > VELOCITY_CAP ? VELOCITY_CAP : flowSize;
        uint256 velocityDiscountTerm = wmul(VELOCITY_DISCOUNT, cappedFlow);
        if (fBase > velocityDiscountTerm) {
            fBase = fBase - velocityDiscountTerm;
        } else {
            fBase = BASE_FEE;
        }
        return fBase < BASE_FEE ? BASE_FEE : fBase;
    }

    function _compressTailWithSlope(uint256 fee, uint256 slope) internal pure returns (uint256) {
        if (fee <= TAIL_KNEE) return fee;
        return TAIL_KNEE + wmul(fee - TAIL_KNEE, slope);
    }

    function _powWad(uint256 factor, uint256 exp) internal pure returns (uint256 result) {
        result = WAD;
        while (exp > 0) {
            if (exp & 1 == 1) result = wmul(result, factor);
            factor = wmul(factor, factor);
            exp >>= 1;
        }
    }

    function _decayCentered(uint256 centered, uint256 decayFactor, uint256 elapsed) internal pure returns (uint256) {
        uint256 mul = _powWad(decayFactor, elapsed);
        if (centered >= WAD) {
            return WAD + wmul(centered - WAD, mul);
        }
        uint256 below = wmul(WAD - centered, mul);
        return below < WAD ? WAD - below : 0;
    }

    function getName() external pure override returns (string memory) {
        return "Sapient v44 - velocity discount";
    }
}
