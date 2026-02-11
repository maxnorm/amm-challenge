// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

/// @title Sapient Strategy V46 — V34 + bandit over 4 fee multipliers
/// @notice Same fee formula as V34; final bid/ask scaled by a chosen multiplier (0.85, 1.0, 1.15, 1.3). Arm chosen by epsilon-greedy on running average reward.
/// @dev P1 from docs/2025-02-10-next-formulas-innovative-research.md. Slots 11–18 bandit state, 19 = lastArm.
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
    uint256 constant DIR_IMPACT_MULT = 2;

    // --- Adaptive Shock Gate ---
    uint256 constant GATE_SIGMA_MULT = 10 * WAD;
    uint256 constant MIN_GATE = 30000000000000000; // 0.03 WAD

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

    // --- Bandit: 4 arms = fee multipliers (WAD) ---
    uint256 constant MULT_0 = 850000000000000000;  // 0.85
    uint256 constant MULT_1 = WAD;                 // 1.0
    uint256 constant MULT_2 = 1150000000000000000; // 1.15
    uint256 constant MULT_3 = 1300000000000000000;  // 1.3
    uint256 constant EPSILON_DENOM = 20;            // explore when seed % 20 == 0 (5%)
    uint256 constant COUNT_CAP = 1e9;               // cap count to avoid overflow

    // slots[0..10] = same as V34 (bid, ask, lastTs, dirState, actEma, pHat, sigmaHat, lambdaHat, sizeHat, toxEma, stepTradeCount)
    // slots[11..14] = sumReward[0..3]
    // slots[15..18] = count[0..3]
    // slots[19] = lastArm (0..3, or 4 = invalid for first trade)

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256, uint256) {
        slots[0] = BASE_FEE;
        slots[1] = BASE_FEE;
        slots[2] = 0;
        slots[3] = WAD;
        slots[4] = 0;
        slots[5] = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;
        slots[6] = 950000000000000;
        slots[7] = 800000000000000000;
        slots[8] = 2000000000000000;
        slots[9] = 0;
        slots[10] = 0;
        slots[11] = 0;
        slots[12] = 0;
        slots[13] = 0;
        slots[14] = 0;
        slots[15] = 0;
        slots[16] = 0;
        slots[17] = 0;
        slots[18] = 0;
        slots[19] = 4; // invalid arm
        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256 prevBidFee = slots[0];
        uint256 prevAskFee = slots[1];
        uint256 lastTs = slots[2];
        uint256 dirState = slots[3];
        uint256 actEma = slots[4];
        uint256 pHat = slots[5];
        uint256 sigmaHat = slots[6];
        uint256 lambdaHat = slots[7];
        uint256 sizeHat = slots[8];
        uint256 toxEma = slots[9];
        uint256 stepTradeCount = slots[10];
        uint256 lastArm = slots[19];

        // 1) Update bandit from previous trade
        if (lastArm < 4) {
            uint256 feeUsed = trade.isBuy ? prevBidFee : prevAskFee;
            uint256 reward = wmul(feeUsed, trade.amountY);
            slots[11 + lastArm] = slots[11 + lastArm] + reward;
            uint256 c = slots[15 + lastArm] + 1;
            if (c > COUNT_CAP) c = COUNT_CAP;
            slots[15 + lastArm] = c;
        }

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

        {
            uint256 feeUsed = trade.isBuy ? prevBidFee : prevAskFee;
            uint256 gamma = feeUsed < WAD ? WAD - feeUsed : 0;
            uint256 pImplied;
            if (gamma == 0) {
                pImplied = spot;
            } else {
                pImplied = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
            }

            uint256 ret = pHat > 0 ? wdiv(absDiff(pImplied, pHat), pHat) : 0;
            uint256 alpha = firstInStep ? PHAT_ALPHA : PHAT_ALPHA_RETAIL;
            uint256 adaptiveGate = wmul(sigmaHat, GATE_SIGMA_MULT);
            if (adaptiveGate < MIN_GATE) adaptiveGate = MIN_GATE;
            if (ret <= adaptiveGate) {
                pHat = wmul(pHat, WAD - alpha) + wmul(pImplied, alpha);
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

        // 2) Choose arm (epsilon-greedy)
        uint256 seed = trade.timestamp + stepTradeCount;
        uint256 arm = _chooseArm(seed);

        // 3) V34 fee pipeline -> raw bid/ask
        uint256 flowSize = wmul(lambdaHat, sizeHat);
        uint256 fBase = BASE_FEE + wmul(SIGMA_COEF, sigmaHat) + wmul(LAMBDA_COEF, lambdaHat) + wmul(FLOW_SIZE_COEF, flowSize);
        uint256 fMid = fBase + wmul(TOX_COEF, toxSignal) + wmul(TOX_QUAD_COEF, wmul(toxSignal, toxSignal)) + wmul(ACT_COEF, actEma);
        fMid = fMid + wmul(SIGMA_TOX_COEF, wmul(sigmaHat, toxSignal));
        {
            uint256 toxCubed = wmul(toxSignal, wmul(toxSignal, toxSignal));
            fMid = fMid + wmul(TOX_CUBIC_COEF, toxCubed);
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

        uint256 bidFeeRaw;
        uint256 askFeeRaw;
        if (sellPressure) {
            bidFeeRaw = fMid + skew;
            askFeeRaw = fMid > skew ? fMid - skew : 0;
        } else {
            askFeeRaw = fMid + skew;
            bidFeeRaw = fMid > skew ? fMid - skew : 0;
        }

        {
            uint256 staleShift = wmul(STALE_DIR_COEF, toxSignal);
            uint256 attractShift = wmul(staleShift, STALE_ATTRACT_FRAC);
            if (spot >= pHat) {
                bidFeeRaw = bidFeeRaw + staleShift;
                askFeeRaw = askFeeRaw > attractShift ? askFeeRaw - attractShift : 0;
            } else {
                askFeeRaw = askFeeRaw + staleShift;
                bidFeeRaw = bidFeeRaw > attractShift ? bidFeeRaw - attractShift : 0;
            }
        }

        {
            bool tradeAligned = (trade.isBuy && spot >= pHat) || (!trade.isBuy && spot < pHat);
            if (tradeAligned) {
                uint256 tradeBoost = wmul(TRADE_TOX_BOOST, tradeRatio);
                if (trade.isBuy) {
                    bidFeeRaw = bidFeeRaw + tradeBoost;
                } else {
                    askFeeRaw = askFeeRaw + tradeBoost;
                }
            }
        }

        if (sellPressure) {
            bidFeeRaw = _compressTailWithSlope(bidFeeRaw, TAIL_SLOPE_PROTECT);
            askFeeRaw = _compressTailWithSlope(askFeeRaw, TAIL_SLOPE_ATTRACT);
        } else {
            askFeeRaw = _compressTailWithSlope(askFeeRaw, TAIL_SLOPE_PROTECT);
            bidFeeRaw = _compressTailWithSlope(bidFeeRaw, TAIL_SLOPE_ATTRACT);
        }

        // 4) Apply multiplier and clamp
        uint256 mult = _multiplierForArm(arm);
        uint256 bidFee = clampFee(wmul(bidFeeRaw, mult));
        uint256 askFee = clampFee(wmul(askFeeRaw, mult));

        // 5) Persist state
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
        slots[19] = arm;

        return (bidFee, askFee);
    }

    function _multiplierForArm(uint256 arm) internal pure returns (uint256) {
        if (arm == 0) return MULT_0;
        if (arm == 1) return MULT_1;
        if (arm == 2) return MULT_2;
        return MULT_3;
    }

    /// @dev Epsilon-greedy: explore when seed % 20 == 0 (5%), else argmax of avg reward. Ties -> smallest index.
    function _chooseArm(uint256 seed) internal view returns (uint256) {
        if (seed % EPSILON_DENOM == 0) {
            return seed % 4;
        }
        uint256 s0 = slots[11];
        uint256 s1 = slots[12];
        uint256 s2 = slots[13];
        uint256 s3 = slots[14];
        uint256 c0 = slots[15];
        uint256 c1 = slots[16];
        uint256 c2 = slots[17];
        uint256 c3 = slots[18];

        uint256 bestArm = 0;
        uint256 bestSum = s0;
        uint256 bestCount = c0;
        if (c0 == 0) { bestSum = 0; bestCount = 1; }

        if (c1 > 0 && (s1 * bestCount > bestSum * c1)) { bestArm = 1; bestSum = s1; bestCount = c1; }
        if (c2 > 0 && (s2 * bestCount > bestSum * c2)) { bestArm = 2; bestSum = s2; bestCount = c2; }
        if (c3 > 0 && (s3 * bestCount > bestSum * c3)) { bestArm = 3; bestSum = s3; bestCount = c3; }
        return bestArm;
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
        return unicode"👀 - sapient v46";
    }
}
