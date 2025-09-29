// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "./Lender.sol";

contract Lens {

    using FixedPointMathLib for uint256;
    

    function getCollateralOf(Lender _lender, address borrower) public view returns (uint256) {
        uint borrowerDebtShares = _lender.freeDebtShares(borrower);
        uint bal = _lender._cachedCollateralBalances(borrower);
        // If borrower has no free debt shares skip calculation and return cached balance
        if (borrowerDebtShares == 0) return bal;
        uint _borrowerEpoch = _lender.borrowerEpoch(borrower);
        uint lastIndex = _lender.borrowerLastRedeemedIndex(borrower);
        // Loop through all missed epochs
        for (uint i = 0; i < 5 && _borrowerEpoch < _lender.epoch() && borrowerDebtShares > 0; ++i) {
            // Apply redemption for the borrower's current epoch
            uint indexDelta = _lender.epochRedeemedCollateral(_borrowerEpoch) - lastIndex;
            uint redeemedCollateral = indexDelta.mulDivUp(borrowerDebtShares, 1e36);
            bal = bal < redeemedCollateral ? 0 : bal - redeemedCollateral;

            // Move to next epoch, reduce shares
            _borrowerEpoch += 1;
            borrowerDebtShares = borrowerDebtShares.divWadUp(1e36) == 1 ? 0 : borrowerDebtShares.divWadUp(1e36); // If shares is 1 round down to 0
            lastIndex = 0; // For new epoch, last redeemed index is 0
        }
        // Apply any remaining redemption for the current epoch
        if (borrowerDebtShares > 0) {
            uint indexDelta = _lender.epochRedeemedCollateral(_borrowerEpoch) - lastIndex;
            uint redeemedCollateral = indexDelta.mulDivUp(borrowerDebtShares, 1e36);
            bal = bal < redeemedCollateral ? 0 : bal - redeemedCollateral;
        }
        return bal;
    }
}