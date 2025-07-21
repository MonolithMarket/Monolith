// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "./Lender.sol";

contract Lens {

    using FixedPointMathLib for uint256;

    function getCollateralOf(Lender _lender, address _borrower) public view returns (uint256) {
        uint bal = _lender._cachedCollateralBalances(_borrower);
        uint borrowerDebtShares = _lender.freeDebtShares(_borrower);
        // if borrower has free debt, we proceed
        if(borrowerDebtShares > 0) {
            uint _borrowerEpoch = _lender.borrowerEpoch(_borrower);
            // index is denominated in collateral tokens redeemed per free debt share
            uint indexDelta = _lender.epochRedeemedCollateral(_borrowerEpoch) - _lender.borrowerLastRedeemedIndex(_borrower);
            // multiply the index delta by the borrower's debt shares to get the amount of collateral redeemed
            uint redeemedCollateral = indexDelta.mulDivUp(borrowerDebtShares, 1e18);
            // reduce collateral balance and guard against underflow
            bal = bal < redeemedCollateral ? 0 : bal - redeemedCollateral;
        }
        return bal;
    }
}