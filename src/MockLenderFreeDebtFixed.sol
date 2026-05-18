// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import "lib/solmate/src/utils/FixedPointMathLib.sol";

/// @title  Same harness as MockLenderFreeDebt but with the PR FIX applied to increaseDebt
/// @notice Used to verify (via Halmos) that the FIX also preserves the invariant.
contract MockLenderFreeDebtFixed {
    using FixedPointMathLib for uint256;

    uint public totalFreeDebt;
    uint public totalFreeDebtShares;
    mapping(address => uint) public freeDebtShares;

    /// @dev FIX-applied form of increaseDebt FREE branch.
    /// Source: PR diff vs Lender.sol:549-565
    function increaseDebt(address account, uint256 amount) external {
        // FIX: split D=0 case by S
        uint shares;
        if (totalFreeDebt == 0) {
            if (totalFreeDebtShares == 0) {
                shares = amount;
            } else {
                // If freeDebtShares are non zero, we have to give the new
                // borrower disproportionately many shares to avoid spreading
                // new debt among existing debt share holders
                shares = amount.mulDivUp(totalFreeDebtShares, 1);
            }
        } else {
            shares = amount.mulDivUp(totalFreeDebtShares, totalFreeDebt);
        }

        totalFreeDebt += amount;
        totalFreeDebtShares += shares;
        freeDebtShares[account] += shares;
    }

    function decreaseDebt(address account, uint256 amount) external {
        uint256 shares;
        if (amount == type(uint).max) {
            shares = freeDebtShares[account];
            amount = getDebtOf(account);
        } else {
            shares = amount.mulDivDown(totalFreeDebtShares, totalFreeDebt);
        }
        freeDebtShares[account] -= shares;
        totalFreeDebtShares = totalFreeDebtShares <= shares ? 0 : totalFreeDebtShares - shares;
        totalFreeDebt = totalFreeDebt <= amount ? 0 : totalFreeDebt - amount;
    }

    function writeOffRedistribute(uint256 debt, uint256 totalDebt) external {
        if (totalDebt > 0) {
            uint256 freeDebtIncrease = debt * totalFreeDebt / totalDebt;
            totalFreeDebt += freeDebtIncrease;
        }
    }

    function getDebtOf(address account) public view returns (uint) {
        return totalFreeDebtShares == 0 ? 0 : freeDebtShares[account].mulDivUp(totalFreeDebt, totalFreeDebtShares);
    }
}
