// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import {Test, console} from "forge-std/Test.sol";
import  "lib/solmate/src/tokens/ERC20.sol";
import {CollateralManager} from "src/CollateralManager.sol";

contract MockCollateral is ERC20 {
    constructor() ERC20("MockCollateral", "MockCollateral", 18) {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract CollateralManagerTest is Test {

    MockCollateral public collateral;
    CollateralManager public collateralManager;

    function setUp() public {
        collateral = new MockCollateral();
        collateralManager = new CollateralManager(address(collateral));
    }

    function test_constructor() public {
        assertEq(address(collateralManager.asset()), address(collateral));
        assertEq(collateralManager.usd2(), address(this));
    }

    function test_deposit() public {
        collateral.mint(address(address(collateralManager)), 100 ether);
        collateralManager.deposit(address(this));
        assertEq(collateral.balanceOf(address(address(collateralManager))), 100 ether);
        assertEq(collateralManager.totalNonRedeemable(), 100 ether);
        assertEq(collateralManager.totalNonRedeemableShares(), 100 ether);
        assertEq(collateralManager.collateralOf(address(this)), 100 ether);
        assertEq(collateralManager.nonRedeemableShares(address(this)), 100 ether);
    }

    function test_deposit_redeemable() public {
        collateralManager.setRedeemable(address(this), true);
        collateral.mint(address(address(collateralManager)), 100 ether);
        collateralManager.deposit(address(this));
        assertEq(collateral.balanceOf(address(address(collateralManager))), 100 ether);
        assertEq(collateralManager.totalRedeemable(), 100 ether);
        assertEq(collateralManager.totalRedeemableShares(), 100 ether);
        assertEq(collateralManager.collateralOf(address(this)), 100 ether);
        assertEq(collateralManager.redeemableShares(address(this)), 100 ether);
    }

    function test_withdraw() public {
        test_deposit();
        collateralManager.withdraw(100 ether, address(this), address(this));
        assertEq(collateral.balanceOf(address(address(collateralManager))), 0);
        assertEq(collateral.balanceOf(address(this)), 100 ether);
        assertEq(collateralManager.totalNonRedeemable(), 0);
        assertEq(collateralManager.totalNonRedeemableShares(), 0);
        assertEq(collateralManager.collateralOf(address(this)), 0);
        assertEq(collateralManager.nonRedeemableShares(address(this)), 0);
    }

    function test_withdraw_redeemable() public {
        test_deposit_redeemable();
        collateralManager.withdraw(100 ether, address(this), address(this));
        assertEq(collateral.balanceOf(address(address(collateralManager))), 0);
        assertEq(collateral.balanceOf(address(this)), 100 ether);
        assertEq(collateralManager.totalRedeemable(), 0);
        assertEq(collateralManager.totalRedeemableShares(), 0);
        assertEq(collateralManager.collateralOf(address(this)), 0);
        assertEq(collateralManager.redeemableShares(address(this)), 0);
    }

    function test_withdraw_notUSD2() public {
        test_deposit();
        vm.prank(address(0x1));
        vm.expectRevert("Not authorized");
        collateralManager.withdraw(100 ether, address(this), address(this));
    }

    function test_setRedeemable() public {
        test_deposit();
        collateralManager.setRedeemable(address(this), true);
        assertEq(collateralManager.isRedeemable(address(this)), true);
        assertEq(collateralManager.redeemableShares(address(this)), 100 ether);
        assertEq(collateralManager.totalRedeemable(), 100 ether);
        assertEq(collateralManager.totalRedeemableShares(), 100 ether);
        assertEq(collateralManager.nonRedeemableShares(address(this)), 0);
        assertEq(collateralManager.totalNonRedeemable(), 0);
        assertEq(collateralManager.totalNonRedeemableShares(), 0);
        assertEq(collateralManager.collateralOf(address(this)), 100 ether);
        collateralManager.setRedeemable(address(this), false);
        assertEq(collateralManager.isRedeemable(address(this)), false);
        assertEq(collateralManager.redeemableShares(address(this)), 0);
        assertEq(collateralManager.totalRedeemable(), 0);
        assertEq(collateralManager.totalRedeemableShares(), 0);
        assertEq(collateralManager.nonRedeemableShares(address(this)), 100 ether);
        assertEq(collateralManager.totalNonRedeemable(), 100 ether);
        assertEq(collateralManager.totalNonRedeemableShares(), 100 ether);
        assertEq(collateralManager.collateralOf(address(this)), 100 ether);
    }

    function test_setRedeemable_notUSD2() public {
        test_deposit();
        vm.prank(address(0x1));
        vm.expectRevert("Not authorized");
        collateralManager.setRedeemable(address(this), true);
    }

    function test_seize() public {
        test_deposit_redeemable();
        collateralManager.seize(99 ether, address(this));
        assertEq(collateral.balanceOf(address(address(collateralManager))), 1 ether);
        assertEq(collateral.balanceOf(address(this)), 99 ether);
    }

    function test_seize_all() public {
        test_deposit_redeemable();
        vm.expectRevert("Remaining redeemable collateral cannot be zero");
        collateralManager.seize(100 ether, address(this));
    }

    function test_seize_notUSD2() public {
        test_deposit_redeemable();
        vm.prank(address(0x1));
        vm.expectRevert("Not authorized");
        collateralManager.seize(100 ether, address(this));
    }

    function test_shareMerge() public {
        test_deposit_redeemable();
        
        // Seize enough collateral to trigger share merge
        collateralManager.seize(100 ether - 1, address(this));

        // Verify share merge occurred
        assertEq(collateralManager.shareMergeCount(), 1);
        
        // Verify shares were adjusted correctly
        uint256 expectedShares = 100 ether / 1e18; // Original shares divided by 1e18 due to merge
        assertEq(collateralManager.redeemableSharesOf(address(this)), expectedShares);
        
        // Verify total shares were adjusted
        assertEq(collateralManager.totalRedeemableShares(), expectedShares);
    }


}
