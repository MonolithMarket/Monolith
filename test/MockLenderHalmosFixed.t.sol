// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockLenderFreeDebtFixed} from "src/MockLenderFreeDebtFixed.sol";

/// @notice Halmos symbolic checks against the FIX-applied form of increaseDebt.
///         Runs the same invariants as MockLenderHalmos.t.sol, but on the
///         FIX. Used to confirm the FIX also preserves the invariants
///         (and thus the FIX is at least as safe as the pre-PR code).
contract MockLenderHalmosFixedTest is Test {
    MockLenderFreeDebtFixed mock;
    address constant target = address(0xA);

    function setUp() public { mock = new MockLenderFreeDebtFixed(); }

    function _setD(uint256 v) internal { vm.store(address(mock), bytes32(uint256(0)), bytes32(v)); }
    function _setS(uint256 v) internal { vm.store(address(mock), bytes32(uint256(1)), bytes32(v)); }
    function _setShares(address u, uint256 v) internal {
        vm.store(address(mock), keccak256(abi.encode(u, uint256(2))), bytes32(v));
    }

    uint256 constant CAP = 2 ** 32;
    function _bound(uint256 v) internal pure { vm.assume(v < CAP); }
    function _assumeI(uint256 D, uint256 S) internal pure { vm.assume(D > 0 || S == 0); }
    function _assumeJ(uint256 D, uint256 S) internal pure { vm.assume(D >= S); }
    function _assertI() internal view {
        uint256 D = mock.totalFreeDebt(); uint256 S = mock.totalFreeDebtShares();
        assert(D > 0 || S == 0);
    }
    function _assertJ() internal view {
        assert(mock.totalFreeDebt() >= mock.totalFreeDebtShares());
    }

    function check_I_after_increaseDebt_FIX(uint256 D, uint256 S, uint256 X, uint256 amount) external {
        _bound(D); _bound(S); _bound(X); _bound(amount);
        _assumeI(D, S);
        vm.assume(X <= S);
        _setD(D); _setS(S); _setShares(target, X);
        mock.increaseDebt(target, amount);
        _assertI();
    }

    function check_J_after_increaseDebt_FIX(uint256 D, uint256 S, uint256 X, uint256 amount) external {
        _bound(D); _bound(S); _bound(X); _bound(amount);
        _assumeJ(D, S);
        vm.assume(X <= S);
        _setD(D); _setS(S); _setShares(target, X);
        mock.increaseDebt(target, amount);
        _assertJ();
    }
}
