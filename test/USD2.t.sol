// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import {Test, console} from "forge-std/Test.sol";
import "lib/solmate/src/utils/SignedWadMath.sol";
import {USD2, IChainlinkFeed} from "src/USD2.sol";
import {SUSD2} from "src/SUSD2.sol";
import  "lib/solmate/src/tokens/ERC20.sol";

contract MockCollateral is ERC20 {
    constructor() ERC20("MockCollateral", "MCOLL", 18) {}

    function __mint(address _to, uint _amount) external {
        _mint(_to, _amount);
    }
}

contract MockFeed is IChainlinkFeed {
    function decimals() external pure returns (uint8) {
        return 18;
    }

    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        return (0, 1e18, 1e18, 1e18, 0);
    }
}

contract USD2Wrapper is USD2 {

    constructor(
        address _collateral,
        address _feed,
        address _operator
    ) USD2(_collateral, _feed, _operator) {}

    function _calculateRate(uint _lastRate,
        uint _timeElapsed,
        uint _expRate,
        uint _lastFreeDebtRatioBps,
        uint _targetFreeDebtRatioStartBps,
        uint _targetFreeDebtRatioEndBps) public pure returns (uint currBorrowRate, uint integral) {
        return calculateRate(_lastRate, _timeElapsed, _expRate, _lastFreeDebtRatioBps, _targetFreeDebtRatioStartBps, _targetFreeDebtRatioEndBps);
    }

    function __mint(address _to, uint _amount) external {
        _mint(_to, _amount);
    }

}

contract USD2Test is Test {

    USD2Wrapper usd2;
    address collateral = address(new MockCollateral());
    address feed = address(new MockFeed());
    address operator = address(3);
    address sUSD2;

    function setUp() public {
        usd2 = new USD2Wrapper(collateral, feed, operator);
        sUSD2 = address(new SUSD2(operator, address(usd2)));
    }

    function test_constructor() public view {
        assertEq(usd2.expRate(), uint(wadLn(2*1e18)) / 7 days);
        assertEq(address(usd2.collateral()), collateral);
        assertEq(address(usd2.feed()), feed);
        assertEq(usd2.operator(), operator);
        assertEq(usd2.IMMUTABILITY_DEADLINE(), block.timestamp + 365 days);
        assertNotEq(address(usd2.collateralManager()), address(0));
    }

    function test_initialize() public {
        usd2.initialize(sUSD2);
        assertEq(address(usd2.sUSD2()), sUSD2);
        assertEq(usd2.allowance(address(usd2), sUSD2), type(uint).max);
        vm.expectRevert("USD2: already initialized");
        usd2.initialize(sUSD2);
    }

    function test_burn(uint amount) public {
        // mint
        usd2.__mint(address(this), amount);
        assertEq(usd2.balanceOf(address(this)), amount);
        // burn
        usd2.burn(amount);
        assertEq(usd2.balanceOf(address(this)), 0);
        
        // underflow
        vm.expectRevert();
        usd2.burn(1);
    }

    function test_setOperator() public {
        vm.prank(operator);
        usd2.setOperator(address(1));
        assertEq(usd2.operator(), address(1));
    }

    function test_setOperator_notOperator() public {
        vm.expectRevert("USD2: not operator");
        usd2.setOperator(address(1));
    }

    function test_setHalfLife() public {
        vm.prank(operator);
        usd2.setHalfLife(1 days);
        assertEq(usd2.expRate(), uint(wadLn(2*1e18)) / 1 days);
    }

    function test_setHalfLife_notOperator() public {
        vm.expectRevert("USD2: not operator");
        usd2.setHalfLife(1 days);
        assertEq(usd2.expRate(), uint(wadLn(2*1e18)) / 7 days);
    }

    function test_setHalfLife_invalidHalfLife() public {
        vm.prank(operator);
        vm.expectRevert("USD2: invalid half-life");
        usd2.setHalfLife(0);
        assertEq(usd2.expRate(), uint(wadLn(2*1e18)) / 7 days);
    }

    function test_setHalfLife_afterDeadline() public {
        vm.warp(usd2.IMMUTABILITY_DEADLINE() + 1);
        vm.prank(operator);
        vm.expectRevert("USD2: immutability deadline passed");
        usd2.setHalfLife(1 days);
        assertEq(usd2.expRate(), uint(wadLn(2*1e18)) / 7 days);
    }

    function test_setCollateralFactorBps() public {
        vm.prank(operator);
        usd2.setCollateralFactorBps(5000);
        assertEq(usd2.collateralFactorBps(), 5000);
    }

    function test_setCollateralFactorBps_notOperator() public {
        vm.expectRevert("USD2: not operator");
        usd2.setCollateralFactorBps(5000);
        assertEq(usd2.collateralFactorBps(), 8500);
    }

    function test_setCollateralFactorBps_invalidCollateralFactorBps() public {
        vm.prank(operator);
        vm.expectRevert("USD2: invalid collateral factor");
        usd2.setCollateralFactorBps(10001);
        assertEq(usd2.collateralFactorBps(), 8500);
    }

    function test_setCollateralFactorBps_afterDeadline() public {
        vm.warp(usd2.IMMUTABILITY_DEADLINE() + 1);
        vm.prank(operator);
        vm.expectRevert("USD2: immutability deadline passed");
        usd2.setCollateralFactorBps(5000);
        assertEq(usd2.collateralFactorBps(), 8500);
    }

    function test_setLiqIncentiveBps() public {
        vm.prank(operator);
        usd2.setLiqIncentiveBps(5000);
        assertEq(usd2.liqIncentiveBps(), 5000);
    }

    function test_setLiqIncentiveBps_notOperator() public {
        vm.expectRevert("USD2: not operator");
        usd2.setLiqIncentiveBps(5000);
        assertEq(usd2.liqIncentiveBps(), 1000);
    }

    function test_setLiqIncentiveBps_invalidLiqIncentiveBps() public {
        vm.prank(operator);
        vm.expectRevert("USD2: invalid liquidation incentive");
        usd2.setLiqIncentiveBps(10001);
        assertEq(usd2.liqIncentiveBps(), 1000);
    }

    function test_setLiqIncentiveBps_afterDeadline() public {
        vm.warp(usd2.IMMUTABILITY_DEADLINE() + 1);
        vm.prank(operator);
        vm.expectRevert("USD2: immutability deadline passed");
        usd2.setLiqIncentiveBps(5000);
        assertEq(usd2.liqIncentiveBps(), 1000);
    }

    function test_setTargetFreeDebtRatioRangeBps() public {
        vm.prank(operator);
        usd2.setTargetFreeDebtRatioRangeBps(0, 10000);
        assertEq(usd2.targetFreeDebtRatioStartBps(), 0);
        assertEq(usd2.targetFreeDebtRatioEndBps(), 10000);
    }

    function test_setTargetFreeDebtRatioRangeBps_notOperator() public {
        vm.expectRevert("USD2: not operator");
        usd2.setTargetFreeDebtRatioRangeBps(0, 10000);
        assertEq(usd2.targetFreeDebtRatioStartBps(), 2000);
        assertEq(usd2.targetFreeDebtRatioEndBps(), 4000);
    }

    function test_setTargetFreeDebtRatioRangeBps_invalidStartBps() public {
        vm.prank(operator);
        vm.expectRevert("USD2: invalid target free debt ratio range");
        usd2.setTargetFreeDebtRatioRangeBps(10001, 10000);
        assertEq(usd2.targetFreeDebtRatioStartBps(), 2000);
        assertEq(usd2.targetFreeDebtRatioEndBps(), 4000);
    }

    function test_setTargetFreeDebtRatioRangeBps_invalidEndBps() public {
        vm.prank(operator);
        vm.expectRevert("USD2: invalid target free debt ratio range");
        usd2.setTargetFreeDebtRatioRangeBps(0, 10001);
        assertEq(usd2.targetFreeDebtRatioStartBps(), 2000);
        assertEq(usd2.targetFreeDebtRatioEndBps(), 4000);
    }

    function test_setTargetFreeDebtRatioRangeBps_afterDeadline() public {
        vm.warp(usd2.IMMUTABILITY_DEADLINE() + 1);
        vm.prank(operator);
        vm.expectRevert("USD2: immutability deadline passed");
        usd2.setTargetFreeDebtRatioRangeBps(0, 10000);
        assertEq(usd2.targetFreeDebtRatioStartBps(), 2000);
        assertEq(usd2.targetFreeDebtRatioEndBps(), 4000);
    }

    function test_setRedeemFeeBps() public {
        vm.prank(operator);
        usd2.setRedeemFeeBps(5000);
        assertEq(usd2.redeemFeeBps(), 5000);
    }

    function test_setRedeemFeeBps_notOperator() public {
        vm.expectRevert("USD2: not operator");
        usd2.setRedeemFeeBps(5000);
        assertEq(usd2.redeemFeeBps(), 30);
    }

    function test_setRedeemFeeBps_invalidRedeemFeeBps() public {
        vm.prank(operator);
        vm.expectRevert("USD2: invalid redeem fee");
        usd2.setRedeemFeeBps(10001);
        assertEq(usd2.redeemFeeBps(), 30);
    }

    function test_setRedeemFeeBps_afterDeadline() public {
        vm.warp(usd2.IMMUTABILITY_DEADLINE() + 1);
        vm.prank(operator);
        vm.expectRevert("USD2: immutability deadline passed");
        usd2.setRedeemFeeBps(5000);
        assertEq(usd2.redeemFeeBps(), 30);
    }

    function test_addToReserve() public {
        usd2.initialize(sUSD2);
        usd2.__mint(address(this), 1000);
        usd2.approve(address(usd2), 1000);
        usd2.addToReserve(1000);
        assertEq(SUSD2(sUSD2).convertToAssets(SUSD2(sUSD2).balanceOf(address(usd2))), 1000);
    }

    function test_removeFromReserve() public {
        test_addToReserve();
        vm.prank(operator);
        usd2.removeFromReserve(1000);
        assertEq(SUSD2(sUSD2).convertToAssets(SUSD2(sUSD2).balanceOf(address(usd2))), 0);
        assertEq(usd2.balanceOf(operator), 1000);
    }

    function test_removeFromReserve_notOperator() public {
        test_addToReserve();
        vm.expectRevert("USD2: not operator");
        usd2.removeFromReserve(1000);
    }

    function test_adjust_depositCollateral() public {
        usd2.initialize(sUSD2);
        MockCollateral(collateral).__mint(address(this), 1000);
        MockCollateral(collateral).approve(address(usd2), 1000);
        usd2.adjust(address(this), 1000, 0);
        assertEq(usd2.collateralManager().collateralOf(address(this)), 1000);
        assertEq(MockCollateral(collateral).balanceOf(address(this)), 0);
        assertEq(MockCollateral(collateral).balanceOf(address(usd2.collateralManager())), 1000);
    }

    function test_adjust_depositCollateral_isRedeemable() public {
        usd2.initialize(sUSD2);
        MockCollateral(collateral).__mint(address(this), 1000);
        MockCollateral(collateral).approve(address(usd2), 1000);
        usd2.optInRedemptions(address(this));
        usd2.adjust(address(this), 1000, 0);
        assertEq(usd2.collateralManager().collateralOf(address(this)), 1000);
        assertEq(MockCollateral(collateral).balanceOf(address(this)), 0);
        assertEq(MockCollateral(collateral).balanceOf(address(usd2.collateralManager())), 1000);
    }

    function test_adjust_depositCollateral_onBehalf() public {
        usd2.initialize(sUSD2);
        MockCollateral(collateral).__mint(address(this), 1000);
        MockCollateral(collateral).approve(address(usd2), 1000);
        usd2.adjust(address(1), 1000, 0);
        assertEq(usd2.collateralManager().collateralOf(address(1)), 1000);
        assertEq(MockCollateral(collateral).balanceOf(address(this)), 0);
        assertEq(MockCollateral(collateral).balanceOf(address(usd2.collateralManager())), 1000);
    }

    function test_adjust_withdrawCollateral() public {
        test_adjust_depositCollateral();
        usd2.adjust(address(this), -1000, 0);
        assertEq(usd2.collateralManager().collateralOf(address(this)), 0);
        assertEq(MockCollateral(collateral).balanceOf(address(this)), 1000);
        assertEq(MockCollateral(collateral).balanceOf(address(usd2.collateralManager())), 0);
    }

    function test_adjust_withdrawCollateral_notEnoughCollateral() public {
        test_adjust_depositCollateral();
        vm.expectRevert();
        usd2.adjust(address(this), -1001, 0);
    }

    function test_adjust_withdrawCollateral_isRedeemable() public {
        test_adjust_depositCollateral_isRedeemable();
        usd2.adjust(address(this), -1000, 0);
        assertEq(usd2.collateralManager().collateralOf(address(this)), 0);
        assertEq(MockCollateral(collateral).balanceOf(address(this)), 1000);
        assertEq(MockCollateral(collateral).balanceOf(address(usd2.collateralManager())), 0);
    }

    function test_adjust_withdrawCollateral_notEnoughCollateral_isRedeemable() public {
        test_adjust_depositCollateral_isRedeemable();
        vm.expectRevert();
        usd2.adjust(address(this), -1001, 0);
    }

    function test_adjust_withdrawCollateral_onBehalf() public {
        test_adjust_depositCollateral();
        usd2.delegate(address(1), true);
        vm.prank(address(1));
        usd2.adjust(address(this), -1000, 0);
        assertEq(usd2.collateralManager().collateralOf(address(this)), 0);
        assertEq(MockCollateral(collateral).balanceOf(address(1)), 1000); // delegate receives collateral
        assertEq(MockCollateral(collateral).balanceOf(address(usd2.collateralManager())), 0);
    }

    function test_adjust_withdrawCollateral_onBehalf_notDelegate() public {
        test_adjust_depositCollateral();
        vm.startPrank(address(1));
        vm.expectRevert("USD2: not authorized");
        usd2.adjust(address(this), -1000, 0);
    }

    function test_adjust_borrow() public {
        test_adjust_depositCollateral(); // 1000 collateral, $1 each
        usd2.adjust(address(this), 0, 850); // 85% collateral factor
        assertEq(usd2.balanceOf(address(this)), 850);
        assertEq(usd2.getDebtOf(address(this)), 850);
    }

    function test_adjust_borrow_isRedeemable() public {
        test_adjust_depositCollateral_isRedeemable(); // 1000 collateral, $1 each
        usd2.adjust(address(this), 0, 850); // 85% collateral factor
        assertEq(usd2.balanceOf(address(this)), 850);
        assertEq(usd2.getDebtOf(address(this)), 850);
    }

    function test_adjust_borrow_onBehalf() public {
        test_adjust_depositCollateral(); // 1000 collateral, $1 each
        usd2.delegate(address(1), true);
        vm.prank(address(1));
        usd2.adjust(address(this), 0, 850); // 85% collateral factor
        assertEq(usd2.balanceOf(address(1)), 850); // delegate receives loan
        assertEq(usd2.getDebtOf(address(this)), 850); // account takes debt
    }

    function test_adjust_borrow_onBehalf_notDelegate() public {
        test_adjust_depositCollateral(); // 1000 collateral, $1 each
        vm.startPrank(address(1));
        vm.expectRevert("USD2: not authorized");
        usd2.adjust(address(this), 0, 850);
    }

    function test_adjust_borrow_unsafe() public {
        test_adjust_depositCollateral(); // 1000 collateral, $1 each
        vm.expectRevert("USD2: unsafe position");
        usd2.adjust(address(this), 0, 851); // 85.1% collateral factor
    }

    function test_adjust_borrow_unsafe_onBehalf() public {
        test_adjust_depositCollateral(); // 1000 collateral, $1 each
        usd2.delegate(address(1), true);
        vm.startPrank(address(1));
        vm.expectRevert("USD2: unsafe position");
        usd2.adjust(address(this), 0, 851); // 85.1% collateral factor
    }

    function test_adjust_borrow_repeat() public {
        test_adjust_borrow();
        vm.expectRevert("USD2: unsafe position");
        usd2.adjust(address(this), 0, 1); // second loan is unsafe
    }

    function test_adjust_repay() public {
        test_adjust_borrow();
        usd2.adjust(address(this), 0, -850);
        assertEq(usd2.balanceOf(address(this)), 0);
        assertEq(usd2.getDebtOf(address(this)), 0);
    }

    function test_adjust_repay_onBehalf() public {
        test_adjust_borrow();
        usd2.transfer(address(1), 850);
        vm.prank(address(1));
        usd2.adjust(address(this), 0, -850);
        assertEq(usd2.getDebtOf(address(this)), 0);
        assertEq(usd2.balanceOf(address(1)), 0);
    }

    function test_adjust_repay_isRedeemable() public {
        test_adjust_borrow_isRedeemable();
        usd2.adjust(address(this), 0, -850);
        assertEq(usd2.balanceOf(address(this)), 0);
        assertEq(usd2.getDebtOf(address(this)), 0);
    }

    function test_adjust_repay_notEnoughDebt() public {
        test_adjust_borrow();
        vm.expectRevert();
        usd2.adjust(address(this), 0, -851);
    }

    function test_adjust_repay_all() public {
        test_adjust_borrow();
        usd2.adjust(address(this), 0, type(int256).min);
        assertEq(usd2.balanceOf(address(this)), 0);
        assertEq(usd2.getDebtOf(address(this)), 0);
    }

    function test_adjust_repay_all_onBehalf() public {
        test_adjust_borrow();
        usd2.transfer(address(1), 850);
        vm.prank(address(1));
        usd2.adjust(address(this), 0, type(int256).min);
        assertEq(usd2.getDebtOf(address(this)), 0);
        assertEq(usd2.balanceOf(address(1)), 0);
    }

    function test_calculateRate_growth() public view {
        uint lastRate = 1e16;
        uint timeElapsed = 7 days;
        uint expRate = usd2.expRate();
        uint lastFreeDebtRatioBps = 0;
        uint targetFreeDebtRatioStartBps = usd2.targetFreeDebtRatioStartBps();
        uint targetFreeDebtRatioEndBps = usd2.targetFreeDebtRatioEndBps();
        (uint currBorrowRate, uint integral) = usd2._calculateRate(
            lastRate,
            timeElapsed,
            expRate,
            lastFreeDebtRatioBps,
            targetFreeDebtRatioStartBps,
            targetFreeDebtRatioEndBps
        );
        uint expectedRate = lastRate;
        uint expectedIntegral = 0;
        for(uint i = 0; i < timeElapsed; i++) {
            uint growthDecay = uint(wadExp(int(expRate)));
            expectedRate = expectedRate * growthDecay / 1e18;
            expectedIntegral += expectedRate;
        }
        assertApproxEqAbs(currBorrowRate, expectedRate, 1e8);
        assertApproxEqAbs(integral, expectedIntegral, 1e16);
    }

    function test_calculateRate_decay() public view {
        uint lastRate = 1e16;
        uint timeElapsed = 7 days;
        uint expRate = usd2.expRate();
        uint lastFreeDebtRatioBps = 10000;
        uint targetFreeDebtRatioStartBps = usd2.targetFreeDebtRatioStartBps();
        uint targetFreeDebtRatioEndBps = usd2.targetFreeDebtRatioEndBps();
        (uint currBorrowRate, uint integral) = usd2._calculateRate(
            lastRate,
            timeElapsed,
            expRate,
            lastFreeDebtRatioBps,
            targetFreeDebtRatioStartBps,
            targetFreeDebtRatioEndBps
        );
        uint expectedRate = lastRate;
        uint expectedIntegral = 0;
        for(uint i = 0; i < timeElapsed; i++) {
            uint growthDecay = uint(wadExp(int(expRate)));
            expectedRate = expectedRate * 1e18 / growthDecay;
            expectedIntegral += expectedRate;
        }
        assertApproxEqAbs(currBorrowRate, expectedRate, 1e8);
        assertApproxEqAbs(integral, expectedIntegral, 1e16);
    }

    function test_calculateRate_decay_minRate_to_minRate() public view {
        uint minRate = 5e15;
        uint lastRate = minRate;
        uint timeElapsed = 7 days;
        uint expRate = usd2.expRate();
        uint lastFreeDebtRatioBps = 10000;
        uint targetFreeDebtRatioStartBps = usd2.targetFreeDebtRatioStartBps();
        uint targetFreeDebtRatioEndBps = usd2.targetFreeDebtRatioEndBps();
        (uint currBorrowRate, uint integral) = usd2._calculateRate(
            lastRate,
            timeElapsed,
            expRate,
            lastFreeDebtRatioBps,
            targetFreeDebtRatioStartBps,
            targetFreeDebtRatioEndBps
        );
        assertEq(currBorrowRate, minRate);
        assertEq(integral, minRate * timeElapsed);
    }

    function test_calculateRate_decay_to_minRate() public view {
        uint minRate = 5e15;
        uint lastRate = 1e15;
        uint timeElapsed = 7 days;
        uint expRate = usd2.expRate();
        uint lastFreeDebtRatioBps = 10000;
        uint targetFreeDebtRatioStartBps = usd2.targetFreeDebtRatioStartBps();
        uint targetFreeDebtRatioEndBps = usd2.targetFreeDebtRatioEndBps();
        (uint currBorrowRate, uint integral) = usd2._calculateRate(
            lastRate,
            timeElapsed,
            expRate,
            lastFreeDebtRatioBps,
            targetFreeDebtRatioStartBps,
            targetFreeDebtRatioEndBps
        );
        uint expectedRate = lastRate;
        uint expectedIntegral = 0;
        for(uint i = 0; i < timeElapsed; i++) {
            uint growthDecay = uint(wadExp(int(expRate)));
            expectedRate = expectedRate * 1e18 / growthDecay;
            if(expectedRate < minRate) {
                expectedRate = minRate;
            }
            expectedIntegral += expectedRate;
        }
        assertApproxEqAbs(currBorrowRate, expectedRate, 1e8);
        assertApproxEqAbs(integral, expectedIntegral, 1e16);
    }

    function test_calculateRate_unchanged() public view {
        uint lastRate = 1e16;
        uint timeElapsed = 7 days;
        uint expRate = usd2.expRate();
        uint lastFreeDebtRatioBps = usd2.targetFreeDebtRatioStartBps();
        uint targetFreeDebtRatioStartBps = usd2.targetFreeDebtRatioStartBps();
        uint targetFreeDebtRatioEndBps = usd2.targetFreeDebtRatioEndBps();
        (uint currBorrowRate, uint integral) = usd2._calculateRate(
            lastRate,
            timeElapsed,
            expRate,
            lastFreeDebtRatioBps,
            targetFreeDebtRatioStartBps,
            targetFreeDebtRatioEndBps
        );
        uint expectedRate = lastRate;
        uint expectedIntegral = lastRate * timeElapsed;
        assertEq(currBorrowRate, expectedRate);
        assertEq(integral, expectedIntegral);
    }
        

}
