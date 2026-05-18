// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import "./Lender.sol";

contract Lens {
    using FixedPointMathLib for uint256;
    
    /// @notice Returns the current debt of a borrower including accrued interest
    /// @param _lender The Lender contract to query
    /// @param borrower The address of the borrower
    /// @return The current debt amount including all accrued interest
    function getDebtOf(Lender _lender, address borrower) public view returns (uint256) {
        // Get the current total debt including accrued interest
        uint256 totalPaidDebt = _getSyncedTotalDebt(_lender);
        uint256 paidDebtShares = _lender.paidDebtShares(borrower);
        uint256 totalPaidDebtShares = _lender.totalPaidDebtShares();
        return totalPaidDebtShares == 0 ? 0 : paidDebtShares.mulDivUp(totalPaidDebt, totalPaidDebtShares);
    }

    /// @notice Internal helper to calculate total debt including accrued interest
    /// @param _lender The Lender contract to query
    /// @return syncedTotalPaidDebt The total paid debt including accrued interest
    function _getSyncedTotalDebt(Lender _lender) internal view returns (uint256 syncedTotalPaidDebt) {
        uint256 totalPaidDebt = _lender.totalPaidDebt();
        
        // Calculate accrued interest since last accrual
        uint256 timeElapsed = block.timestamp - _lender.lastAccrue();
        
        if (timeElapsed == 0 || _lender.eventTriggerMode()) return totalPaidDebt;
        
        // Call the interest model to calculate accrued interest
        try _lender.interestModel().calculateInterest(
            totalPaidDebt,
            _lender.lastBorrowRateMantissa(),
            timeElapsed,
            _lender.expRate(),
            _lender.getPsmDebtRatio(),
            _lender.targetPsmDebtRatioStartBps(),
            _lender.targetPsmDebtRatioEndBps()
        ) returns (uint256, uint256 interest) {
            // Add accrued interest to paid debt
            syncedTotalPaidDebt = totalPaidDebt + interest;
        } catch {
            // If interest calculation fails, return current totals
            syncedTotalPaidDebt = totalPaidDebt;
        }
    }
}
