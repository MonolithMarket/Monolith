// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {InterestModel} from "src/InterestModel.sol";
import "lib/solmate/src/utils/SignedWadMath.sol";
contract InterestModelTest is Test {
    InterestModel interestModel;

    function setUp() public {
        interestModel = new InterestModel();
    }
    
    function test_calculateInterest(uint _totalPaidDebt, uint lastPsmDebtRatioBps, uint timeElapsed, uint halfLife, uint lastRate) public view {
        lastPsmDebtRatioBps = bound(lastPsmDebtRatioBps, 0, 10000);
        timeElapsed = bound(timeElapsed, 1, 7 days);
        halfLife = bound(halfLife, 12 hours, 30 days);
        lastRate = bound(lastRate, 5e15, 1e18);

        uint totalPaidDebt = bound(_totalPaidDebt, 1e18, 1e20);
        uint expRate = uint(wadLn(2*1e18)) / halfLife;
        uint targetPsmDebtRatioStartBps = 2500; // 25%
        uint targetPsmDebtRatioEndBps = 7500; // 75%

        (uint currBorrowRate, uint interest) = interestModel.calculateInterest(totalPaidDebt, lastRate, timeElapsed, expRate, lastPsmDebtRatioBps, targetPsmDebtRatioStartBps, targetPsmDebtRatioEndBps);

        uint expectedBorrowRate = lastRate;
        uint expectedInterest;

        for (uint i = 0; i < timeElapsed; i++) {
            if(lastPsmDebtRatioBps < targetPsmDebtRatioStartBps) {
                // borrow rate grows
                expectedBorrowRate += expectedBorrowRate * expRate / 1e18;
            } else if(lastPsmDebtRatioBps > targetPsmDebtRatioEndBps) {
                // borrow rate decays
                expectedBorrowRate -= expectedBorrowRate * expRate / 1e18;
            } else {
                // borrow rate remains constant
                expectedBorrowRate = expectedBorrowRate;
            }
            uint MIN_RATE = 5e15; // 0.5%
            if(expectedBorrowRate < MIN_RATE) {
                expectedBorrowRate = MIN_RATE;
            }
            expectedInterest += totalPaidDebt * expectedBorrowRate / 1e18 / 365 days;
        }

        assertApproxEqRel(currBorrowRate, expectedBorrowRate, 0.05e18, "borrow rate mismatch");
        assertApproxEqRel(interest, expectedInterest, 0.05e18, "interest mismatch");
    }

    function test_calculateInterest_wadExpUnderflow() public view {
        uint totalPaidDebt = 1e18;
        uint lastRate = 5e16;
        uint timeElapsed = 60 days;
        uint halfLife = 12 hours;
        uint expRate = uint(wadLn(2e18)) / halfLife;
        uint lastPsmDebtRatioBps = 1000;
        uint targetPsmDebtRatioStartBps = 2500;
        uint targetPsmDebtRatioEndBps = 7500;

        (uint currBorrowRate, uint interest) = interestModel.calculateInterest(
            totalPaidDebt,
            lastRate,
            timeElapsed,
            expRate,
            lastPsmDebtRatioBps,
            targetPsmDebtRatioStartBps,
            targetPsmDebtRatioEndBps
        );

        // When growthDecay underflows to 0, we set it to 1, causing currBorrowRate
        // to exceed uint88.max, triggering overflow protection: return (_lastRate, 0)
        assertEq(currBorrowRate, lastRate);
        assertEq(interest, 0);
    }
}
