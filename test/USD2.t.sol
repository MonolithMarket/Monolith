// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import {Test, console} from "forge-std/Test.sol";
import "lib/solmate/src/utils/SignedWadMath.sol";
import "lib/solmate/src/utils/CREATE3.sol";
import {USD2, IChainlinkFeed} from "src/USD2.sol";
import {SUSD2} from "src/SUSD2.sol";
import  "lib/solmate/src/tokens/ERC20.sol";
import {CollateralManager} from "src/CollateralManager.sol";

contract MockCollateral is ERC20 {
    constructor() ERC20("MockCollateral", "MCOLL", 18) {}

    function __mint(address _to, uint _amount) external {
        _mint(_to, _amount);
    }
}

contract MockFeed is IChainlinkFeed {

    uint price;

    constructor() {
        price = 1e18;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, int(price), 1e18, 1e18, 0);
    }

    function __setPrice(uint _price) external {
        price = _price;
    }
}

contract USD2Wrapper is USD2 {

    constructor(
        string memory _name,
        string memory _symbol,
        address _sUSD2,
        address _collateral,
        address _feed,
        address _factory,
        address _operator
    ) USD2(_name, _symbol, _sUSD2, _collateral, _feed, _factory, _operator, 9000) {}

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
    CollateralManager collateralManager;

    function setUp() public {
        usd2 = USD2Wrapper(CREATE3.getDeployed(keccak256("USD2")));
        sUSD2 = CREATE3.getDeployed(keccak256("SUSD2"));
        CREATE3.deploy(
            keccak256("USD2"),
            abi.encodePacked(type(USD2Wrapper).creationCode, abi.encode("TestUSD", "TUSD", sUSD2, collateral, feed, address(this), operator, 9000)),
            0
        );
        CREATE3.deploy(
            keccak256("SUSD2"),
            abi.encodePacked(type(SUSD2).creationCode, abi.encode("Staked TestUSD", "sUSD2", address(usd2))),
            0
        );
        // just to show collateralManager on the forge debugger source maps
        collateralManager = usd2.collateralManager();
    }

    // mocks the feeBps() function in the factory
    function feeBps() public pure returns (uint) {
        return 0;
    }

    function test_constructor() public view {
        assertEq(usd2.factory(), address(this), "factory");
        assertEq(usd2.expRate(), uint(wadLn(2*1e18)) / 7 days, "expRate");
        assertEq(address(usd2.collateral()), collateral, "collateral");
        assertEq(address(usd2.feed()), feed, "feed");
        assertEq(usd2.operator(), operator, "operator");
        assertEq(usd2.IMMUTABILITY_DEADLINE(), block.timestamp + 365 days, "IMMUTABILITY_DEADLINE");
        assertNotEq(address(usd2.collateralManager()), address(0), "collateralManager");
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

    function test_setTargetFreeDebtRatioRangeBps() public {
        vm.prank(operator);
        usd2.setTargetFreeDebtRatioRangeBps(500, 9500);
        assertEq(usd2.targetFreeDebtRatioStartBps(), 500);
        assertEq(usd2.targetFreeDebtRatioEndBps(), 9500);
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
        usd2.setRedeemFeeBps(100);
        assertEq(usd2.redeemFeeBps(), 100);
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

    function test_adjust_depositCollateral() public {
        MockCollateral(collateral).__mint(address(this), 1000);
        MockCollateral(collateral).approve(address(usd2), 1000);
        usd2.adjust(address(this), 1000, 0);
        assertEq(usd2.collateralManager().collateralOf(address(this)), 1000);
        assertEq(MockCollateral(collateral).balanceOf(address(this)), 0);
        assertEq(MockCollateral(collateral).balanceOf(address(usd2.collateralManager())), 1000);
    }

    function test_adjust_depositCollateral_isRedeemable() public {
        MockCollateral(collateral).__mint(address(this), 1000);
        MockCollateral(collateral).approve(address(usd2), 1000);
        usd2.optInRedemptions(address(this));
        usd2.adjust(address(this), 1000, 0);
        assertEq(usd2.collateralManager().collateralOf(address(this)), 1000);
        assertEq(MockCollateral(collateral).balanceOf(address(this)), 0);
        assertEq(MockCollateral(collateral).balanceOf(address(usd2.collateralManager())), 1000);
    }

    function test_adjust_depositCollateral_onBehalf() public {
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
        usd2.adjust(address(this), 0, 900); // 90% collateral factor
        assertEq(usd2.balanceOf(address(this)), 900);
        assertEq(usd2.getDebtOf(address(this)), 900);
    }

    function test_adjust_borrow_isRedeemable() public {
        test_adjust_depositCollateral_isRedeemable(); // 1000 collateral, $1 each
        usd2.adjust(address(this), 0, 900); // 90% collateral factor
        assertEq(usd2.balanceOf(address(this)), 900);
        assertEq(usd2.getDebtOf(address(this)), 900);
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
        usd2.adjust(address(this), 0, 901); // 90.1% collateral factor
    }

    function test_adjust_borrow_unsafe_onBehalf() public {
        test_adjust_depositCollateral(); // 1000 collateral, $1 each
        usd2.delegate(address(1), true);
        vm.startPrank(address(1));
        vm.expectRevert("USD2: unsafe position");
        usd2.adjust(address(this), 0, 901); // 90.1% collateral factor
    }

    function test_adjust_borrow_repeat() public {
        test_adjust_borrow();
        vm.expectRevert("USD2: unsafe position");
        usd2.adjust(address(this), 0, 1); // second loan is unsafe
    }

    function test_adjust_repay() public {
        test_adjust_borrow();
        usd2.adjust(address(this), 0, -900);
        assertEq(usd2.balanceOf(address(this)), 0);
        assertEq(usd2.getDebtOf(address(this)), 0);
    }

    function test_adjust_repay_onBehalf() public {
        test_adjust_borrow();
        usd2.transfer(address(1), 900);
        vm.prank(address(1));
        usd2.adjust(address(this), 0, -900);
        assertEq(usd2.getDebtOf(address(this)), 0);
        assertEq(usd2.balanceOf(address(1)), 0);
    }

    function test_adjust_repay_isRedeemable() public {
        test_adjust_borrow_isRedeemable();
        usd2.adjust(address(this), 0, -900);
        assertEq(usd2.balanceOf(address(this)), 0);
        assertEq(usd2.getDebtOf(address(this)), 0);
    }

    function test_adjust_repay_notEnoughDebt() public {
        test_adjust_borrow();
        vm.expectRevert();
        usd2.adjust(address(this), 0, -901);
    }

    function test_adjust_repay_all() public {
        test_adjust_borrow();
        usd2.adjust(address(this), 0, type(int256).min);
        assertEq(usd2.balanceOf(address(this)), 0);
        assertEq(usd2.getDebtOf(address(this)), 0);
    }

    function test_adjust_repay_all_onBehalf() public {
        test_adjust_borrow();
        usd2.transfer(address(1), 900);
        vm.prank(address(1));
        usd2.adjust(address(this), 0, type(int256).min);
        assertEq(usd2.getDebtOf(address(this)), 0);
        assertEq(usd2.balanceOf(address(1)), 0);
    }

    function test_redeem() public {
        uint collateralAmount = 10000;
        uint loan = 8500;
        uint redeemAmount = 1000;
        uint minAmountOut = 997;
        address BORROWER = address(this);
        address REDEEMER = address(1);
        MockCollateral(collateral).__mint(BORROWER, collateralAmount);
        MockCollateral(collateral).approve(address(usd2), collateralAmount);
        usd2.optInRedemptions(address(this));
        // deposit 10000, borrow 8500
        usd2.adjust(BORROWER, int(collateralAmount), int(loan));
        assertEq(usd2.totalFreeDebt(), loan);
        // redeem
        usd2.transfer(REDEEMER, redeemAmount);
        vm.prank(REDEEMER);
        usd2.redeem(redeemAmount, minAmountOut);
        assertEq(usd2.balanceOf(REDEEMER), 0); // redeemeer's entire balance is redeemed
        assertEq(usd2.getDebtOf(BORROWER), loan - redeemAmount); // borrower's debt decreases by redeem amount
        assertEq(usd2.collateralManager().collateralOf(BORROWER), collateralAmount - minAmountOut); // collateral decreases by minAmountOut
        assertEq(usd2.totalFreeDebt(), loan - redeemAmount);
        assertEq(usd2.totalSupply(), loan - redeemAmount);
    }

    function test_redeem_InsufficientAmountOut() public {
        uint collateralAmount = 10000;
        uint loan = 8500;
        uint redeemAmount = 1000;
        uint minAmountOut = 998; // in this case, minAmountOut is too high
        address BORROWER = address(this);
        address REDEEMER = address(1);
        MockCollateral(collateral).__mint(BORROWER, collateralAmount);
        MockCollateral(collateral).approve(address(usd2), collateralAmount);
        usd2.optInRedemptions(address(this));
        // deposit 10000, borrow 8500
        usd2.adjust(BORROWER, int(collateralAmount), int(loan));
        assertEq(usd2.totalFreeDebt(), loan);
        // redeem
        usd2.transfer(REDEEMER, redeemAmount);
        vm.startPrank(REDEEMER);
        vm.expectRevert("USD2: insufficient amount out");
        usd2.redeem(redeemAmount, minAmountOut);
    }

    function test_redeem_nonRedeemable() public {
        uint collateralAmount = 10000;
        uint loan = 8500;
        address BORROWER = address(this);
        address REDEEMER = address(1);
        MockCollateral(collateral).__mint(BORROWER, collateralAmount);
        MockCollateral(collateral).approve(address(usd2), collateralAmount);
        // redeemer is not opted in, there's no redeemable collateral
        // usd2.optInRedemptions(address(this));
        // deposit 10000, borrow 8500
        usd2.adjust(BORROWER, int(collateralAmount), int(loan));
        assertEq(usd2.totalFreeDebt(), 0);
        // redeem
        usd2.transfer(REDEEMER, loan);
        vm.startPrank(REDEEMER);
        vm.expectRevert("USD2: insufficient amount out");
        usd2.redeem(1, 1);
    }

    function test_writeOff() public {
        // first borrower is redeemable
        address REDEEMABLE_BORROWER = address(11);
        vm.startPrank(REDEEMABLE_BORROWER);
        MockCollateral(collateral).__mint(REDEEMABLE_BORROWER, 1000e18);
        usd2.optInRedemptions(REDEEMABLE_BORROWER);
        MockCollateral(collateral).approve(address(usd2), 1000e18);
        usd2.adjust(REDEEMABLE_BORROWER, 1000e18, 850e18);
        // second borrower is non-redeemable
        address NON_REDEEMABLE_BORROWER = address(12);
        vm.startPrank(NON_REDEEMABLE_BORROWER);
        MockCollateral(collateral).__mint(NON_REDEEMABLE_BORROWER, 1000e18);
        MockCollateral(collateral).approve(address(usd2), 1000e18);
        usd2.adjust(NON_REDEEMABLE_BORROWER, 1000e18, 850e18);
        // third borrower will be written off, he's non-redeemable btw
        address WRITTEN_OFF_BORROWER = address(this);
        vm.startPrank(WRITTEN_OFF_BORROWER);
        MockCollateral(collateral).__mint(WRITTEN_OFF_BORROWER, 1000e18);
        MockCollateral(collateral).approve(address(usd2), 1000e18);
        // deposit $1000, borrow $850 (both tokens are worth $1 each)
        usd2.adjust(WRITTEN_OFF_BORROWER, 1000e18, 850e18);
        // reduce collateral price to just under $0.5
        MockFeed(feed).__setPrice(0.5e18);
        uint prevFreeDebt = usd2.totalFreeDebt();
        uint prevPaidDebt = usd2.totalPaidDebt();
        usd2.writeOff(WRITTEN_OFF_BORROWER);
        // assert written off borrower's debt is equal to his collateral value
        // at $0.5 price per collateral, 1000 collateral is worth $500. $350 of debt needs to go.
        assertApproxEqAbs(usd2.getDebtOf(WRITTEN_OFF_BORROWER), 500e18, 1);
        // collateral remains unchanged
        assertEq(usd2.collateralManager().collateralOf(WRITTEN_OFF_BORROWER), 1000e18);
        // assert other borrowers receive 350 of the written off borrower's debt (850 - 500)
        assertEq(usd2.getDebtOf(REDEEMABLE_BORROWER), 850e18 + (350e18 / 2));
        assertEq(usd2.getDebtOf(NON_REDEEMABLE_BORROWER), 850e18 + (350e18 / 2));
        // assert total debt is unchanged
        assertEq(usd2.totalFreeDebt() + usd2.totalPaidDebt(), prevFreeDebt + prevPaidDebt);
    }

    function test_writeOff_safePosition() public {
        address WRITTEN_OFF_BORROWER = address(this);
        vm.startPrank(WRITTEN_OFF_BORROWER);
        MockCollateral(collateral).__mint(WRITTEN_OFF_BORROWER, 1000);
        MockCollateral(collateral).approve(address(usd2), 1000);
        usd2.adjust(WRITTEN_OFF_BORROWER, 1000, 850);
        usd2.writeOff(WRITTEN_OFF_BORROWER);
        // assert written off borrower's debt and collateral are the same as before
        assertEq(usd2.getDebtOf(WRITTEN_OFF_BORROWER), 850);
        assertEq(usd2.collateralManager().collateralOf(WRITTEN_OFF_BORROWER), 1000);
    }

    function test_getRedeemAmountOut() public {
        uint collateralAmount = 2e18;
        uint loanAmount = 1e18;
        MockCollateral(collateral).__mint(address(this), collateralAmount);
        MockCollateral(collateral).approve(address(usd2), collateralAmount);
        usd2.optInRedemptions(address(this));
        usd2.adjust(address(this), int(collateralAmount), int(loanAmount));
        uint amountIn = 1e18;
        uint redeemFeeBps = 30;
        uint expectedAmountOut = 1e18 * (10000 - redeemFeeBps) / 10000;
        assertEq(usd2.getRedeemAmountOut(amountIn), expectedAmountOut);
    }

    function test_getRedeemAmountOut_insufficientFreeDebt() public {
        uint collateralAmount = 2e18;
        uint loanAmount = 1e18;
        MockCollateral(collateral).__mint(address(this), collateralAmount);
        MockCollateral(collateral).approve(address(usd2), collateralAmount);
        usd2.optInRedemptions(address(this));
        usd2.adjust(address(this), int(collateralAmount), int(loanAmount));
        assertEq(usd2.getRedeemAmountOut(1e18 + 1), 0);
    }

    function test_calculateRate_growth() public view {
        uint lastRate = 1e16;
        uint timeElapsed = 100;
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
        uint initialDebt = 1e18;
        uint expectedRate = lastRate;
        uint expectedIntegral = 0;
        uint expectedDebt = initialDebt;
        for(uint i = 0; i < timeElapsed; i++) {
            uint growthDecay = uint(wadExp(int(expRate)));
            expectedRate = expectedRate * growthDecay / 1e18;
            expectedIntegral += expectedRate / 365 days;
            expectedDebt += expectedDebt * expectedRate / 1e18 / 365 days;
        }
        assertApproxEqAbs(currBorrowRate, expectedRate, 1e8);
        assertApproxEqAbs(integral, expectedIntegral, 1e16);
        assertApproxEqAbs(expectedDebt, initialDebt + initialDebt * integral / 1e18, 1e16);
    }

    function test_calculateRate_decay() public view {
        uint lastRate = 1e16;
        uint timeElapsed = 100;
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
        uint initialDebt = 1e18;
        uint expectedRate = lastRate;
        uint expectedIntegral = 0;
        uint expectedDebt = initialDebt;
        for(uint i = 0; i < timeElapsed; i++) {
            uint growthDecay = uint(wadExp(int(expRate)));
            expectedRate = expectedRate * 1e18 / growthDecay;
            expectedIntegral += expectedRate / 365 days;
            expectedDebt += expectedDebt * expectedRate / 1e18 / 365 days;
        }
        assertApproxEqAbs(currBorrowRate, expectedRate, 1e8);
        assertApproxEqAbs(integral, expectedIntegral, 1e16);
        assertApproxEqAbs(expectedDebt, initialDebt + initialDebt * integral / 1e18, 1e16);
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
        uint initialDebt = 1e18;
        uint expectedDebt = initialDebt + initialDebt * minRate * timeElapsed / 1e18 / 365 days;
        assertEq(currBorrowRate, minRate);
        assertEq(integral, minRate * timeElapsed / 365 days);
        assertApproxEqAbs(expectedDebt, initialDebt + initialDebt * integral / 1e18, 1e16);
    }

    function test_calculateRate_decay_to_minRate() public view {
        uint minRate = 5e15;
        uint lastRate = 1e15;
        uint timeElapsed = 100;
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
        uint initialDebt = 1e18;
        uint expectedRate = lastRate;
        uint expectedIntegral = 0;
        uint expectedDebt = initialDebt;
        for(uint i = 0; i < timeElapsed; i++) {
            uint growthDecay = uint(wadExp(int(expRate)));
            expectedRate = expectedRate * 1e18 / growthDecay;
            if(expectedRate < minRate) {
                expectedRate = minRate;
            }
            expectedIntegral += expectedRate / 365 days;
            expectedDebt += expectedDebt * expectedRate / 1e18 / 365 days;
        }
        assertApproxEqAbs(currBorrowRate, expectedRate, 1e8);
        assertApproxEqAbs(integral, expectedIntegral, 1e16);
        assertApproxEqAbs(expectedDebt, initialDebt + initialDebt * integral / 1e18, 1e16);
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
        uint initialDebt = 1e18;
        uint expectedRate = lastRate;
        uint expectedIntegral = lastRate * timeElapsed / 365 days;
        uint expectedDebt = initialDebt + initialDebt * lastRate * timeElapsed / 1e18 / 365 days;
        assertEq(currBorrowRate, expectedRate);
        assertEq(integral, expectedIntegral);
        assertEq(expectedDebt, initialDebt + initialDebt * integral / 1e18);
    }

    function test_liquidate() public {
        address BORROWER = address(this);
        address LIQUIDATOR = address(1);

        // Deposit collateral and borrow
        uint collateralAmount = 1000e18;
        uint borrowAmount = 900e18;
        MockCollateral(collateral).__mint(BORROWER, collateralAmount);
        MockCollateral(collateral).approve(address(usd2), collateralAmount);
        usd2.adjust(BORROWER, int(collateralAmount), int(borrowAmount));

        // Lower collateral price to make position undercollateralized
        MockFeed(feed).__setPrice(0.5e18);

        // Get liquidatable debt
        uint liquidatableDebt = usd2.getLiquidatableDebt(BORROWER);
        assertEq(liquidatableDebt, borrowAmount, "Entire debt should be liquidatable");

        // Fund liquidator and approve
        usd2.__mint(LIQUIDATOR, liquidatableDebt);
        vm.startPrank(LIQUIDATOR);
        usd2.approve(address(usd2), liquidatableDebt);

        // Execute liquidation
        uint collateralOut = usd2.liquidate(BORROWER, liquidatableDebt, 0);

        // Verify state changes
        assertEq(usd2.getDebtOf(BORROWER), 0, "Debt should be fully repaid");
        assertEq(collateralOut, collateralAmount, "Liquidator should receive all collateral");
        assertEq(MockCollateral(collateral).balanceOf(LIQUIDATOR), collateralOut, "Collateral transferred");
        assertEq(usd2.balanceOf(LIQUIDATOR), 0, "USD2 should be burned");
    }
}
