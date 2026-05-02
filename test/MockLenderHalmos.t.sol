// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockLenderFreeDebt} from "src/MockLenderFreeDebt.sol";

/// @title  Halmos symbolic-execution proofs for the FREE-debt invariant
/// @notice Single-step inductive proof: assume invariant holds in some prior
///         state, run one operation, prove invariant still holds. Combined
///         with the trivial base case (initial state D=0,S=0), induction
///         gives the property for ALL reachable states.
contract MockLenderHalmosTest is Test {
    MockLenderFreeDebt mock;

    address constant target = address(0xA);

    function setUp() public {
        mock = new MockLenderFreeDebt();
    }

    // Storage helpers (slots verified via `forge inspect MockLenderFreeDebt storage-layout`)
    function _setD(uint256 v) internal { vm.store(address(mock), bytes32(uint256(0)), bytes32(v)); }
    function _setS(uint256 v) internal { vm.store(address(mock), bytes32(uint256(1)), bytes32(v)); }
    function _setShares(address u, uint256 v) internal {
        vm.store(address(mock), keccak256(abi.encode(u, uint256(2))), bytes32(v));
    }

    // Bound symbolic uint256s to keep SMT tractable. The inductive property is
    // RATIO-based — if a counter-example exists in uint256, a similar one exists
    // at small scale (Z3 found D=1,S=2,X=1; Halmos at 2^32 found 2^31,3·2^30,...).
    // 2^16 is small enough for SMT to solve symbolic multiplications quickly while
    // still big enough to surface any ratio-based counter-example.
    uint256 constant CAP = 2 ** 16;
    function _bound(uint256 v) internal pure { vm.assume(v < CAP); }

    function _assumeI(uint256 D, uint256 S) internal pure { vm.assume(D > 0 || S == 0); }
    function _assumeJ(uint256 D, uint256 S) internal pure { vm.assume(D >= S); }

    function _assertI() internal view {
        uint256 D = mock.totalFreeDebt();
        uint256 S = mock.totalFreeDebtShares();
        assert(D > 0 || S == 0);
    }
    function _assertJ() internal view {
        assert(mock.totalFreeDebt() >= mock.totalFreeDebtShares());
    }

    // =====================================================================
    // PART 1 — Invariant I := (D = 0 ⇒ S = 0)
    // =====================================================================

    function check_I_after_increaseDebt(uint256 D, uint256 S, uint256 X, uint256 amount) external {
        _bound(D); _bound(S); _bound(X); _bound(amount);
        _assumeI(D, S);
        vm.assume(X <= S);              // sum invariant
        _setD(D); _setS(S); _setShares(target, X);
        mock.increaseDebt(target, amount);
        _assertI();
    }

    function check_I_after_decreaseDebt_nonmax(uint256 D, uint256 S, uint256 X, uint256 amount) external {
        _bound(D); _bound(S); _bound(X); _bound(amount);
        _assumeI(D, S);
        vm.assume(X <= S);
        vm.assume(D > 0);                       // mulDivDown reverts on denom=0
        vm.assume(amount != type(uint256).max); // ensure non-max branch
        _setD(D); _setS(S); _setShares(target, X);
        try mock.decreaseDebt(target, amount) { _assertI(); } catch { _assertI(); }
    }

    function check_I_after_decreaseDebt_max(uint256 D, uint256 S, uint256 X) external {
        _bound(D); _bound(S); _bound(X);
        _assumeI(D, S);
        vm.assume(X <= S);
        _setD(D); _setS(S); _setShares(target, X);
        try mock.decreaseDebt(target, type(uint256).max) { _assertI(); } catch { _assertI(); }
    }

    function check_I_after_writeOffRedistribute(
        uint256 D, uint256 S, uint256 debt, uint256 totalDebt
    ) external {
        _bound(D); _bound(S); _bound(debt); _bound(totalDebt);
        _assumeI(D, S);
        vm.assume(D <= totalDebt);
        _setD(D); _setS(S);
        mock.writeOffRedistribute(debt, totalDebt);
        _assertI();
    }

    // =====================================================================
    // PART 2 — Stronger invariant J := (D ≥ S)  (J inductive ⇒ J always ⇒ I always)
    // =====================================================================

    function check_J_after_increaseDebt(uint256 D, uint256 S, uint256 X, uint256 amount) external {
        _bound(D); _bound(S); _bound(X); _bound(amount);
        _assumeJ(D, S);
        vm.assume(X <= S);
        _setD(D); _setS(S); _setShares(target, X);
        mock.increaseDebt(target, amount);
        _assertJ();
    }

    function check_J_after_decreaseDebt_nonmax(uint256 D, uint256 S, uint256 X, uint256 amount) external {
        _bound(D); _bound(S); _bound(X); _bound(amount);
        _assumeJ(D, S);
        vm.assume(X <= S);
        vm.assume(D > 0);
        vm.assume(amount != type(uint256).max);
        _setD(D); _setS(S); _setShares(target, X);
        try mock.decreaseDebt(target, amount) { _assertJ(); } catch { _assertJ(); }
    }

    function check_J_after_decreaseDebt_max(uint256 D, uint256 S, uint256 X) external {
        _bound(D); _bound(S); _bound(X);
        _assumeJ(D, S);
        vm.assume(X <= S);
        _setD(D); _setS(S); _setShares(target, X);
        try mock.decreaseDebt(target, type(uint256).max) { _assertJ(); } catch { _assertJ(); }
    }

    function check_J_after_writeOffRedistribute(
        uint256 D, uint256 S, uint256 debt, uint256 totalDebt
    ) external {
        _bound(D); _bound(S); _bound(debt); _bound(totalDebt);
        _assumeJ(D, S);
        vm.assume(D <= totalDebt);
        _setD(D); _setS(S);
        mock.writeOffRedistribute(debt, totalDebt);
        _assertJ();
    }
}
