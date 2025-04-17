// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "lib/solmate/src/utils/SignedWadMath.sol";

// Only one instance of this contract is deployed for use by all Lender contracts
contract InterestModel {

    uint internal constant MIN_RATE = 5e15; // 0.5%

    // The reason why this pure math is called externally by Lender contracts even though
    // it is non-upgradeable is to allow Lender contracts try/catch the call for safety.
    // In case of unexpected under/overflow here, Lender contracts would skip accruing interest
    // while allowing borrowers to exit. Otherwise failure would freeze their funds.
    // We could have also added this as an external function to Lender and called
    // self.calculateInterest() externally, but since it's the same cost to call it here,
    // we opt for this approach in order to reduce contract bytecode size of Lender.
    // We also reduce Factory deployment costs by only using one instance of
    // this contract for all Lender contracts.
    function calculateInterest(
        uint _totalPaidDebt,
        uint _lastRate,
        uint _timeElapsed,
        uint _expRate,
        uint _lastFreeDebtRatioBps,
        uint _targetFreeDebtRatioStartBps,
        uint _targetFreeDebtRatioEndBps
    ) external pure returns (uint currBorrowRate, uint interest) {
        // check _expRate * _timeElapsed overflow
        if(uint(type(int256).max) / _expRate < _timeElapsed) _timeElapsed = uint(type(int256).max) / _expRate;
        // we use a negative exponent in order to prevent growthDecay overflow due to large timeElapsed
        // Results of positive exponents can exceed max uint256, negative exponents only return a value between [0, 1e18]
        uint growthDecay = uint(wadExp(-int(_expRate * _timeElapsed)));
        
        if (_lastFreeDebtRatioBps < _targetFreeDebtRatioStartBps) {
            currBorrowRate = _lastRate * 1e18 / growthDecay;
            interest = _totalPaidDebt * (currBorrowRate - _lastRate) * 1e18 / _expRate / 365 days;
        } else if (_lastFreeDebtRatioBps > _targetFreeDebtRatioEndBps) {
            currBorrowRate = _lastRate * growthDecay / 1e18;
            if (currBorrowRate < MIN_RATE) {
                currBorrowRate = MIN_RATE;
                // calculate integral
                if (_lastRate <= MIN_RATE) {
                    // Already at min rate, just use flat rate for entire period
                    interest = _totalPaidDebt * MIN_RATE * _timeElapsed / 365 days;
                } else {
                    uint timeToMin = uint(-wadLn(int(MIN_RATE * 1e18 / _lastRate))) * 1e18 / _expRate;
                    // Decaying integral up to min rate, then add flat rate portion
                    interest = _totalPaidDebt * ((_lastRate - MIN_RATE) * 1e18 / _expRate + 
                              MIN_RATE * (_timeElapsed - timeToMin)) / 365 days;
                }
            } else {
                interest = _totalPaidDebt * (_lastRate - currBorrowRate) * 1e18 / _expRate / 365 days;
            }
        } else {
            currBorrowRate = _lastRate;
            interest = _totalPaidDebt * _lastRate * _timeElapsed / 365 days;
        }
    }
}