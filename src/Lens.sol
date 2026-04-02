// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import "./Lender.sol";

contract Lens {
    using FixedPointMathLib for uint256;
    
    /// @notice Previews borrower-specific redemption results using current state
    /// @param _lender The Lender contract to query
    /// @param borrower The borrower to redeem from
    /// @param amountIn The requested Coin amount to redeem
    /// @return coinIn The Coin amount that would actually be repaid
    /// @return amountOut The collateral amount out (in collateral token decimals)
    function previewRedeem(Lender _lender, address borrower, uint256 amountIn)
        external
        view
        returns (uint256 coinIn, uint256 amountOut)
    {
        if (amountIn == 0 || !_lender.isRedeemable(borrower)) return (0, 0);

        uint256 internalCollateralBalance = _lender._cachedCollateralBalances(borrower);
        if (internalCollateralBalance == 0) return (0, 0);

        (uint256 price,, bool allowLiquidations) = _lender.getCollateralPrice();
        if (!allowLiquidations) return (0, 0);

        uint256 borrowerDebt = getDebtOf(_lender, borrower);
        if (borrowerDebt == 0) return (0, 0);

        coinIn = amountIn > borrowerDebt ? borrowerDebt : amountIn;
        uint256 redeemFeeBps = _lender.redeemFeeBps();
        uint256 maxRedeemByCollateral = internalCollateralBalance * price * 10000 / 1e18 / (10000 - redeemFeeBps);
        if (maxRedeemByCollateral == 0) return (0, 0);
        if (coinIn > maxRedeemByCollateral) coinIn = maxRedeemByCollateral;

        uint256 internalAmountOut = coinIn * 1e18 * (10000 - redeemFeeBps) / price / 10000;
        if (internalAmountOut == 0 || internalAmountOut > internalCollateralBalance) return (0, 0);
        amountOut = _lender.internalToCollateral(internalAmountOut);
        if (amountOut == 0) return (0, 0);
    }

    /// @notice Returns the current debt of a borrower including accrued interest
    /// @param _lender The Lender contract to query
    /// @param borrower The address of the borrower
    /// @return The current debt amount including all accrued interest
    function getDebtOf(Lender _lender, address borrower) public view returns (uint256) {
        // Get the current total debt including accrued interest
        (uint256 totalPaidDebt, uint256 totalFreeDebt) = _getSyncedTotalDebt(_lender);
        
        // Calculate the borrower's share of debt based on whether they are redeemable
        if (_lender.isRedeemable(borrower)) {
            uint256 borrowerDebtShares = _lender.freeDebtShares(borrower);
            uint256 totalFreeDebtShares = _lender.totalFreeDebtShares();
            return totalFreeDebtShares == 0 ? 0 : borrowerDebtShares.mulDivUp(totalFreeDebt, totalFreeDebtShares);
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
    /// @return syncedTotalFreeDebt The total free debt
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
