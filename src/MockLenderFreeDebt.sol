// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import "lib/solmate/src/utils/FixedPointMathLib.sol";

/// @title  Minimized harness extracted from src/Lender.sol for Halmos symbolic execution
/// @notice ALL functions here are byte-for-byte copies of the corresponding FREE-debt
///         logic in Lender.sol. Code that does not read or write totalFreeDebt /
///         totalFreeDebtShares / freeDebtShares[] has been removed.
///
/// @dev Storage layout intentionally identical to Lender.sol's FREE-debt slots
///      (so vm.store-based test setup uses the same offsets logically — though
///      slot numbers differ since other Lender state is omitted here).
///
/// @dev All callers in Lender.sol go through one of these functions to mutate
///      FREE-debt storage:
///        Lender.sol:557-559    (increaseDebt FREE branch)              → increaseDebt
///        Lender.sol:589-597    (decreaseDebt FREE branch)              → decreaseDebt
///        Lender.sol:398-405    (writeOff redistribute FREE side)       → writeOffRedistribute
///        Lender.sol:653-654    (getDebtOf FREE branch — read-only)     → getDebtOf
///
/// @dev Code intentionally omitted (does not affect FREE-debt storage):
///        - The else branches (paid debt) — separate storage.
///        - The actualDebtIncrease / maxBorrowDelta `require` in increaseDebt
///          (Lender.sol:562-565). A failed `require` reverts the entire tx, so
///          omitting it is a sound over-approximation: if the invariant holds
///          for ALL increaseDebt calls (including those that would have
///          reverted), it certainly holds for the subset that succeed.
///        - The collateralBalance / safeTransfer in writeOff (no FREE-debt effect).
///        - accrueInterest / liquidate / redeem / adjust wrappers — they all
///          ultimately call increaseDebt/decreaseDebt; mutator-level proof
///          covers them transitively.
///
/// @dev IMPORTANT: This contract has the PRE-PR (vulnerable) form of increaseDebt.
contract MockLenderFreeDebt {
    using FixedPointMathLib for uint256;

    // ─── State (matches Lender.sol:52-53 and Lender.sol:87) ───
    uint public totalFreeDebt;          // slot 0   (Lender slot 5)
    uint public totalFreeDebtShares;    // slot 1   (Lender slot 6)
    mapping(address => uint) public freeDebtShares;  // slot 2 (Lender slot 23)

    // ─── EXACT COPY of Lender.sol::increaseDebt FREE branch (lines 549-565) ───
    //
    // Lender.sol original:
    //
    //   function increaseDebt(address account, uint256 amount) internal {
    //       if (isRedeemable[account]) {
    //           // Handle free debt
    //           uint shares = totalFreeDebt == 0 ?
    //                   amount :
    //                   amount.mulDivUp(totalFreeDebtShares, totalFreeDebt);
    //           totalFreeDebt += amount;
    //           totalFreeDebtShares += shares;
    //           freeDebtShares[account] += shares;
    //           // ... maxBorrowDelta require omitted (see contract docs above)
    //       } else { ... paid branch omitted ... }
    //   }
    //
    /// @dev Hardcoded to FREE branch (assumes isRedeemable[account] == true).
    function increaseDebt(address account, uint256 amount) external {
        // Handle free debt
        uint shares = totalFreeDebt == 0 ?
                amount :
                amount.mulDivUp(totalFreeDebtShares, totalFreeDebt);

        // Update state first
        totalFreeDebt += amount;
        totalFreeDebtShares += shares;
        freeDebtShares[account] += shares;
    }

    // ─── EXACT COPY of Lender.sol::decreaseDebt FREE branch (lines 585-597) ───
    //
    //   function decreaseDebt(address account, uint256 amount) internal {
    //       if (isRedeemable[account]) {
    //           // Handle free debt
    //           uint256 shares;
    //           if(amount == type(uint).max) {
    //               shares = freeDebtShares[account];
    //               amount = getDebtOf(account);
    //           } else {
    //               shares = amount.mulDivDown(totalFreeDebtShares, totalFreeDebt);
    //           }
    //           freeDebtShares[account] -= shares;
    //           totalFreeDebtShares = totalFreeDebtShares <= shares ? 0 : totalFreeDebtShares - shares;
    //           totalFreeDebt = totalFreeDebt <= amount ? 0 : totalFreeDebt - amount;
    //       } else { ... paid branch omitted ... }
    //   }
    //
    function decreaseDebt(address account, uint256 amount) external {
        // Handle free debt
        uint256 shares;
        if (amount == type(uint).max) {
            shares = freeDebtShares[account];
            amount = getDebtOf(account);
        } else {
            shares = amount.mulDivDown(totalFreeDebtShares, totalFreeDebt);
        }
        freeDebtShares[account] -= shares;
        totalFreeDebtShares = totalFreeDebtShares <= shares ? 0 : totalFreeDebtShares - shares; // prevent underflow
        totalFreeDebt = totalFreeDebt <= amount ? 0 : totalFreeDebt - amount; // prevent underflow
    }

    // ─── EXACT COPY of Lender.sol::writeOff redistribute step (lines 398-405) ───
    //
    //   uint256 totalDebt = totalFreeDebt + totalPaidDebt;
    //   if (totalDebt > 0) {
    //       uint256 freeDebtIncrease = debt * totalFreeDebt / totalDebt;
    //       uint256 paidDebtIncrease = debt - freeDebtIncrease;
    //       totalFreeDebt += freeDebtIncrease;
    //       totalPaidDebt += paidDebtIncrease;
    //   }
    //
    /// @notice Just the FREE-side write of writeOff's redistribute.
    /// @param debt           pre-decrease debt of the borrower being written off
    /// @param totalDebt      totalFreeDebt + totalPaidDebt at the time of redistribute
    ///                       (post-decreaseDebt). Equals THIS contract's totalFreeDebt
    ///                       plus an external paidDebt amount.
    /// @dev `totalDebt > 0` matches the source `if` guard.
    /// @dev `paidDebtIncrease` and `totalPaidDebt += paidDebtIncrease` are intentionally
    ///      not modeled (no effect on FREE storage).
    function writeOffRedistribute(uint256 debt, uint256 totalDebt) external {
        if (totalDebt > 0) {
            uint256 freeDebtIncrease = debt * totalFreeDebt / totalDebt;
            totalFreeDebt += freeDebtIncrease;
            // totalPaidDebt += paidDebtIncrease;   // omitted: external state
        }
    }

    // ─── EXACT COPY of Lender.sol::getDebtOf FREE branch (lines 652-654) ───
    //
    //   function getDebtOf(address account) public view returns (uint) {
    //       if(isRedeemable[account]) {
    //           return totalFreeDebtShares == 0 ? 0 : freeDebtShares[account].mulDivUp(totalFreeDebt, totalFreeDebtShares);
    //       } else { ... }
    //   }
    //
    function getDebtOf(address account) public view returns (uint) {
        return totalFreeDebtShares == 0 ? 0 : freeDebtShares[account].mulDivUp(totalFreeDebt, totalFreeDebtShares);
    }
}
