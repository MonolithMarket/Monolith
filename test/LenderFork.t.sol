// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test, console, console2} from "forge-std/Test.sol";
import {Lender, ERC20, Coin, Vault, InterestModel, IChainlinkFeed, IFactory} from "src/Lender.sol";
import {ERC4626} from "lib/solmate/src/tokens/ERC4626.sol";
import {Lens} from "src/Lens.sol";

contract FeedMock {

    uint8 public decimals = 18;
    bool public shouldRevert;
    int256 public price = 1e18;  // Default price

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }
    
    function setPrice(int256 _price) external {
        price = _price;
    }

    function latestRoundData() external view returns (
        uint80 /*roundId*/,
        int256 /*answer*/,
        uint256 /*startedAt*/,
        uint256 /*updatedAt*/,
        uint80 /*answeredInRound*/
    ) {
        if (shouldRevert) {
            revert("Feed reverted");
        }
        address(this); // silences pure function warning
        return (0, price, 0, block.timestamp, 0);
    }
}

contract ERC20Mock is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol, 18) {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function burn(uint256 amount) public {
        _burn(msg.sender, amount);
    }
}

contract VaultMock {
    function totalAssets() public view returns (uint256) {
        address(this); // silences pure function warning
        return 1e18;
    }
}
    
contract InterestModelMock {

    bool public shouldRevert;

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function calculateInterest(
        uint _totalPaidDebt,
        uint /*_lastRate*/,
        uint _timeElapsed,
        uint /*_expRate*/,
        uint /*_lastFreeDebtRatioBps*/,
        uint /*_targetFreeDebtRatioStartBps*/,
        uint /*_targetFreeDebtRatioEndBps*/
    ) external view returns (uint currBorrowRate, uint interest) {
        if (shouldRevert) {
            revert("Revert");
        }
        currBorrowRate = 1e18;
        interest = _totalPaidDebt * currBorrowRate * _timeElapsed / 365 days / 1e18;
    }
}

contract FactoryMock {
    uint public fee = 1000; // 10% default fee
    uint public minDebtFloor = 1e15;

    function getFeeOf(address) external view returns (uint) {
        return fee;
    }

    function setFee(uint newFee) external {
        fee = newFee;
    }
}

contract LenderForkTest is Test {

    Lender lender;
    address public operatorAddr;
    Lens lens;
    ERC20 collateral;
    Coin coin;
    function setUp() public {
        string memory url = vm.rpcUrl("mainnet");
        uint mainnetFork = vm.createSelectFork(url);
        lens = new Lens();
        // Get the existing Lender contract address
        address lenderAddress = 0x44AfC35b52dbeBF43e1940D4f12C372446D52D5A;
        Lender deployedLender = Lender(lenderAddress);
        coin = Coin(address(new ERC20Mock("Coin", "COIN")));
        collateral = ERC20(address(deployedLender.collateral()));
       
        // Deploy a new Lender contract with the same immutable variables as the existing contract
        // Note: The existing contract doesn't have a manager, so we use address(0)
        Lender.LenderParams memory forkLenderParams = Lender.LenderParams({
            collateral: deployedLender.collateral(),
            psmAsset: ERC20(address(0)), // optional PSM asset
            psmVault: ERC4626(address(0)), // optional PSM vault
            feed: deployedLender.feed(),
            coin: coin,
            vault: deployedLender.vault(),
            interestModel: deployedLender.interestModel(),
            factory: deployedLender.factory(),
            operator: deployedLender.operator(), // use existing operator
            manager: address(0), // no manager in old contract
            collateralFactor: deployedLender.collateralFactor(),
            minDebt: deployedLender.minDebt(),
            timeUntilImmutability: 365 days, // dummy immutability deadline (this won't matter since we're replacing bytecode)
            halfLife: 7 days,
            targetFreeDebtRatioStartBps: 2000,
            targetFreeDebtRatioEndBps: 4000,
            redeemFeeBps: 30,
            stalenessThreshold: 24 hours,
            maxBorrowDeltaBps: 50,
            psmVaultMinTotalSupply: 1
        });
        vm.mockCall(
            address(deployedLender.factory()),
            abi.encodeWithSelector(IFactory(deployedLender.factory()).minDebtFloor.selector),
            abi.encode(1e15)
        );
        lender = new Lender(forkLenderParams);
    }

    function test_fix_repeated_redemptions_fork_takes_non_redeemable_collateral(uint256 collateralAmount1, uint256 nonRedeemableCollateralAmount) public {
        collateralAmount1 = bound(collateralAmount1, 1_000_000e18, 100_000_000e18);
        nonRedeemableCollateralAmount = bound(nonRedeemableCollateralAmount, 1e18, 500_000e18);
        // Setup: create multiple borrowers with redeemable debt and non-redeemable debt
        uint collateralAmount2 = 5_000_000e18;
        (uint price,,) = lender.getCollateralPrice();
        
        uint borrowAmount1 =  collateralAmount1 * price / 1 ether * 80 / 100; // 80% of collateral amount
        uint borrowAmount2 = 3_000_001e18;
        //uint borrowAmount2 = collateralAmount2 * price / 1 ether * 80 / 100; 
        uint nonRedeemableBorrowAmount = nonRedeemableCollateralAmount * price / 1 ether * 80 / 100; // non-redeemable debt amount
        // Prepare test data
        address borrower1 = address(0xBEEF);
        address borrower2 = address(0xF00D);
        address nonRedeemableBorrower3 = address(0xBEEF2);
        
        // Setup: mint collateral to borrowers and coins to redeemer
        deal(address(collateral), borrower1, collateralAmount1);
        deal(address(collateral), borrower2, collateralAmount2);
        deal(address(collateral), nonRedeemableBorrower3, nonRedeemableCollateralAmount); // give borrower3 enough collateral
        // New deployment of Lender contract
        assertEq(collateral.balanceOf(address(lender)), 0, "NOT ZERO BALANCE");
        
        // Setup: borrower2 creates a redeemable position
        vm.startPrank(borrower2);
        collateral.approve(address(lender), collateralAmount2);
        lender.adjust(borrower2, int256(collateralAmount2), int256(borrowAmount2), true); // opt into redemptions
        vm.stopPrank();
        assertEq(collateral.balanceOf(address(lender)), collateralAmount2, "Collateral balance in lender should be correct after borrower2");
        // Setup: borrower1 creates a redeemable position
        vm.startPrank(borrower1);
        collateral.approve(address(lender), type(uint).max);
        coin.approve(address(lender), type(uint).max);
        lender.adjust(borrower1, int256(collateralAmount1), int256(borrowAmount1), true); // opt into redemptions
        vm.stopPrank();

        // Borrower3 creates a non-redeemable position
        vm.startPrank(nonRedeemableBorrower3);
        collateral.approve(address(lender), nonRedeemableCollateralAmount);
        lender.adjust(nonRedeemableBorrower3, int256(nonRedeemableCollateralAmount), int256(nonRedeemableBorrowAmount), false); // non-redeemable debt
        vm.stopPrank();
        assertEq(collateral.balanceOf(address(lender)), collateralAmount2 + collateralAmount1 + nonRedeemableCollateralAmount, "Collateral balance in lender should be correct");
        
        for(uint i; i < 50; i++){
            vm.startPrank(borrower1);
            lender.adjust(borrower1, int256(collateral.balanceOf(borrower1)), 0);
            (uint currentPrice,,) = lender.getCollateralPrice();
            uint borrowingPower = currentPrice * lender.collateralBalances(borrower1) * (lender.collateralFactor()-100) / 1e18 / 10000 - lender.getDebtOf(borrower1);
            lender.adjust(borrower1, 0, int256(borrowingPower));
            uint maxRedeem = collateral.balanceOf(address(lender)) * currentPrice * 10000 / 1e18 / (10000 - lender.redeemFeeBps());
            uint balance = coin.balanceOf(borrower1);
            uint redeemAmount = balance > maxRedeem ? maxRedeem : balance;
            lender.redeem(borrower2, redeemAmount, 0);
            vm.stopPrank();
        }
       
        // Attemps to repay debt and withdraw collateral for both redeeamble borrowers
        uint256 collateralBalance2 = lender.collateralBalances(borrower2);
        assertEq(collateral.balanceOf(borrower2),0, "Borrower2's collateral should be zero before update");
        vm.startPrank(borrower2);
        coin.approve(address(lender), type(uint).max);
        lender.adjust(borrower2, -int(collateralBalance2), -int(lender.getDebtOf(borrower2))); 
        assertEq(lender.collateralBalances(borrower2), 0, "Borrower2's collateral should be zero after update");
        assertEq(lender.collateralBalances(borrower2), 0, "Borrower2's cached collateral should be zero after update");
        vm.stopPrank();
        
        
        assertGt(lender.collateralBalances(borrower1), 0, "Borrower1's collateral should be greater than zero");
        // Borrower1 should still have some collateral and debt
        uint256 debt1 = lender.getDebtOf(borrower1);
        vm.startPrank(borrower1);
        assertEq(coin.balanceOf(borrower1), 0, "Borrower1's coin balance should be zero before redeem");
        deal(address(coin), borrower1, lender.getDebtOf(borrower1)); // give borrower1 enough coins to redeem
        lender.adjust(borrower1, -int(lender.collateralBalances(borrower1)), -int(lender.getDebtOf(borrower1))); 
        vm.stopPrank();

        // This check is important
        // The final difference in collateral balance should be less than the debt amount adjusted to the current collateral price
        assertLt(collateral.balanceOf(borrower1) - collateralAmount1, (debt1 * 1 ether / price),"PROFIT");
        
        assertEq(lender.getDebtOf(borrower1), 0, "Borrower1's debt should be zero after update");
        assertEq(lender.collateralBalances(borrower1), 0, "Borrower1's collateral should be zero after update");
        
        // Approx to 0.00000002% in excess due to rounding errors
        assertGt(collateral.balanceOf(address(lender)), nonRedeemableCollateralAmount, "Lender's collateral balance should be greater than non-redeemable collateral amount after redemption");
        assertApproxEqRel(collateral.balanceOf(address(lender)), nonRedeemableCollateralAmount , 0.0002 ether, "Lender's collateral balance should be greater than zero after redemption");
        
        // Non-redeemable borrower should still have their collateral and debt
        vm.startPrank(nonRedeemableBorrower3);
        uint256 nonRedeemableCollateralBalance = lender.collateralBalances(nonRedeemableBorrower3);
        uint256 nonRedeemableDebt = lender.getDebtOf(nonRedeemableBorrower3);
        lender.coin().approve(address(lender), type(uint).max);
        lender.adjust(nonRedeemableBorrower3, -int(nonRedeemableCollateralBalance), -int(nonRedeemableDebt)); 
        assertEq(lender.collateralBalances(nonRedeemableBorrower3), 0, "Non-redeemable Borrower3's collateral should be zero after withdrawal");
        assertEq(lender.collateralBalances(nonRedeemableBorrower3), 0, "Non-redeemable Borrower3's cached collateral should be zero after update");
        assertEq(lender.getDebtOf(nonRedeemableBorrower3), 0, "Non-redeemable Borrower3's debt should be zero after update");
        assertEq(collateral.balanceOf(nonRedeemableBorrower3), nonRedeemableCollateralAmount, "Non-redeemable Borrower3's collateral should be equal to initial amount after update");
        vm.stopPrank();
    }

    function test_multiple_fuzz(uint256 collateralAmount1, uint256 collateralAmount2, uint256 nonRedeemableCollateralAmount) public {
        collateralAmount1 = bound(collateralAmount1, 1e16, 100_000_000e18);
        nonRedeemableCollateralAmount = bound(nonRedeemableCollateralAmount, 1e16, 100_000_000e18);
        collateralAmount2 = bound(collateralAmount2, 1e16, 100_000_000e18);
   
        console2.log("collateralAmount1: %s", collateralAmount1);
        console2.log("collateralAmount2: %s", collateralAmount2);
        console2.log("nonRedeemableCollateralAmount: %s", nonRedeemableCollateralAmount);
        
        // Setup: create multiple borrowers with redeemable debt and non-redeemable debt
        (uint price,,) = lender.getCollateralPrice();
        
        uint borrowAmount1 =  collateralAmount1 * price / 1 ether * 80 / 100; // 80% of collateral amount
        uint borrowAmount2 =  collateralAmount2 * price / 1 ether * 80 / 100; // 80% of collateral amount
        uint nonRedeemableBorrowAmount = nonRedeemableCollateralAmount * price / 1 ether * 80 / 100; // non-redeemable debt amount
        // Prepare test data
        address borrower1 = address(0xBEEF);
        address borrower2 = address(0xF00D);
        address nonRedeemableBorrower3 = address(0xBEEF2);
        
        // Setup: mint collateral to borrowers and coins to redeemer
        deal(address(collateral), borrower1, collateralAmount1);
        deal(address(collateral), borrower2, collateralAmount2);
        deal(address(collateral), nonRedeemableBorrower3, nonRedeemableCollateralAmount); // give borrower3 enough collateral
        // New deployment of Lender contract
        assertEq(collateral.balanceOf(address(lender)), 0, "NOT ZERO BALANCE");
        
        // Setup: borrower2 creates a redeemable position
        vm.startPrank(borrower2);
        collateral.approve(address(lender), collateralAmount2);
        lender.adjust(borrower2, int256(collateralAmount2), int256(borrowAmount2), true); // opt into redemptions
        vm.stopPrank();
        assertEq(collateral.balanceOf(address(lender)), collateralAmount2, "Collateral balance in lender should be correct after borrower2");
        // Setup: borrower1 creates a redeemable position
        vm.startPrank(borrower1);
        collateral.approve(address(lender), type(uint).max);
        coin.approve(address(lender), type(uint).max);
        lender.adjust(borrower1, int256(collateralAmount1), int256(borrowAmount1), true); // opt into redemptions
        vm.stopPrank();

        // Borrower3 creates a non-redeemable position
        vm.startPrank(nonRedeemableBorrower3);
        collateral.approve(address(lender), nonRedeemableCollateralAmount);
        lender.adjust(nonRedeemableBorrower3, int256(nonRedeemableCollateralAmount), int256(nonRedeemableBorrowAmount), false); // non-redeemable debt
        vm.stopPrank();
        assertEq(collateral.balanceOf(address(lender)), collateralAmount2 + collateralAmount1 + nonRedeemableCollateralAmount, "Collateral balance in lender should be correct");
        
        for(uint i; i < 50; i++){
            vm.startPrank(borrower1);
            lender.adjust(borrower1, int256(collateral.balanceOf(borrower1)), 0);
            uint borrowingPower = price * lender.collateralBalances(borrower1) * (lender.collateralFactor()-1) / 1e18 / 10000 - lender.getDebtOf(borrower1);
            lender.adjust(borrower1, 0, int256(borrowingPower));
            uint maxRedeem = collateral.balanceOf(address(lender)) * price * 10000 / 1e18 / (10000 - lender.redeemFeeBps());
            uint balance = coin.balanceOf(borrower1);
            uint redeemAmount = balance > maxRedeem ? maxRedeem : balance;
            lender.redeem(borrower2, redeemAmount, 0);
            vm.stopPrank();
            console2.log("Iteration: %s", i);
        }
        // Attemps to repay debt and withdraw collateral for both redeeamble borrowers
        uint256 collateralBalance2 = lender.collateralBalances(borrower2);
        console2.log("collateralBalance2: %s", collateralBalance2);
        uint256 debt2 = lender.getDebtOf(borrower2);
        assertGt(debt2, 0, "Borrower2's debt should be greater than zero before update");
        assertEq(collateral.balanceOf(borrower2),0, "Borrower2's collateral should be zero before update");
        vm.startPrank(borrower2);
        coin.approve(address(lender), type(uint).max);
        lender.adjust(borrower2, -int(collateralBalance2), -int(lender.getDebtOf(borrower2))); 
        assertEq(lender.collateralBalances(borrower2), 0, "Borrower2's collateral should be zero after update");
        assertEq(lender.collateralBalances(borrower2), 0, "Borrower2's cached collateral should be zero after update");
        assertEq(lender.getDebtOf(borrower2), 0, "Borrower2's debt should be zero after update");
        assertLt(collateral.balanceOf(borrower2), collateralAmount2, "Borrower2's collateral should be less than initial amount after redemption");
        console2.log(collateral.balanceOf(borrower2), "Borrower2's collateral balance after update");
        vm.stopPrank();
        
        
        assertGt(lender.collateralBalances(borrower1), 0, "Borrower1's collateral should be greater than zero");
        uint256 debt1 = lender.getDebtOf(borrower1);

        vm.startPrank(borrower1);
        assertEq(coin.balanceOf(borrower1), 0, "Borrower1's coin balance should be zero before redeem");
        deal(address(coin), borrower1, lender.getDebtOf(borrower1)); // give borrower1 enough coins to redeem
        lender.adjust(borrower1, -int(lender.collateralBalances(borrower1)), -int(lender.getDebtOf(borrower1))); 
        vm.stopPrank();
        

        // This check is important
        // The final difference in collateral balance should be less than the debt amount adjusted to the current collateral price
        assertLt(collateral.balanceOf(borrower1) - collateralAmount1, (debt1 * 1 ether / price),"PROFIT");
        
        assertEq(lender.getDebtOf(borrower1), 0, "Borrower1's debt should be zero after update");
        assertEq(lender.collateralBalances(borrower1), 0, "Borrower1's collateral should be zero after update");
        
        // Approx to 0.00000002% in excess due to rounding errors
        assertGe(collateral.balanceOf(address(lender)), nonRedeemableCollateralAmount, "Lender's collateral balance should be greater than non-redeemable collateral amount after redemption");
        assertApproxEqRel(collateral.balanceOf(address(lender)), nonRedeemableCollateralAmount , 0.00000002 ether, "Lender's collateral balance should be greater than zero after redemption");
        
        // Non-redeemable borrower should still have their collateral and debt
        vm.startPrank(nonRedeemableBorrower3);
        uint256 nonRedeemableCollateralBalance = lender.collateralBalances(nonRedeemableBorrower3);
        uint256 nonRedeemableDebt = lender.getDebtOf(nonRedeemableBorrower3);
        lender.coin().approve(address(lender), type(uint).max);
        lender.adjust(nonRedeemableBorrower3, -int(nonRedeemableCollateralBalance), -int(nonRedeemableDebt)); 
        assertEq(lender.collateralBalances(nonRedeemableBorrower3), 0, "Non-redeemable Borrower3's collateral should be zero after withdrawal");
        assertEq(lender.collateralBalances(nonRedeemableBorrower3), 0, "Non-redeemable Borrower3's cached collateral should be zero after update");
        assertEq(lender.getDebtOf(nonRedeemableBorrower3), 0, "Non-redeemable Borrower3's debt should be zero after update");
        assertEq(collateral.balanceOf(nonRedeemableBorrower3), nonRedeemableCollateralAmount, "Non-redeemable Borrower3's collateral should be equal to initial amount after update");
        vm.stopPrank();
        assertApproxEqAbs(collateral.balanceOf(address(lender)), 0, 1e6,"Lender's collateral balance should be almost zero at the end");
        assertEq(lender.totalPaidDebtShares(), 0, "Lender's total paid debt shares should be zero at the end");   
        assertEq(lender.totalPaidDebt(), 0, "Lender's total paid debt should be zero at the end");
        assertEq(lender.totalFreeDebt(), 0, "Lender's total free debt should be zero at the end");
        assertEq(lender.totalFreeDebtShares(), 0, "Lender's total free debt shares should be zero at the end");
        assertEq(lender.getDebtOf(borrower1), 0, "Borrower1's debt should be zero at the end");
        assertEq(lender.getDebtOf(borrower2), 0, "Borrower2's debt should be zero at the end");
        assertEq(lender.getDebtOf(nonRedeemableBorrower3), 0, "Non-redeemable Borrower3's debt should be zero at the end");
        assertEq(lender.collateralBalances(borrower1), 0, "Borrower1's cached collateral should be zero at the end");
        assertEq(lender.collateralBalances(borrower2), 0, "Borrower2's cached collateral should be zero at the end");
        assertEq(lender.collateralBalances(nonRedeemableBorrower3), 0, "Non-redeemable Borrower3's cached collateral should be zero at the end");
        assertEq(lender.freeDebtShares(borrower1), 0, "Borrower1's free debt shares should be zero at the end");
        assertEq(lender.freeDebtShares(borrower2), 0, "Borrower2's free debt shares should be zero at the end");
        assertEq(lender.paidDebtShares(nonRedeemableBorrower3), 0, "Borrower3's paid debt shares should be zero at the end");
    }    

    function test_nonRedeemableCollateral_accounting_for_adjust(uint256 collateralAmount, uint256 nonRedeemableCollateralAmount) public {
        collateralAmount = bound(collateralAmount, 1e16, 100_000_000e18);
        nonRedeemableCollateralAmount = bound(nonRedeemableCollateralAmount, 1e16, 100_000_000e18);

        (uint price,,) = lender.getCollateralPrice();
        uint borrowAmount1 = collateralAmount * price / 1 ether * 80 / 100;
        uint borrowAmount2 = nonRedeemableCollateralAmount * price / 1 ether * 80 / 100;

        address borrower1 = address(0xBEEF);
        address borrower2 = address(0xBEEF2);

        deal(address(collateral), borrower1, collateralAmount);
        deal(address(collateral), borrower2, nonRedeemableCollateralAmount);

        vm.startPrank(borrower1);
        collateral.approve(address(lender), type(uint).max);
        lender.adjust(borrower1, int256(collateralAmount), int256(borrowAmount1), true);
        vm.stopPrank();

        vm.startPrank(borrower2);
        collateral.approve(address(lender), nonRedeemableCollateralAmount);
        lender.adjust(borrower2, int256(nonRedeemableCollateralAmount), int256(borrowAmount2), false);
        vm.stopPrank();

        uint borrower1DebtBefore = lender.getDebtOf(borrower1);
        uint borrower2DebtBefore = lender.getDebtOf(borrower2);
        uint borrower1CollateralBefore = lender.collateralBalances(borrower1);
        uint borrower2CollateralBefore = lender.collateralBalances(borrower2);

        vm.prank(borrower1);
        lender.setRedemptionStatus(borrower1, false);
        vm.prank(borrower2);
        lender.setRedemptionStatus(borrower2, true);

        assertFalse(lender.isRedeemable(borrower1), "Borrower1 should be non-redeemable");
        assertTrue(lender.isRedeemable(borrower2), "Borrower2 should be redeemable");
        assertEq(lender.collateralBalances(borrower1), borrower1CollateralBefore, "Borrower1 collateral should be preserved");
        assertEq(lender.collateralBalances(borrower2), borrower2CollateralBefore, "Borrower2 collateral should be preserved");
        assertGe(lender.getDebtOf(borrower1), borrower1DebtBefore, "Borrower1 debt should not decrease");
        assertGe(lender.getDebtOf(borrower2), borrower2DebtBefore, "Borrower2 debt should not decrease");
    }

    function test_nonRedeemableCollateral_accounting_setRedemptionStatus_only(uint256 collateralAmount, uint256 nonRedeemableCollateralAmount) public {
        collateralAmount = bound(collateralAmount, 1e16, 100_000_000e18);
        nonRedeemableCollateralAmount = bound(nonRedeemableCollateralAmount, 1e16, 100_000_000e18);

        (uint price,,) = lender.getCollateralPrice();
        uint borrowAmount1 = collateralAmount * price / 1 ether * 80 / 100;
        uint borrowAmount2 = nonRedeemableCollateralAmount * price / 1 ether * 80 / 100;

        address borrower1 = address(0xBEEF);
        address borrower2 = address(0xBEEF2);

        deal(address(collateral), borrower1, collateralAmount);
        deal(address(collateral), borrower2, nonRedeemableCollateralAmount);

        vm.startPrank(borrower1);
        collateral.approve(address(lender), type(uint).max);
        lender.adjust(borrower1, int256(collateralAmount), int256(borrowAmount1), true);
        vm.stopPrank();

        vm.startPrank(borrower2);
        collateral.approve(address(lender), nonRedeemableCollateralAmount);
        lender.adjust(borrower2, int256(nonRedeemableCollateralAmount), int256(borrowAmount2), false);
        vm.stopPrank();

        vm.prank(borrower1);
        lender.setRedemptionStatus(borrower1, false);
        vm.prank(borrower2);
        lender.setRedemptionStatus(borrower2, true);
        assertFalse(lender.isRedeemable(borrower1), "Borrower1 should be non-redeemable");
        assertTrue(lender.isRedeemable(borrower2), "Borrower2 should be redeemable");

        vm.prank(borrower1);
        lender.setRedemptionStatus(borrower1, true);
        assertTrue(lender.isRedeemable(borrower1), "Borrower1 should be redeemable");

        vm.prank(borrower2);
        lender.setRedemptionStatus(borrower2, false);
        assertFalse(lender.isRedeemable(borrower2), "Borrower2 should be non-redeemable");
    }
}   
