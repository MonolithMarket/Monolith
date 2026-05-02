// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockLenderFreeDebt} from "src/MockLenderFreeDebt.sol";

/// @title  Kontrol symbolic-execution proofs (KEVM bytecode-level)
/// @notice Same single-step inductive proofs as MockLenderHalmos.t.sol but
///         shaped for Kontrol. Functions named `prove_*` so kontrol picks
///         them up by default. Bodies are byte-for-byte identical to the
///         Halmos versions.
contract MockLenderKontrolTest is Test {
    MockLenderFreeDebt mock;
    address constant target = address(0xA);

    function setUp() public { mock = new MockLenderFreeDebt(); }

    function _setD(uint256 v) internal { vm.store(address(mock), bytes32(uint256(0)), bytes32(v)); }
    function _setS(uint256 v) internal { vm.store(address(mock), bytes32(uint256(1)), bytes32(v)); }
    function _setShares(address u, uint256 v) internal {
        vm.store(address(mock), keccak256(abi.encode(u, uint256(2))), bytes32(v));
    }

    uint256 constant CAP = 2 ** 64;
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

    // PART 1: I := D = 0 ⇒ S = 0
    function prove_I_after_increaseDebt(uint256 D, uint256 S, uint256 X, uint256 amount) external {
        _bound(D); _bound(S); _bound(X); _bound(amount);
        _assumeI(D, S);
        vm.assume(X <= S);
        _setD(D); _setS(S); _setShares(target, X);
        mock.increaseDebt(target, amount);
        _assertI();
    }

    function prove_I_after_decreaseDebt_nonmax(uint256 D, uint256 S, uint256 X, uint256 amount) external {
        _bound(D); _bound(S); _bound(X); _bound(amount);
        _assumeI(D, S);
        vm.assume(X <= S);
        vm.assume(D > 0);
        vm.assume(amount != type(uint256).max);
        _setD(D); _setS(S); _setShares(target, X);
        try mock.decreaseDebt(target, amount) { _assertI(); } catch { _assertI(); }
    }

    function prove_I_after_decreaseDebt_max(uint256 D, uint256 S, uint256 X) external {
        _bound(D); _bound(S); _bound(X);
        _assumeI(D, S);
        vm.assume(X <= S);
        _setD(D); _setS(S); _setShares(target, X);
        try mock.decreaseDebt(target, type(uint256).max) { _assertI(); } catch { _assertI(); }
    }

    function prove_I_after_writeOffRedistribute(
        uint256 D, uint256 S, uint256 debt, uint256 totalDebt
    ) external {
        _bound(D); _bound(S); _bound(debt); _bound(totalDebt);
        _assumeI(D, S);
        vm.assume(D <= totalDebt);
        _setD(D); _setS(S);
        mock.writeOffRedistribute(debt, totalDebt);
        _assertI();
    }

    // PART 2: J := D ≥ S
    function prove_J_after_increaseDebt(uint256 D, uint256 S, uint256 X, uint256 amount) external {
        _bound(D); _bound(S); _bound(X); _bound(amount);
        _assumeJ(D, S);
        vm.assume(X <= S);
        _setD(D); _setS(S); _setShares(target, X);
        mock.increaseDebt(target, amount);
        _assertJ();
    }

    function prove_J_after_decreaseDebt_nonmax(uint256 D, uint256 S, uint256 X, uint256 amount) external {
        _bound(D); _bound(S); _bound(X); _bound(amount);
        _assumeJ(D, S);
        vm.assume(X <= S);
        vm.assume(D > 0);
        vm.assume(amount != type(uint256).max);
        _setD(D); _setS(S); _setShares(target, X);
        try mock.decreaseDebt(target, amount) { _assertJ(); } catch { _assertJ(); }
    }

    function prove_J_after_decreaseDebt_max(uint256 D, uint256 S, uint256 X) external {
        _bound(D); _bound(S); _bound(X);
        _assumeJ(D, S);
        vm.assume(X <= S);
        _setD(D); _setS(S); _setShares(target, X);
        try mock.decreaseDebt(target, type(uint256).max) { _assertJ(); } catch { _assertJ(); }
    }

    function prove_J_after_writeOffRedistribute(
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
