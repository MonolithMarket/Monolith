// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import "./Lender.sol";

contract Lens {

    using FixedPointMathLib for uint256;
    

    function getCollateralOf(Lender _lender, address borrower) public view returns (uint256) {
        uint borrowerDebtShares = _lender.freeDebtShares(borrower);
        uint bal = _lender._cachedCollateralBalances(borrower);
        // If borrower has no free debt shares skip calculation and return cached balance
        if (borrowerDebtShares == 0) return _lender.internalToCollateral(bal);
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
        return _lender.internalToCollateral(bal);
    }

    /// @notice Returns the current debt of a borrower including accrued interest and accounting for redeemed debt
    /// @param _lender The Lender contract to query
    /// @param borrower The address of the borrower
    /// @return The current debt amount including all accrued interest and after accounting for redemptions
    function getDebtOf(Lender _lender, address borrower) public view returns (uint256) {
        // Get the current total debt including accrued interest
        (uint256 totalPaidDebt, uint256 totalFreeDebt) = _getSyncedTotalDebt(_lender);
        
        // Calculate the borrower's share of debt based on whether they are redeemable
        if (_lender.isRedeemable(borrower)) {
            // For redeemable (free) debt, we need to account for redemptions
            uint256 borrowerDebtShares = _lender.freeDebtShares(borrower);
            uint256 totalFreeDebtShares = _lender.totalFreeDebtShares();
            
            if (totalFreeDebtShares == 0) return 0;
            
            // Calculate base debt from shares
            uint256 debt = borrowerDebtShares.mulDivUp(totalFreeDebt, totalFreeDebtShares);
            
            // Account for debt reductions through redemptions
            // Similar to collateral redemptions, debt is reduced when redemptions occur
            uint256 _borrowerEpoch = _lender.borrowerEpoch(borrower);
            uint256 currentEpoch = _lender.epoch();
            
            // If borrower is in current epoch, no redemption adjustments needed
            // as redemptions reduce totalFreeDebt directly
            if (_borrowerEpoch < currentEpoch) {
                // Borrower missed epoch transitions, need to account for debt reductions
                // Each epoch transition reduces shares, which effectively reduces debt
                for (uint256 i = 0; i < 5 && _borrowerEpoch < currentEpoch && borrowerDebtShares > 0; ++i) {
                    _borrowerEpoch += 1;
                    borrowerDebtShares = borrowerDebtShares.divWadUp(1e36) == 1 ? 0 : borrowerDebtShares.divWadUp(1e36);
                }
                // Recalculate debt with reduced shares
                debt = totalFreeDebtShares == 0 ? 0 : borrowerDebtShares.mulDivUp(totalFreeDebt, totalFreeDebtShares);
            }
            
            return debt;
        } else {
            // For non-redeemable (paid) debt, simply calculate from shares with synced total
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