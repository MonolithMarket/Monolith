// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {InterestModel} from "src/InterestModel.sol";
import "lib/solmate/src/utils/SignedWadMath.sol";
contract InterestModelTest is Test {
    InterestModel interestModel;

    function setUp() public {
        interestModel = new InterestModel();
    }
    
    function test_calculateInterest(uint _totalPaidDebt, uint lastFreeDebtRatioBps, uint timeElapsed, uint halfLife, uint lastRate) public view {
        lastFreeDebtRatioBps = bound(lastFreeDebtRatioBps, 0, 10000);
        timeElapsed = bound(timeElapsed, 1, 100);
        halfLife = bound(halfLife, 12 hours, 30 days);
        lastRate = bound(lastRate, 5e15, 1e18);

        uint totalPaidDebt = bound(_totalPaidDebt, 1e18, 1e32);
        uint expRate = uint(wadLn(2*1e18)) / halfLife;
        uint targetFreeDebtRatioStartBps = 2500; // 25%
        uint targetFreeDebtRatioEndBps = 7500; // 75%

        (uint currBorrowRate, uint interest) = interestModel.calculateInterest(totalPaidDebt, lastRate, timeElapsed, expRate, lastFreeDebtRatioBps, targetFreeDebtRatioStartBps, targetFreeDebtRatioEndBps);

        uint expectedBorrowRate = lastRate;
        uint expectedInterest;

        for (uint i = 0; i < timeElapsed; i++) {
            if(lastFreeDebtRatioBps < targetFreeDebtRatioStartBps) {
                // borrow rate grows
                expectedBorrowRate += expectedBorrowRate * expRate / 1e18;
            } else if(lastFreeDebtRatioBps > targetFreeDebtRatioEndBps) {
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
            expectedInterest += (totalPaidDebt + expectedInterest) * expectedBorrowRate / 1e18 / 365 days;
        }

        assertApproxEqRel(currBorrowRate, expectedBorrowRate, 1e11, "borrow rate mismatch");
        assertApproxEqRel(interest, expectedInterest, 1e15, "interest mismatch");
    }
}
