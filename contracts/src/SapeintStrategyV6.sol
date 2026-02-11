// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

/// @title VIAF Strategy V6 — Break same-edge: symmetric tox floor + stronger directionality + larger surge
/// @notice Addresses V5 = V4 edge: small symmetric tox so non-vulnerable side isn't too cheap;
///         directionality only when ret >= 0.5%, cap 30 bps; surge 25 bps on gate breach.
///         Fee cap 100 bps: without it the formula can output 2–5%+, which kills volume and collapses edge.
/// @dev See /docs/Sapient-v5-same-edge-diagnosis.md, /docs/Sapient-v6-edge-wall-deep-review.md
contract Strategy is AMMStrategyBase {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 constant BASE_FEE = 35e14;           // 30 bps base
    uint256 constant K_IMB = 2e18;               // Imbalance multiplier
    uint256 constant K_VOL = 15e18;              // Volatility multiplier
    uint256 constant ALPHA = 25e16;              // 0.25 EWMA for volatility
    uint256 constant DECAY_FACTOR = 96e16;       // 0.96 decay toward floor
    uint256 constant MAX_FEE_CAP = 75e14;       // 100 bps — guardrail: higher fees kill volume / select for toxic flow
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

    // V6 — Small symmetric toxicity (so non-vulnerable side isn't too cheap)
    uint256 constant SYM_TOX_COEF = 12e14;       // 12 bps per unit tox
    uint256 constant SYM_TOX_QUAD = 30e14;       // 30 bps per tox^2

    // V6 — Directionality: only when confident, stronger cap
    uint256 constant DIR_RET_THRESHOLD = 5e15;   // 0.5% in WAD
    uint256 constant DIR_BPS_PER_UNIT_RET = 250e14; // ~25 bps per 10% move
    uint256 constant CAP_DIR_BPS = 30e14;        // Cap 30 bps

    // V6 — Larger surge on gate breach
    uint256 constant SURGE_BPS = 25e14;          // 25 bps when ret > gate

    /*//////////////////////////////////////////////////////////////
                            STORAGE SLOT INDICES
    //////////////////////////////////////////////////////////////*/

    uint256 constant SLOT_PHAT = 0;
    uint256 constant SLOT_VOLATILITY = 1;
    uint256 constant SLOT_TIMESTAMP = 2;
    uint256 constant SLOT_SIGMA = 3;
    uint256 constant SLOT_TOX_EMA = 4;

    uint256 constant SLOT_TEMP_RESERVE_X = 10;
    uint256 constant SLOT_TEMP_RESERVE_Y = 11;
    uint256 constant SLOT_TEMP_TIMESTAMP = 12;
    uint256 constant SLOT_TEMP_IS_BUY = 13;
    uint256 constant SLOT_TEMP_VOL = 14;

    uint256 constant ONE_WAD = 1e18;

    function _wmul(uint256 x, uint256 y) private pure returns (uint256) { return (x * y) / ONE_WAD; }
    function _wdiv(uint256 x, uint256 y) private pure returns (uint256) { return (x * ONE_WAD) / y; }
    function _abs(uint256 a, uint256 b) private pure returns (uint256) { return a > b ? a - b : b - a; }
    function _clampFee(uint256 fee) private pure returns (uint256) { return fee > MAX_FEE_CAP ? MAX_FEE_CAP : fee; }

    /// @dev Computes raw fee from vol, toxEma, lastTs; reads reserves and timestamp from temp slots
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

    /// @dev Applies dir and surge; reads isBuy from temp slot
    function _applyDirAndSurge(uint256 ret, uint256 adaptiveGate, uint256 spot, uint256 pHat, uint256 bidFeeOut, uint256 askFeeOut) private view returns (uint256, uint256) {
        if (ret >= DIR_RET_THRESHOLD) {
            uint256 dirPremium = _wmul(ret, DIR_BPS_PER_UNIT_RET);
            if (dirPremium > CAP_DIR_BPS) dirPremium = CAP_DIR_BPS;
            if (spot >= pHat) {
                askFeeOut = _clampFee(askFeeOut + dirPremium);
            } else {
                bidFeeOut = _clampFee(bidFeeOut + dirPremium);
            }
        }
        if (ret > adaptiveGate) {
            if (slots[SLOT_TEMP_IS_BUY] != 0) {
                bidFeeOut = _clampFee(bidFeeOut + SURGE_BPS);
            } else {
                askFeeOut = _clampFee(askFeeOut + SURGE_BPS);
            }
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
        return (BASE_FEE, BASE_FEE);
    }

    /*//////////////////////////////////////////////////////////////
                          FEE CALCULATION FUNCTION
    //////////////////////////////////////////////////////////////*/

    /// @notice V6: base (vol+imb) + small symmetric tox + floor + decay; then vulnerable-side tox+asym; then thresholded directionality; then larger surge
    function afterSwap(TradeInfo calldata trade) external override returns (uint256 bidFee, uint256 askFee) {
        uint256 oldPHat = slots[SLOT_PHAT];
        uint256 oldVol = slots[SLOT_VOLATILITY];
        uint256 lastTs = slots[SLOT_TIMESTAMP];
        uint256 sigmaHat = slots[SLOT_SIGMA];
        uint256 toxEma = slots[SLOT_TOX_EMA];

        slots[SLOT_TEMP_RESERVE_X] = trade.reserveX;
        slots[SLOT_TEMP_RESERVE_Y] = trade.reserveY;
        slots[SLOT_TEMP_TIMESTAMP] = trade.timestamp;
        slots[SLOT_TEMP_IS_BUY] = trade.isBuy ? 1 : 0;

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
        slots[SLOT_TEMP_VOL] = vol;

        uint256 tox = ret > TOX_CAP ? TOX_CAP : ret;
        toxEma = _wmul(ONE_WAD - TOX_ALPHA, toxEma) + _wmul(TOX_ALPHA, tox);

        uint256 rawFee = _computeRawFee(vol, toxEma, lastTs);
        uint256 baseFee = rawFee > MAX_FEE_CAP ? MAX_FEE_CAP : rawFee;

        uint256 toxPremium = _wmul(TOX_COEF, toxEma) + _wmul(TOX_QUAD_COEF, _wmul(toxEma, toxEma));
        uint256 bidFeeOut = slots[SLOT_TEMP_RESERVE_Y] >= slots[SLOT_TEMP_RESERVE_X]
            ? _clampFee(_wmul(baseFee + toxPremium, ONE_WAD + ASYMM)) : baseFee;
        uint256 askFeeOut = slots[SLOT_TEMP_RESERVE_Y] >= slots[SLOT_TEMP_RESERVE_X]
            ? baseFee : _clampFee(_wmul(baseFee + toxPremium, ONE_WAD + ASYMM));

        (bidFeeOut, askFeeOut) = _applyDirAndSurge(ret, adaptiveGate, spot, pHat, bidFeeOut, askFeeOut);

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
        return "Sapient v6 - (sym-tox floor + strong dir + surge)";
    }
}
