// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import "./Lender.sol";

contract Lens {

    using FixedPointMathLib for uint256;
    

    function getCollateralOf(Lender _lender, address borrower) public view returns (uint256) {
        return _lender.internalToCollateral(_lender._cachedCollateralBalances(borrower));
    }

    /// @notice Returns the current debt of a borrower including accrued interest and accounting for redeemed debt
    /// @param _lender The Lender contract to query
    /// @param borrower The address of the borrower
    /// @return The current debt amount including all accrued interest and after accounting for redemptions
    function getDebtOf(Lender _lender, address borrower) public view returns (uint256) {
        // Get the current total debt including accrued interest
        (uint256 totalPaidDebt, uint256 totalFreeDebt) = _getSyncedTotalDebt(_lender);
        
        if (_lender.isRedeemable(borrower)) {
            uint256 borrowerDebtShares = _lender.freeDebtShares(borrower);
            uint256 totalFreeDebtShares = _lender.totalFreeDebtShares();
            if (totalFreeDebtShares == 0) return 0;
            return borrowerDebtShares.mulDivUp(totalFreeDebt, totalFreeDebtShares);
        } else {
            uint256 paidDebtShares = _lender.paidDebtShares(borrower);
            uint256 totalPaidDebtShares = _lender.totalPaidDebtShares();
            return totalPaidDebtShares == 0 ? 0 : paidDebtShares.mulDivUp(totalPaidDebt, totalPaidDebtShares);
        }
    }

    /// @notice Internal helper to calculate total debt including accrued interest
    /// @param _lender The Lender contract to query
    /// @return syncedTotalPaidDebt The total paid debt including accrued interest
    /// @return syncedTotalFreeDebt The total free debt (redemptions already reduce this directly)
    function _getSyncedTotalDebt(Lender _lender) internal view returns (uint256 syncedTotalPaidDebt, uint256 syncedTotalFreeDebt) {
        uint256 totalPaidDebt = _lender.totalPaidDebt();
        syncedTotalFreeDebt = _lender.totalFreeDebt();
        
        // Calculate accrued interest since last accrual
        uint256 timeElapsed = block.timestamp - _lender.lastAccrue();
        
        if (timeElapsed == 0) {
            return (totalPaidDebt, syncedTotalFreeDebt);
        }
        
        // Call the interest model to calculate accrued interest
        try _lender.interestModel().calculateInterest(
            totalPaidDebt,
            _lender.lastBorrowRateMantissa(),
            timeElapsed,
            _lender.expRate(),
            _lender.getFreeDebtRatio(),
            _lender.targetFreeDebtRatioStartBps(),
            _lender.targetFreeDebtRatioEndBps()
        ) returns (uint256, uint256 interest) {
            // Add accrued interest to paid debt
            syncedTotalPaidDebt = totalPaidDebt + interest;
        } catch {
            // If interest calculation fails, return current totals
            syncedTotalPaidDebt = totalPaidDebt;
        }
    }
}
