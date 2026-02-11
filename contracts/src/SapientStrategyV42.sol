// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

/// @title Sapient Strategy V42 — V34 + toxic flow run
/// @notice Same as V34 (YQ baseline) plus: decayed state "toxRun" tracks recent toxic trades (buy above pHat / sell below); when high, add a fee boost to both sides.
/// @dev Unique angle 2.5 from docs/2025-02-10-V34-explanation-and-unique-angles.md. One new slot: slots[11] = toxRun.
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

    // --- Toxic flow run (angle 2.5) ---
    uint256 constant TOX_RUN_DECAY = 920000000000000000; // 0.92 per trade
    uint256 constant TOX_RUN_INCR = 5e17; // 0.5 WAD when toxic
    uint256 constant TOX_RUN_CAP = 3 * WAD;
    uint256 constant TOX_RUN_COEF = 5 * BPS; // fee boost per WAD of toxRun

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

    // slots[0] = bid fee
    // slots[1] = ask fee
    // slots[2] = last timestamp
    // slots[3] = dirState (centered at WAD, [0, 2*WAD])
    // slots[4] = actEma
    // slots[5] = pHat
    // slots[6] = sigmaHat
    // slots[7] = lambdaHat
    // slots[8] = sizeHat
    // slots[9] = toxEma
    // slots[10] = stepTradeCount (raw integer)
    // slots[11] = toxRun (decayed "recent toxic" accumulator)

    struct StateV42 {
        uint256 dirState;
        uint256 actEma;
        uint256 pHat;
        uint256 sigmaHat;
        uint256 lambdaHat;
        uint256 sizeHat;
        uint256 toxEma;
        uint256 stepTradeCount;
    }

    struct ComputeFeesParamsV42 {
        bool isBuy;
        uint256 amountY;
        uint256 reserveX;
        uint256 reserveY;
        uint256 dirState;
        uint256 pHat;
        uint256 fMid;
        uint256 toxSignal;
    }

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256, uint256) {
        slots[0] = BASE_FEE;
        slots[1] = BASE_FEE;
        slots[2] = 0;
        slots[3] = WAD; // neutral direction
        slots[4] = 0;
        slots[5] = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;
        slots[6] = 950000000000000; // 0.095% initial sigma guess
        slots[7] = 800000000000000000; // 0.8 initial arrival-rate guess
        slots[8] = 2000000000000000; // 0.2% reserve-size ratio guess
        slots[9] = 0;
        slots[10] = 0;
        slots[11] = 0; // toxRun
        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        StateV42 memory s = _readAndUpdateStateV42(trade);
        (uint256 fMid, uint256 toxSignal) = _baseFeesV42(s);
        ComputeFeesParamsV42 memory p;
        p.isBuy = trade.isBuy;
        p.amountY = trade.amountY;
        p.reserveX = trade.reserveX;
        p.reserveY = trade.reserveY;
        p.dirState = s.dirState;
        p.pHat = s.pHat;
        p.fMid = fMid;
        p.toxSignal = toxSignal;
        (uint256 bidFee, uint256 askFee) = _computeFeesV42Minimal(p);
        slots[0] = bidFee;
        slots[1] = askFee;
        slots[2] = trade.timestamp;
        slots[3] = s.dirState;
        slots[4] = s.actEma;
        slots[5] = s.pHat;
        slots[6] = s.sigmaHat;
        slots[7] = s.lambdaHat;
        slots[8] = s.sizeHat;
        slots[9] = s.toxEma;
        slots[10] = s.stepTradeCount;
        return (bidFee, askFee);
    }

    function _readAndUpdateStateV42(TradeInfo calldata trade) internal view returns (StateV42 memory s) {
        s.dirState = slots[3];
        s.actEma = slots[4];
        s.pHat = slots[5];
        s.sigmaHat = slots[6];
        s.lambdaHat = slots[7];
        s.sizeHat = slots[8];
        s.toxEma = slots[9];
        s.stepTradeCount = slots[10];
        _decayStepV42(trade.timestamp, slots[2], s);
        _updatePHatAndFlowV42(slots[0], slots[1], trade.isBuy, trade.amountY, trade.reserveX, trade.reserveY, s);
    }

    function _decayStepV42(uint256 timestamp, uint256 lastTs, StateV42 memory s) internal pure {
        if (timestamp <= lastTs) return;
        uint256 elapsedRaw = timestamp - lastTs;
        uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;
        s.dirState = _decayCentered(s.dirState, DIR_DECAY, elapsed);
        s.actEma = wmul(s.actEma, _powWad(ACT_DECAY, elapsed));
        s.sizeHat = wmul(s.sizeHat, _powWad(SIZE_DECAY, elapsed));
        s.toxEma = wmul(s.toxEma, _powWad(TOX_DECAY, elapsed));
        if (s.stepTradeCount > 0 && elapsedRaw > 0) {
            uint256 lambdaInst = (s.stepTradeCount * WAD) / elapsedRaw;
            if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
            s.lambdaHat = wmul(s.lambdaHat, LAMBDA_DECAY) + wmul(lambdaInst, WAD - LAMBDA_DECAY);
        }
        s.stepTradeCount = 0;
    }

    function _updatePHatAndFlowV42(uint256 prevBidFee, uint256 prevAskFee, bool isBuy, uint256 amountY, uint256 reserveX, uint256 reserveY, StateV42 memory s) internal pure {
        uint256 spot = reserveX > 0 ? wdiv(reserveY, reserveX) : s.pHat;
        if (s.pHat == 0) s.pHat = spot;
        uint256 feeUsed = isBuy ? prevBidFee : prevAskFee;
        uint256 gamma = feeUsed < WAD ? WAD - feeUsed : 0;
        uint256 pImplied = gamma == 0 ? spot : (isBuy ? wmul(spot, gamma) : wdiv(spot, gamma));
        uint256 ret = s.pHat > 0 ? wdiv(absDiff(pImplied, s.pHat), s.pHat) : 0;
        uint256 alpha = s.stepTradeCount == 0 ? PHAT_ALPHA : PHAT_ALPHA_RETAIL;
        uint256 adaptiveGate = wmul(s.sigmaHat, GATE_SIGMA_MULT);
        if (adaptiveGate < MIN_GATE) adaptiveGate = MIN_GATE;
        if (ret <= adaptiveGate) s.pHat = wmul(s.pHat, WAD - alpha) + wmul(pImplied, alpha);
        if (s.stepTradeCount == 0) {
            if (ret > RET_CAP) ret = RET_CAP;
            s.sigmaHat = wmul(s.sigmaHat, SIGMA_DECAY) + wmul(ret, WAD - SIGMA_DECAY);
        }
        uint256 tradeRatio = reserveY > 0 ? wdiv(amountY, reserveY) : 0;
        if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;
        if (tradeRatio > SIGNAL_THRESHOLD) {
            uint256 push = tradeRatio * DIR_IMPACT_MULT;
            if (push > WAD / 4) push = WAD / 4;
            if (isBuy) {
                s.dirState = s.dirState + push;
                if (s.dirState > 2 * WAD) s.dirState = 2 * WAD;
            } else {
                s.dirState = s.dirState > push ? s.dirState - push : 0;
            }
            s.actEma = wmul(s.actEma, ACT_BLEND_DECAY) + wmul(tradeRatio, WAD - ACT_BLEND_DECAY);
            s.sizeHat = wmul(s.sizeHat, SIZE_BLEND_DECAY) + wmul(tradeRatio, WAD - SIZE_BLEND_DECAY);
            if (s.sizeHat > WAD) s.sizeHat = WAD;
        }
        uint256 tox = s.pHat > 0 ? wdiv(absDiff(spot, s.pHat), s.pHat) : 0;
        if (tox > TOX_CAP) tox = TOX_CAP;
        s.toxEma = wmul(s.toxEma, TOX_BLEND_DECAY) + wmul(tox, WAD - TOX_BLEND_DECAY);
        s.stepTradeCount = s.stepTradeCount + 1;
        if (s.stepTradeCount > STEP_COUNT_CAP) s.stepTradeCount = STEP_COUNT_CAP;
    }

    function _baseFeesV42(StateV42 memory s) internal pure returns (uint256 fMid, uint256 toxSignal) {
        toxSignal = s.toxEma;
        uint256 flowSize = wmul(s.lambdaHat, s.sizeHat);
        fMid = BASE_FEE + wmul(SIGMA_COEF, s.sigmaHat) + wmul(LAMBDA_COEF, s.lambdaHat) + wmul(FLOW_SIZE_COEF, flowSize);
        fMid = fMid + wmul(TOX_COEF, toxSignal) + wmul(TOX_QUAD_COEF, wmul(toxSignal, toxSignal)) + wmul(ACT_COEF, s.actEma);
        fMid = fMid + wmul(SIGMA_TOX_COEF, wmul(s.sigmaHat, toxSignal));
        fMid = fMid + wmul(TOX_CUBIC_COEF, wmul(toxSignal, wmul(toxSignal, toxSignal)));
    }

    function _skewFeesV42(uint256 fMid, uint256 toxSignal, uint256 dirState) internal pure returns (uint256 bidFee, uint256 askFee, bool sellPressure) {
        uint256 dirDev = dirState >= WAD ? dirState - WAD : WAD - dirState;
        sellPressure = dirState >= WAD;
        uint256 skew = wmul(DIR_COEF, dirDev) + wmul(DIR_TOX_COEF, wmul(dirDev, toxSignal));
        if (sellPressure) {
            bidFee = fMid + skew;
            askFee = fMid > skew ? fMid - skew : 0;
        } else {
            askFee = fMid + skew;
            bidFee = fMid > skew ? fMid - skew : 0;
        }
    }

    function _applyStaleTradeToxicV42(uint256 bidFee, uint256 askFee, uint256 spot, uint256 tradeRatio, uint256 pHat, bool isBuy, uint256 toxSignal, bool sellPressure) internal returns (uint256, uint256) {
        uint256 staleShift = wmul(STALE_DIR_COEF, toxSignal);
        uint256 attractShift = wmul(staleShift, STALE_ATTRACT_FRAC);
        if (spot >= pHat) {
            bidFee = bidFee + staleShift;
            askFee = askFee > attractShift ? askFee - attractShift : 0;
        } else {
            askFee = askFee + staleShift;
            bidFee = bidFee > attractShift ? bidFee - attractShift : 0;
        }
        bool tradeAligned = (isBuy && spot >= pHat) || (!isBuy && spot < pHat);
        if (tradeAligned) {
            uint256 tradeBoost = wmul(TRADE_TOX_BOOST, tradeRatio);
            if (isBuy) bidFee = bidFee + tradeBoost;
            else askFee = askFee + tradeBoost;
        }
        return _applyToxicRunAndTail(bidFee, askFee, tradeAligned, sellPressure);
    }

    function _computeFeesV42Minimal(ComputeFeesParamsV42 memory p) internal returns (uint256 bidFee, uint256 askFee) {
        bool sellPressure;
        (bidFee, askFee, sellPressure) = _skewFeesV42(p.fMid, p.toxSignal, p.dirState);
        uint256 spot = p.reserveX > 0 ? wdiv(p.reserveY, p.reserveX) : p.pHat;
        uint256 tradeRatio = p.reserveY > 0 ? wdiv(p.amountY, p.reserveY) : 0;
        if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;
        (bidFee, askFee) = _applyStaleTradeToxicV42(bidFee, askFee, spot, tradeRatio, p.pHat, p.isBuy, p.toxSignal, sellPressure);
    }

    function _updatedToxRun(bool tradeAligned) internal view returns (uint256) {
        uint256 r = slots[11];
        r = tradeAligned ? wmul(r, TOX_RUN_DECAY) + TOX_RUN_INCR : wmul(r, TOX_RUN_DECAY);
        return r > TOX_RUN_CAP ? TOX_RUN_CAP : r;
    }

    function _applyToxicRunAndTail(uint256 bidFee, uint256 askFee, bool tradeAligned, bool sellPressure) internal returns (uint256, uint256) {
        uint256 toxRun = _updatedToxRun(tradeAligned);
        slots[11] = toxRun;
        bidFee = bidFee + wmul(TOX_RUN_COEF, toxRun);
        askFee = askFee + wmul(TOX_RUN_COEF, toxRun);
        if (sellPressure) {
            bidFee = clampFee(_compressTailWithSlope(bidFee, TAIL_SLOPE_PROTECT));
            askFee = clampFee(_compressTailWithSlope(askFee, TAIL_SLOPE_ATTRACT));
        } else {
            askFee = clampFee(_compressTailWithSlope(askFee, TAIL_SLOPE_PROTECT));
            bidFee = clampFee(_compressTailWithSlope(bidFee, TAIL_SLOPE_ATTRACT));
        }
        return (bidFee, askFee);
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
        return "Sapient v42 - toxic flow run";
    }
}
