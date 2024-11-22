// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import {Test, console} from "forge-std/Test.sol";
import "lib/solmate/src/utils/SignedWadMath.sol";
import {USD2} from "src/USD2.sol";

contract USD2Wrapper is USD2 {

    constructor() USD2(address(0),address(0),address(0)) {}

    function _calculateRate(uint _lastRate,
        uint _timeElapsed,
        uint _expRate,
        uint _lastFreeDebtRatioBps,
        uint _targetFreeDebtRatioStartBps,
        uint _targetFreeDebtRatioEndBps) public pure returns (uint currBorrowRate, uint integral) {
        return calculateRate(_lastRate, _timeElapsed, _expRate, _lastFreeDebtRatioBps, _targetFreeDebtRatioStartBps, _targetFreeDebtRatioEndBps);
    }

}

contract USD2Test is Test {

    USD2Wrapper usd2;

    function setUp() public {
        usd2 = new USD2Wrapper();
    }

    function test_calculateRate_growth() public view {
        uint lastRate = 1e16;
        uint timeElapsed = 7 days;
        uint expRate = usd2.expRate();
        uint lastFreeDebtRatioBps = 0;
        uint targetFreeDebtRatioStartBps = usd2.targetFreeDebtRatioStartBps();
        uint targetFreeDebtRatioEndBps = usd2.targetFreeDebtRatioEndBps();
        (uint currBorrowRate, uint integral) = usd2._calculateRate(
            lastRate,
            timeElapsed,
            expRate,
            lastFreeDebtRatioBps,
            targetFreeDebtRatioStartBps,
            targetFreeDebtRatioEndBps
        );
        uint expectedRate = lastRate;
        uint expectedIntegral = 0;
        for(uint i = 0; i < timeElapsed; i++) {
            uint growthDecay = uint(wadExp(int(expRate)));
            expectedRate = expectedRate * growthDecay / 1e18;
            expectedIntegral += expectedRate;
        }
        assertApproxEqAbs(currBorrowRate, expectedRate, 1e8);
        assertApproxEqAbs(integral, expectedIntegral, 1e16);
    }

    function test_calculateRate_decay() public view {
        uint lastRate = 1e16;
        uint timeElapsed = 7 days;
        uint expRate = usd2.expRate();
        uint lastFreeDebtRatioBps = 10000;
        uint targetFreeDebtRatioStartBps = usd2.targetFreeDebtRatioStartBps();
        uint targetFreeDebtRatioEndBps = usd2.targetFreeDebtRatioEndBps();
        (uint currBorrowRate, uint integral) = usd2._calculateRate(
            lastRate,
            timeElapsed,
            expRate,
            lastFreeDebtRatioBps,
            targetFreeDebtRatioStartBps,
            targetFreeDebtRatioEndBps
        );
        uint expectedRate = lastRate;
        uint expectedIntegral = 0;
        for(uint i = 0; i < timeElapsed; i++) {
            uint growthDecay = uint(wadExp(int(expRate)));
            expectedRate = expectedRate * 1e18 / growthDecay;
            expectedIntegral += expectedRate;
        }
        assertApproxEqAbs(currBorrowRate, expectedRate, 1e8);
        assertApproxEqAbs(integral, expectedIntegral, 1e16);
    }

    function test_calculateRate_decay_minRate_to_minRate() public view {
        uint minRate = 5e15;
        uint lastRate = minRate;
        uint timeElapsed = 7 days;
        uint expRate = usd2.expRate();
        uint lastFreeDebtRatioBps = 10000;
        uint targetFreeDebtRatioStartBps = usd2.targetFreeDebtRatioStartBps();
        uint targetFreeDebtRatioEndBps = usd2.targetFreeDebtRatioEndBps();
        (uint currBorrowRate, uint integral) = usd2._calculateRate(
            lastRate,
            timeElapsed,
            expRate,
            lastFreeDebtRatioBps,
            targetFreeDebtRatioStartBps,
            targetFreeDebtRatioEndBps
        );
        assertEq(currBorrowRate, minRate);
        assertEq(integral, minRate * timeElapsed);
    }

    function test_calculateRate_decay_to_minRate() public view {
        uint minRate = 5e15;
        uint lastRate = 1e15;
        uint timeElapsed = 7 days;
        uint expRate = usd2.expRate();
        uint lastFreeDebtRatioBps = 10000;
        uint targetFreeDebtRatioStartBps = usd2.targetFreeDebtRatioStartBps();
        uint targetFreeDebtRatioEndBps = usd2.targetFreeDebtRatioEndBps();
        (uint currBorrowRate, uint integral) = usd2._calculateRate(
            lastRate,
            timeElapsed,
            expRate,
            lastFreeDebtRatioBps,
            targetFreeDebtRatioStartBps,
            targetFreeDebtRatioEndBps
        );
        uint expectedRate = lastRate;
        uint expectedIntegral = 0;
        for(uint i = 0; i < timeElapsed; i++) {
            uint growthDecay = uint(wadExp(int(expRate)));
            expectedRate = expectedRate * 1e18 / growthDecay;
            if(expectedRate < minRate) {
                expectedRate = minRate;
            }
            expectedIntegral += expectedRate;
        }
        assertApproxEqAbs(currBorrowRate, expectedRate, 1e8);
        assertApproxEqAbs(integral, expectedIntegral, 1e16);
    }

    function test_calculateRate_unchanged() public view {
        uint lastRate = 1e16;
        uint timeElapsed = 7 days;
        uint expRate = usd2.expRate();
        uint lastFreeDebtRatioBps = usd2.targetFreeDebtRatioStartBps();
        uint targetFreeDebtRatioStartBps = usd2.targetFreeDebtRatioStartBps();
        uint targetFreeDebtRatioEndBps = usd2.targetFreeDebtRatioEndBps();
        (uint currBorrowRate, uint integral) = usd2._calculateRate(
            lastRate,
            timeElapsed,
            expRate,
            lastFreeDebtRatioBps,
            targetFreeDebtRatioStartBps,
            targetFreeDebtRatioEndBps
        );
        uint expectedRate = lastRate;
        uint expectedIntegral = lastRate * timeElapsed;
        assertEq(currBorrowRate, expectedRate);
        assertEq(integral, expectedIntegral);
    }
        

}
