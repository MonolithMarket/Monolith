// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Lender, ERC20, Coin, Vault, InterestModel, IChainlinkFeed, IFactory} from "src/Lender.sol";

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
    function feeBps() external view returns (uint) {
        address(this); // silences pure function warning
        return 1000; // 10%
    }
}

contract LenderTest is Test {

    Lender lender;
    address public operatorAddr;

    function setUp() public {
        // Set operator address
        operatorAddr = address(0x123);
        
        // deploy lender
        lender = new Lender(
            ERC20(address(new ERC20Mock("Collateral", "COL"))),
            IChainlinkFeed(address(new FeedMock())),
            Coin(address(new ERC20Mock("Coin", "COIN"))),
            Vault(address(new VaultMock())),
            InterestModel(address(new InterestModelMock())),
            IFactory(address(new FactoryMock())),
            operatorAddr, // use operator address
            5000, // 50% collateral factor
            1000e18, // 1000 Coin min debt
            365 days // 1 year immutability deadline
        );
    }
    
    function test_constructor() public {
        // Deploy new mock contracts for testing
        ERC20Mock newCollateral = new ERC20Mock("Collateral", "COL");
        FeedMock newFeed = new FeedMock();
        ERC20Mock newCoin = new ERC20Mock("Coin", "COIN");
        VaultMock newVault = new VaultMock();
        InterestModelMock newInterestModel = new InterestModelMock();
        FactoryMock newFactory = new FactoryMock();

        // Deploy new lender with the new mock contracts
        Lender newLender = new Lender(
            ERC20(address(newCollateral)),
            IChainlinkFeed(address(newFeed)),
            Coin(address(newCoin)),
            Vault(address(newVault)),
            InterestModel(address(newInterestModel)),
            IFactory(address(newFactory)),
            operatorAddr, // use operator address
            5000, // 50% collateral factor
            1000e18, // 1000 Coin min debt
            365 days // 1 year immutability deadline
        );

        // Verify all contract instances
        assertEq(address(newLender.collateral()), address(newCollateral), "Collateral address mismatch in constructor");
        assertEq(address(newLender.feed()), address(newFeed), "Feed address mismatch in constructor");
        assertEq(address(newLender.coin()), address(newCoin), "Coin address mismatch in constructor");
        assertEq(address(newLender.vault()), address(newVault), "Vault address mismatch in constructor");
        assertEq(address(newLender.interestModel()), address(newInterestModel), "Interest model address mismatch in constructor");
        assertEq(address(newLender.factory()), address(newFactory), "Factory address mismatch in constructor");
        assertEq(newLender.operator(), operatorAddr, "Operator address mismatch in constructor");
        assertEq(newLender.collateralFactor(), 5000, "Collateral factor mismatch in constructor");
        assertEq(newLender.minDebt(), 1000e18, "Minimum debt mismatch in constructor");
        assertEq(newLender.immutabilityDeadline(), block.timestamp + 365 days, "Immutability deadline mismatch in constructor");
    }

    function test_depositCollateral(uint depositAmount, bool chooseRedeemable) public {
        // Bound deposit amount to prevent int256 overflow
        depositAmount = bound(depositAmount, 0, uint(type(int256).max));
        
        // Prepare test data
        address user = address(0xBEEF);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        
        // Setup: mint collateral to user
        collateral.mint(user, depositAmount);
        
        // Setup: approve collateral for lender
        vm.startPrank(user);
        collateral.approve(address(lender), depositAmount);
        
        // Verify initial state
        assertEq(collateral.balanceOf(user), depositAmount, "Initial user collateral balance incorrect");
        assertEq(collateral.balanceOf(address(lender)), 0, "Initial lender collateral balance should be zero");
        assertEq(lender._cachedCollateralBalances(user), 0, "Initial cached collateral balance should be zero");
        assertEq(lender.isRedeemable(user), false, "Initial isRedeemable should be false");
        
        // Execute: deposit collateral with redemption status
        lender.adjust(user, int256(depositAmount), 0, chooseRedeemable);
        
        // Verify final state
        assertEq(collateral.balanceOf(user), 0, "User collateral balance should be zero after deposit");
        assertEq(collateral.balanceOf(address(lender)), depositAmount, "Lender collateral balance incorrect after deposit");
        assertEq(lender._cachedCollateralBalances(user), depositAmount, "Cached collateral balance incorrect after deposit");
        assertEq(lender.isRedeemable(user), chooseRedeemable, "Final isRedeemable incorrect");
        
        vm.stopPrank();
    }
    
    function test_depositCollateral_multipleTransactions(uint firstDeposit, uint secondDeposit, bool chooseRedeemable) public {
        // Bound deposit amounts to prevent int256 overflow
        firstDeposit = bound(firstDeposit, 0, uint(type(int256).max) / 2);
        secondDeposit = bound(secondDeposit, 0, uint(type(int256).max) / 2);
        
        // Prepare test data
        address user = address(0xBEEF);
        uint256 totalDeposit = firstDeposit + secondDeposit;
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        
        // Setup: mint collateral to user
        collateral.mint(user, totalDeposit);
        
        // Setup: approve collateral for lender
        vm.startPrank(user);
        collateral.approve(address(lender), totalDeposit);
        
        // Execute: first deposit with redemption status
        lender.adjust(user, int256(firstDeposit), 0, chooseRedeemable);
        
        // Verify intermediate state
        assertEq(collateral.balanceOf(user), secondDeposit, "User collateral balance incorrect after first deposit");
        assertEq(collateral.balanceOf(address(lender)), firstDeposit, "Lender collateral balance incorrect after first deposit");
        assertEq(lender._cachedCollateralBalances(user), firstDeposit, "Cached collateral balance incorrect after first deposit");
        assertEq(lender.isRedeemable(user), chooseRedeemable, "Intermediate isRedeemable incorrect");
        
        // Execute: second deposit with same redemption status
        lender.adjust(user, int256(secondDeposit), 0);
        
        // Verify final state
        assertEq(collateral.balanceOf(user), 0, "User collateral balance should be zero after both deposits");
        assertEq(collateral.balanceOf(address(lender)), totalDeposit, "Lender collateral balance incorrect after both deposits");
        assertEq(lender._cachedCollateralBalances(user), totalDeposit, "Cached collateral balance incorrect after both deposits");
        assertEq(lender.isRedeemable(user), chooseRedeemable, "Final isRedeemable incorrect");
        
        vm.stopPrank();
    }
    

    function test_depositCollateral_byThirdParty(uint depositAmount, bool chooseRedeemable) public {
        // Bound deposit amount to prevent int256 overflow
        depositAmount = bound(depositAmount, 0, uint(type(int256).max));
        
        // Prepare test data
        address user = address(0xBEEF);
        address thirdParty = address(0xCAFE);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        
        // Setup: mint collateral to third party
        collateral.mint(thirdParty, depositAmount);

        // Setup: set redemption status
        vm.prank(user);
        lender.setRedemptionStatus(user, chooseRedeemable);
        
        // Setup: approve collateral for lender from third party
        vm.startPrank(thirdParty);
        collateral.approve(address(lender), depositAmount);
        
        // Execute: third party deposits collateral on behalf of user (no delegation needed) with redemption status
        lender.adjust(user, int256(depositAmount), 0);
        
        // Verify final state
        assertEq(collateral.balanceOf(thirdParty), 0, "Third party collateral balance should be zero after deposit");
        assertEq(collateral.balanceOf(address(lender)), depositAmount, "Lender collateral balance incorrect after third party deposit");
        assertEq(lender._cachedCollateralBalances(user), depositAmount, "User cached collateral balance incorrect after third party deposit");
        assertEq(lender.isRedeemable(user), chooseRedeemable, "Final isRedeemable incorrect");
        
        vm.stopPrank();
    }

    function test_depositCollateral_withInterestModelRevert(uint depositAmount, bool chooseRedeemable) public {
        // Bound deposit amount to prevent int256 overflow
        depositAmount = bound(depositAmount, 0, uint(type(int256).max));
        
        // Prepare test data
        address user = address(0xBEEF);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        
        // Setup: mint collateral to user
        collateral.mint(user, depositAmount);
        
        // Setup: approve collateral for lender
        vm.startPrank(user);
        collateral.approve(address(lender), depositAmount);
        
        // Configure the InterestModel to revert
        InterestModelMock interestModel = InterestModelMock(address(lender.interestModel()));
        interestModel.setShouldRevert(true);
        
        // Verify initial state
        assertEq(collateral.balanceOf(user), depositAmount, "Initial user collateral balance incorrect");
        assertEq(collateral.balanceOf(address(lender)), 0, "Initial lender collateral balance should be zero");
        assertEq(lender._cachedCollateralBalances(user), 0, "Initial cached collateral balance should be zero");
        assertEq(lender.isRedeemable(user), false, "Initial isRedeemable should be false");
        
        // Get initial lastAccrue value
        uint40 initialLastAccrue = lender.lastAccrue();
        
        // Warp 1 second into the future
        vm.warp(block.timestamp + 1);
        
        // Execute: deposit collateral (should still work even if IRM reverts) with redemption status
        lender.adjust(user, int256(depositAmount), 0, chooseRedeemable);
        
        // Verify final state
        assertEq(collateral.balanceOf(user), 0, "User collateral balance should be zero after deposit despite IRM revert");
        assertEq(collateral.balanceOf(address(lender)), depositAmount, "Lender collateral balance incorrect after deposit despite IRM revert");
        assertEq(lender._cachedCollateralBalances(user), depositAmount, "Cached collateral balance incorrect after deposit despite IRM revert");
        assertEq(lender.isRedeemable(user), chooseRedeemable, "Final isRedeemable incorrect despite IRM revert");
        
        // Check if lastAccrue was updated or not
        uint40 finalLastAccrue = lender.lastAccrue();
        assertEq(finalLastAccrue, initialLastAccrue, "lastAccrue should not be updated when interest model reverts");
        
        // Set the IRM back to normal
        interestModel.setShouldRevert(false);
        
        vm.stopPrank();
    }
    
    function test_withdrawCollateral(uint depositAmount, uint withdrawAmount, bool chooseRedeemable) public {
        // Bound amounts to prevent int256 overflow
        depositAmount = bound(depositAmount, 1, uint(type(int256).max));
        withdrawAmount = bound(withdrawAmount, 1, depositAmount);
        
        // Prepare test data
        address user = address(0xBEEF);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        
        // Setup: mint collateral to user
        collateral.mint(user, depositAmount);
        
        // Setup: approve collateral for lender
        vm.startPrank(user);
        collateral.approve(address(lender), depositAmount);
        
        // Deposit collateral first with redemption status
        lender.adjust(user, int256(depositAmount), 0, chooseRedeemable);
        
        // Execute: withdraw collateral
        lender.adjust(user, -int256(withdrawAmount), 0);
        
        // Verify final state
        assertEq(collateral.balanceOf(user), withdrawAmount, "User collateral balance incorrect after withdrawal");
        assertEq(collateral.balanceOf(address(lender)), depositAmount - withdrawAmount, "Lender collateral balance incorrect after withdrawal");
        assertEq(lender._cachedCollateralBalances(user), depositAmount - withdrawAmount, "Cached collateral balance incorrect after withdrawal");
        assertEq(lender.isRedeemable(user), chooseRedeemable, "isRedeemable should remain unchanged after withdrawal");
        
        vm.stopPrank();
    }
    
    function test_withdrawCollateral_full(uint depositAmount, bool chooseRedeemable) public {
        // Bound deposit amount to prevent int256 overflow
        depositAmount = bound(depositAmount, 1, uint(type(int256).max));
        
        // Prepare test data
        address user = address(0xBEEF);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        
        // Setup: mint collateral to user
        collateral.mint(user, depositAmount);
        
        // Setup: approve collateral for lender
        vm.startPrank(user);
        collateral.approve(address(lender), depositAmount);
        
        // Deposit collateral first with redemption status
        lender.adjust(user, int256(depositAmount), 0, chooseRedeemable);
        
        // Execute: withdraw all collateral
        lender.adjust(user, -int256(depositAmount), 0);
        
        // Verify final state
        assertEq(collateral.balanceOf(user), depositAmount, "User collateral balance should equal original deposit after full withdrawal");
        assertEq(collateral.balanceOf(address(lender)), 0, "Lender collateral balance should be zero after full withdrawal");
        assertEq(lender._cachedCollateralBalances(user), 0, "Cached collateral balance should be zero after full withdrawal");
        
        vm.stopPrank();
    }
    
    function test_withdrawCollateral_multipleTransactions(uint totalAmount, bool chooseRedeemable) public {
        // Bound amount to prevent int256 overflow
        totalAmount = bound(totalAmount, 2, uint(type(int256).max));
        uint firstWithdrawal = totalAmount / 2;
        uint secondWithdrawal = totalAmount - firstWithdrawal;
        
        // Prepare test data
        address user = address(0xBEEF);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        
        // Setup: mint collateral to user
        collateral.mint(user, totalAmount);
        
        // Setup: approve collateral for lender
        vm.startPrank(user);
        collateral.approve(address(lender), totalAmount);
        
        // Deposit collateral first with redemption status
        lender.adjust(user, int256(totalAmount), 0, chooseRedeemable);
        
        // Execute: first withdrawal
        lender.adjust(user, -int256(firstWithdrawal), 0);
        
        // Verify intermediate state
        assertEq(collateral.balanceOf(user), firstWithdrawal, "User collateral balance incorrect after first withdrawal");
        assertEq(collateral.balanceOf(address(lender)), secondWithdrawal, "Lender collateral balance incorrect after first withdrawal");
        assertEq(lender._cachedCollateralBalances(user), secondWithdrawal, "Cached collateral balance incorrect after first withdrawal");
        
        // Execute: second withdrawal
        lender.adjust(user, -int256(secondWithdrawal), 0);
        
        // Verify final state
        assertEq(collateral.balanceOf(user), totalAmount, "User collateral balance should equal original deposit after multiple withdrawals");
        assertEq(collateral.balanceOf(address(lender)), 0, "Lender collateral balance should be zero after multiple withdrawals");
        assertEq(lender._cachedCollateralBalances(user), 0, "Cached collateral balance should be zero after multiple withdrawals");
        
        vm.stopPrank();
    }
    
    function test_withdrawCollateral_byDelegation(uint depositAmount, uint withdrawAmount, bool chooseRedeemable) public {
        // Bound amounts to prevent int256 overflow
        depositAmount = bound(depositAmount, 1, uint(type(int256).max));
        withdrawAmount = bound(withdrawAmount, 1, depositAmount);
        
        // Prepare test data
        address user = address(0xBEEF);
        address delegate = address(0xCAFE);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        
        // Setup: mint collateral to user
        collateral.mint(user, depositAmount);
        
        // Setup: delegate permissions
        vm.prank(user);
        lender.delegate(delegate, true);
        
        // Setup: deposit collateral first (from user)
        vm.startPrank(user);
        collateral.approve(address(lender), depositAmount);
        lender.adjust(user, int256(depositAmount), 0, chooseRedeemable);
        vm.stopPrank();
        
        // Execute: delegate withdraws on behalf of user
        vm.prank(delegate);
        lender.adjust(user, -int256(withdrawAmount), 0);
        
        // Verify final state - collateral goes to the delegate (msg.sender)
        assertEq(collateral.balanceOf(delegate), withdrawAmount, "Delegate collateral balance incorrect after delegated withdrawal");
        assertEq(collateral.balanceOf(user), 0, "User collateral balance should be zero after delegated withdrawal");
        assertEq(lender._cachedCollateralBalances(user), depositAmount - withdrawAmount, "Cached collateral balance incorrect after delegated withdrawal");
    }
    
    function test_withdrawCollateral_withInterestModelRevert(uint depositAmount, uint withdrawAmount, bool chooseRedeemable) public {
        // Bound amounts to prevent int256 overflow
        depositAmount = bound(depositAmount, 1, uint(type(int256).max));
        withdrawAmount = bound(withdrawAmount, 1, depositAmount);
        
        // Prepare test data
        address user = address(0xBEEF);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        
        // Setup: mint collateral to user
        collateral.mint(user, depositAmount);
        
        // Setup: approve collateral for lender
        vm.startPrank(user);
        collateral.approve(address(lender), depositAmount);
        
        // Deposit collateral first with redemption status
        lender.adjust(user, int256(depositAmount), 0, chooseRedeemable);
        
        // Configure the InterestModel to revert
        InterestModelMock interestModel = InterestModelMock(address(lender.interestModel()));
        interestModel.setShouldRevert(true);
        
        // Get initial lastAccrue value
        uint40 initialLastAccrue = lender.lastAccrue();
        
        // Warp 1 second into the future
        vm.warp(block.timestamp + 1);
        
        // Execute: withdraw collateral (should still work even if IRM reverts)
        lender.adjust(user, -int256(withdrawAmount), 0);
        
        // Verify final state
        assertEq(collateral.balanceOf(user), withdrawAmount, "User collateral balance incorrect after withdrawal despite IRM revert");
        assertEq(collateral.balanceOf(address(lender)), depositAmount - withdrawAmount, "Lender collateral balance incorrect after withdrawal despite IRM revert");
        assertEq(lender._cachedCollateralBalances(user), depositAmount - withdrawAmount, "Cached collateral balance incorrect after withdrawal despite IRM revert");
        
        // Check if lastAccrue was updated or not
        uint40 finalLastAccrue = lender.lastAccrue();
        assertEq(finalLastAccrue, initialLastAccrue, "lastAccrue should not be updated when interest model reverts");
        
        // Set the IRM back to normal
        interestModel.setShouldRevert(false);
        
        vm.stopPrank();
    }
    
    function test_withdrawCollateral_byUnauthorizedThirdPartyReverts() public {
        // Amounts don't matter for this test
        uint depositAmount = 1000e18;
        uint withdrawAmount = 500e18;
        
        // Prepare test data
        address user = address(0xBEEF);
        address unauthorized = address(0xDEAD);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        
        // Setup: mint collateral to user
        collateral.mint(user, depositAmount);
        
        // Setup: deposit collateral first (from user)
        vm.startPrank(user);
        collateral.approve(address(lender), depositAmount);
        lender.adjust(user, int256(depositAmount), 0);
        vm.stopPrank();
        
        // Execute: unauthorized third party attempts to withdraw on behalf of user
        vm.startPrank(unauthorized);
        
        // This should revert because the third party is not authorized
        vm.expectRevert("Unauthorized");
        lender.adjust(user, -int256(withdrawAmount), 0);
        
        vm.stopPrank();
        
        // Verify state remains unchanged
        assertEq(collateral.balanceOf(address(lender)), depositAmount, "Lender collateral balance should remain unchanged after failed withdrawal attempt");
        assertEq(lender._cachedCollateralBalances(user), depositAmount, "Cached collateral balance should remain unchanged after failed withdrawal attempt");
    }
    
    function test_withdrawCollateral_withDebtSolvencyCheck(uint collateralAmount, uint borrowAmount) public {
        // Bound amounts to prevent overflows and ensure solvency
        collateralAmount = bound(collateralAmount, 4000e18, type(uint128).max);
        borrowAmount = bound(borrowAmount, lender.minDebt(), collateralAmount * lender.collateralFactor() / 20000); // Only borrow 25% of capacity
        
        // Prepare test data
        address user = address(0xBEEF);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        
        // Setup: mint collateral to user
        collateral.mint(user, collateralAmount);
        
        // Setup: approve collateral for lender
        vm.startPrank(user);
        collateral.approve(address(lender), collateralAmount);
        
        // Deposit collateral first
        lender.adjust(user, int256(collateralAmount), 0);
        
        // Borrow some amount
        lender.adjust(user, 0, int256(borrowAmount));
        
        // Calculate the maximum amount of collateral that can be withdrawn while maintaining solvency
        // Price is 1e18 in the mock, and collateral factor is 5000 (50%)
        uint price = 1e18;
        uint minCollateralRequired = borrowAmount * 10000 / lender.collateralFactor() * 1e18 / price;
        uint maxWithdrawalAmount = collateralAmount - minCollateralRequired;
        
        // Execute: withdraw just under the maximum allowed amount
        uint safeWithdrawalAmount = maxWithdrawalAmount > 0 ? maxWithdrawalAmount - 1 : 0;
        lender.adjust(user, -int256(safeWithdrawalAmount), 0);
        
        // This should succeed
        assertEq(collateral.balanceOf(user), safeWithdrawalAmount, "User collateral balance incorrect after safe withdrawal");
        assertEq(lender._cachedCollateralBalances(user), collateralAmount - safeWithdrawalAmount, "Cached collateral balance incorrect after safe withdrawal");
        
        // Try to withdraw 2 more units, which should break solvency
        vm.expectRevert("Solvency check failed");
        lender.adjust(user, -int256(2), 0);
        
        vm.stopPrank();
    }
    
    function test_withdrawCollateral_reduceOnlyModeZeroDebt(uint depositAmount, uint withdrawAmount) public {
        // Bound amounts to prevent int256 overflow
        depositAmount = bound(depositAmount, 1, uint(type(int256).max));
        withdrawAmount = bound(withdrawAmount, 1, depositAmount);
        
        // Prepare test data
        address user = address(0xBEEF);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        FeedMock feed = FeedMock(address(lender.feed()));
        
        // Setup: mint collateral to user
        collateral.mint(user, depositAmount);
        
        // Setup: approve collateral for lender
        vm.startPrank(user);
        collateral.approve(address(lender), depositAmount);
        
        // Deposit collateral first
        lender.adjust(user, int256(depositAmount), 0);
        
        // Enable the feed to revert to trigger reduce-only mode
        feed.setShouldRevert(true);
        
        // Execute: withdraw collateral in reduce-only mode (should ONLY work with zero debt)
        lender.adjust(user, -int256(withdrawAmount), 0);
        
        // Verify final state
        assertEq(collateral.balanceOf(user), withdrawAmount, "User collateral balance incorrect after withdrawal in reduce-only mode");
        assertEq(collateral.balanceOf(address(lender)), depositAmount - withdrawAmount, "Lender collateral balance incorrect after withdrawal in reduce-only mode");
        assertEq(lender._cachedCollateralBalances(user), depositAmount - withdrawAmount, "Cached collateral balance incorrect after withdrawal in reduce-only mode");
        
        vm.stopPrank();
    }
    
    function test_withdrawCollateral_reduceOnlyModeWithDebtReverts(uint collateralAmount, uint withdrawAmount) public {
        // Bound amounts to prevent overflows and ensure solvency
        collateralAmount = bound(collateralAmount, 4000e18, type(uint128).max);
        uint borrowAmount = collateralAmount * lender.collateralFactor() / 10000;
        withdrawAmount = bound(withdrawAmount, 1, collateralAmount / 2); // Try to withdraw some amount
        
        // Prepare test data
        address user = address(0xBEEF);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        FeedMock feed = FeedMock(address(lender.feed()));
        
        // Setup: mint collateral to user
        collateral.mint(user, collateralAmount);
        
        // Setup: approve collateral for lender
        vm.startPrank(user);
        collateral.approve(address(lender), collateralAmount);
        
        // Deposit collateral first
        lender.adjust(user, int256(collateralAmount), 0);
        
        // Borrow some amount
        lender.adjust(user, 0, int256(borrowAmount));
        
        // Verify user has debt
        assertGt(lender.getDebtOf(user), 0, "User should have debt before trying to withdraw in reduce-only mode");
        
        // Enable the feed to revert to trigger reduce-only mode
        feed.setShouldRevert(true);
        
        // Try to withdraw collateral in reduce-only mode with debt
        // This should revert because withdrawing collateral with debt is not allowed in reduce-only mode
        vm.expectRevert("Reduce only");
        lender.adjust(user, -int256(withdrawAmount), 0);
        
        // Verify state remains unchanged after failed withdrawal
        assertEq(collateral.balanceOf(user), 0, "User collateral balance should remain unchanged after failed withdrawal attempt");
        assertEq(collateral.balanceOf(address(lender)), collateralAmount, "Lender collateral balance should remain unchanged after failed withdrawal attempt");
        assertEq(lender._cachedCollateralBalances(user), collateralAmount, "Cached collateral balance should remain unchanged after failed withdrawal attempt");
        
        vm.stopPrank();
    }
    
    function test_borrow(uint collateralAmount, uint borrowAmount, bool chooseRedeemable) public {
        // Bound amounts to prevent overflows
        collateralAmount = bound(collateralAmount, 2000e18, type(uint128).max);
        borrowAmount = bound(borrowAmount, lender.minDebt(), collateralAmount * lender.collateralFactor() / 10000);
        
        // Prepare test data
        address user = address(0xBEEF);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        
        // Setup: mint collateral to user
        collateral.mint(user, collateralAmount);
        
        // Setup: approve collateral for lender
        vm.startPrank(user);
        collateral.approve(address(lender), collateralAmount);

        // Set redemption status
        lender.setRedemptionStatus(user, chooseRedeemable);
        
        // Deposit collateral first
        lender.adjust(user, int256(collateralAmount), 0);
        
        // Verify initial state before borrowing
        assertEq(lender._cachedCollateralBalances(user), collateralAmount, "Initial collateral balance incorrect before borrowing");
        assertEq(lender.getDebtOf(user), 0, "Initial debt should be zero before borrowing");
        assertEq(coin.balanceOf(user), 0, "Initial coin balance should be zero before borrowing");
        
        // Execute: borrow
        lender.adjust(user, 0, int256(borrowAmount));
        
        // Verify final state
        assertEq(lender.getDebtOf(user), borrowAmount, "Debt amount incorrect after borrowing");
        assertEq(coin.balanceOf(user), borrowAmount, "Coin balance incorrect after borrowing");
        // Collateral balance should remain unchanged
        assertEq(lender._cachedCollateralBalances(user), collateralAmount, "Collateral balance should be unchanged after borrowing");
        
        vm.stopPrank();
    }
    
    function test_borrow_multipleTransactions(uint collateralAmount, bool chooseRedeemable) public {
        // Bound amounts to prevent overflows
        collateralAmount = bound(collateralAmount, lender.minDebt() * 4, type(uint128).max);
        uint firstBorrow = lender.minDebt();
        uint secondBorrow = lender.minDebt();
        
        // Prepare test data
        address user = address(0xBEEF);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        
        // Setup: mint collateral to user
        collateral.mint(user, collateralAmount);
        
        // Setup: approve collateral for lender
        vm.startPrank(user);
        collateral.approve(address(lender), collateralAmount);

        // Set redemption status
        lender.setRedemptionStatus(user, chooseRedeemable);
        
        // Deposit collateral first
        lender.adjust(user, int256(collateralAmount), 0);
        
        // Execute: first borrow
        lender.adjust(user, 0, int256(firstBorrow));
        
        // Verify intermediate state
        assertEq(lender.getDebtOf(user), firstBorrow, "Debt amount incorrect after first borrow");
        assertEq(coin.balanceOf(user), firstBorrow, "Coin balance incorrect after first borrow");
        
        // Execute: second borrow
        lender.adjust(user, 0, int256(secondBorrow));
        
        // Verify final state
        assertEq(lender.getDebtOf(user), firstBorrow + secondBorrow, "Total debt incorrect after second borrow");
        assertEq(coin.balanceOf(user), firstBorrow + secondBorrow, "Total coin balance incorrect after second borrow");
        
        // Collateral balance should remain unchanged
        assertEq(lender._cachedCollateralBalances(user), collateralAmount, "Collateral balance should be unchanged after multiple borrows");
        
        vm.stopPrank();
    }
    
    function test_borrow_byDelegation(uint collateralAmount, uint borrowAmount, bool chooseRedeemable) public {
        // Bound amounts to prevent overflows
        collateralAmount = bound(collateralAmount, 2000e18, type(uint128).max);
        borrowAmount = bound(borrowAmount, lender.minDebt(), collateralAmount * lender.collateralFactor() / 10000);
        
        // Prepare test data
        address user = address(0xBEEF);
        address delegate = address(0xCAFE);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        
        // Setup: mint collateral to user
        collateral.mint(user, collateralAmount);
        
        // Setup: delegate permissions
        vm.prank(user);
        lender.delegate(delegate, true);
        
        // Setup: deposit collateral first (from user)
        vm.startPrank(user);
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(user, int256(collateralAmount), 0);
        vm.stopPrank();
        
        // Verify initial state before borrowing
        assertEq(lender._cachedCollateralBalances(user), collateralAmount, "Initial collateral balance incorrect before delegated borrowing");
        assertEq(lender.getDebtOf(user), 0, "Initial debt should be zero before delegated borrowing");
        
        // Execute: delegate borrows on behalf of user
        vm.prank(delegate);
        lender.adjust(user, 0, int256(borrowAmount), chooseRedeemable);
        
        // Verify final state - coins go to the delegate (msg.sender)
        assertEq(lender.getDebtOf(user), borrowAmount, "User debt incorrect after delegated borrowing");
        assertEq(coin.balanceOf(delegate), borrowAmount, "Delegate coin balance incorrect after delegated borrowing");
        assertEq(coin.balanceOf(user), 0, "User coin balance should be zero after delegated borrowing");
        // Collateral balance should remain unchanged
        assertEq(lender._cachedCollateralBalances(user), collateralAmount, "Collateral balance should be unchanged after delegated borrowing");
    }
    
    function test_borrow_withInterestModelRevert(uint collateralAmount, uint borrowAmount, bool chooseRedeemable) public {
        // Bound amounts to prevent overflows
        collateralAmount = bound(collateralAmount, 2000e18, type(uint128).max);
        borrowAmount = bound(borrowAmount, lender.minDebt(), collateralAmount * lender.collateralFactor() / 10000);
        
        // Prepare test data
        address user = address(0xBEEF);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        
        // Setup: mint collateral to user
        collateral.mint(user, collateralAmount);
        
        // Setup: approve collateral for lender
        vm.startPrank(user);
        collateral.approve(address(lender), collateralAmount);
        
        // Deposit collateral first
        lender.adjust(user, int256(collateralAmount), 0);

        // Set redemption status
        lender.setRedemptionStatus(user, chooseRedeemable);
        
        // Configure the InterestModel to revert
        InterestModelMock interestModel = InterestModelMock(address(lender.interestModel()));
        interestModel.setShouldRevert(true);
        
        // Get initial lastAccrue value
        uint40 initialLastAccrue = lender.lastAccrue();
        
        // Warp 1 second into the future
        vm.warp(block.timestamp + 1);
        
        // Execute: borrow (should still work even if IRM reverts)
        lender.adjust(user, 0, int256(borrowAmount));
        
        // Verify final state
        assertEq(lender.getDebtOf(user), borrowAmount, "Debt amount incorrect after borrowing with IRM revert");
        assertEq(coin.balanceOf(user), borrowAmount, "Coin balance incorrect after borrowing with IRM revert");
        
        // Check if lastAccrue was updated or not
        uint40 finalLastAccrue = lender.lastAccrue();
        assertEq(finalLastAccrue, initialLastAccrue, "lastAccrue should not be updated when interest model reverts");
        
        // Set the IRM back to normal
        interestModel.setShouldRevert(false);
        
        vm.stopPrank();
    }
    
    function test_borrow_exceedMaxAmountReverts(uint collateralAmount, bool chooseRedeemable) public {
        // Bound deposit amount
        collateralAmount = bound(collateralAmount, 2000e18, type(uint128).max);
        
        // Prepare test data
        address user = address(0xBEEF);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        
        // Setup: mint collateral to user
        collateral.mint(user, collateralAmount);
        
        // Setup: approve collateral for lender
        vm.startPrank(user);
        collateral.approve(address(lender), collateralAmount);
        
        // Deposit collateral first
        lender.adjust(user, int256(collateralAmount), 0);

        // Set redemption status
        lender.setRedemptionStatus(user, chooseRedeemable);
        
        // Calculate the maximum borrowable amount based on collateral factor (50%)
        uint maxBorrowAmount = collateralAmount * lender.collateralFactor() / 10000;
        
        // Try to borrow more than the maximum and expect revert
        vm.expectRevert("Solvency check failed");
        lender.adjust(user, 0, int256(maxBorrowAmount + 1));
        
        vm.stopPrank();
    }
    
    function test_borrow_belowMinDebtReverts(uint collateralAmount, bool chooseRedeemable) public {
        // Bound deposit amount
        collateralAmount = bound(collateralAmount, 2000e18, type(uint128).max);
        
        // Prepare test data
        address user = address(0xBEEF);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        uint minDebt = lender.minDebt();
        uint borrowAmount = minDebt - 1; // Just below minimum debt
        
        // Setup: mint collateral to user
        collateral.mint(user, collateralAmount);
        
        // Setup: approve collateral for lender
        vm.startPrank(user);
        collateral.approve(address(lender), collateralAmount);
        
        // Deposit collateral first
        lender.adjust(user, int256(collateralAmount), 0);

        // Set redemption status
        lender.setRedemptionStatus(user, chooseRedeemable);
        
        // Try to borrow below minimum debt and expect revert
        vm.expectRevert("Debt below minimum and larger than 0");
        lender.adjust(user, 0, int256(borrowAmount));
        
        vm.stopPrank();
    }
    
    function test_borrow_byUnauthorizedThirdPartyReverts(bool chooseRedeemable) public {
        // Amounts don't matter for this test. Borrow just needs to reach minDebt
        uint collateralAmount = 4000e18;
        uint borrowAmount = 2000e18;
        
        // Prepare test data
        address user = address(0xBEEF);
        address unauthorized = address(0xDEAD);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        
        // Setup: mint collateral to user
        collateral.mint(user, collateralAmount);
        
        // Setup: deposit collateral first (from user)
        vm.startPrank(user);
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(user, int256(collateralAmount), 0);
        vm.stopPrank();

        
        // Verify initial state before borrowing attempt
        assertEq(lender._cachedCollateralBalances(user), collateralAmount, "Initial collateral balance incorrect before unauthorized borrow attempt");
        assertEq(lender.getDebtOf(user), 0, "Initial debt should be zero before unauthorized borrow attempt");
        
        // Execute: unauthorized third party attempts to borrow on behalf of user
        vm.startPrank(unauthorized);
        
        // This should revert because the third party is not authorized
        vm.expectRevert("Unauthorized");
        lender.adjust(user, 0, int256(borrowAmount), chooseRedeemable);
        
        vm.stopPrank();
        
        // Verify state remains unchanged
        assertEq(lender.getDebtOf(user), 0, "Debt should still be zero after failed unauthorized borrow attempt");
    }
    
    function test_borrow_reduceOnlyMode() public {
        // Amounts for the test
        uint collateralAmount = 4000e18;
        uint borrowAmount = 2000e18;
        
        // Prepare test data
        address user = address(0xBEEF);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        FeedMock feed = FeedMock(address(lender.feed()));
        
        // Setup: mint collateral to user
        collateral.mint(user, collateralAmount);
        
        // Setup: approve collateral for lender
        vm.startPrank(user);
        collateral.approve(address(lender), collateralAmount);
        
        // Deposit collateral first
        lender.adjust(user, int256(collateralAmount), 0);
        
        // Borrow some debt normally
        lender.adjust(user, 0, int256(borrowAmount));
        
        // Verify initial state after borrowing
        assertEq(lender.getDebtOf(user), borrowAmount, "Initial debt incorrect after normal borrowing");
        assertEq(coin.balanceOf(user), borrowAmount, "Initial coin balance incorrect after normal borrowing");
        
        // Enable the feed to revert to trigger reduce-only mode
        feed.setShouldRevert(true);
        
        // Attempt to borrow more in reduce-only mode
        vm.expectRevert("Reduce only");
        lender.adjust(user, 0, int256(borrowAmount));
        
        // Verify state remained unchanged after failed borrow attempt
        assertEq(lender.getDebtOf(user), borrowAmount, "Debt should remain unchanged after failed borrow in reduce-only mode");
        assertEq(coin.balanceOf(user), borrowAmount, "Coin balance should remain unchanged after failed borrow in reduce-only mode");
        
        vm.stopPrank();
    }

    function test_repay_partial(uint collateralAmount, uint repayAmount, bool chooseRedeemable) public {
        // Bound amounts to prevent overflows
        collateralAmount = bound(collateralAmount, lender.minDebt() * 4, type(uint128).max);
        uint borrowAmount = collateralAmount * lender.collateralFactor() / 10000;
        repayAmount = bound(repayAmount, 1, borrowAmount - lender.minDebt()); // Ensure partial repayment
        
        // Prepare test data
        address user = address(0xBEEF);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        
        // Setup: mint collateral to user
        collateral.mint(user, collateralAmount);
        
        // Setup: approve collateral for lender
        vm.startPrank(user);
        collateral.approve(address(lender), collateralAmount);
        
        // Deposit collateral and borrow
        lender.adjust(user, int256(collateralAmount), int256(borrowAmount), chooseRedeemable);
        
        // Approve coin for repayment
        coin.approve(address(lender), repayAmount);
        
        // Execute: partial repayment
        lender.adjust(user, 0, -int256(repayAmount));
        
        // Verify final state
        assertEq(lender.getDebtOf(user), borrowAmount - repayAmount, "Debt amount incorrect after partial repayment");
        assertEq(coin.balanceOf(user), borrowAmount - repayAmount, "Coin balance incorrect after partial repayment");
        
        vm.stopPrank();
    }
    
    function test_repay_full(uint collateralAmount, bool chooseRedeemable) public {
        // Bound amounts to prevent overflows
        collateralAmount = bound(collateralAmount, 2000e18, type(uint128).max);
        uint borrowAmount = collateralAmount * lender.collateralFactor() / 10000;
        
        // Prepare test data
        address user = address(0xBEEF);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        
        // Setup: mint collateral to user
        collateral.mint(user, collateralAmount);
        
        // Setup: approve collateral for lender
        vm.startPrank(user);
        collateral.approve(address(lender), collateralAmount);
        
        // Deposit collateral and borrow
        lender.adjust(user, int256(collateralAmount), int256(borrowAmount), chooseRedeemable);
        
        // Approve coin for repayment
        coin.approve(address(lender), borrowAmount);
        
        // Execute: full repayment
        lender.adjust(user, 0, -int256(borrowAmount));
        
        // Verify final state
        assertEq(lender.getDebtOf(user), 0, "Debt should be zero after full repayment");
        assertEq(coin.balanceOf(user), 0, "Coin balance should be zero after full repayment");
        
        vm.stopPrank();
    }
    
    function test_repay_excess(uint collateralAmount, bool chooseRedeemable) public {
        // Bound amounts to prevent overflows
        collateralAmount = bound(collateralAmount, 2000e18, type(uint128).max);
        uint borrowAmount = collateralAmount * lender.collateralFactor() / 10000;
        uint excessAmount = borrowAmount + 100e18; // More than the debt
        
        // Prepare test data
        address user = address(0xBEEF);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        
        // Setup: mint collateral to user
        collateral.mint(user, collateralAmount);
        // Mint extra coin for excess repayment
        coin.mint(user, 100e18);
        
        // Setup: approve collateral for lender
        vm.startPrank(user);
        collateral.approve(address(lender), collateralAmount);
        
        // Deposit collateral first
        lender.adjust(user, int256(collateralAmount), 0);

        // Set redemption status
        lender.setRedemptionStatus(user, chooseRedeemable);
        
        // Borrow
        lender.adjust(user, 0, int256(borrowAmount));
        
        // Approve coin for repayment (more than borrowed)
        coin.approve(address(lender), excessAmount);
        
        // Execute: excess repayment (should cap at actual debt)
        lender.adjust(user, 0, -int256(excessAmount));
        
        // Verify final state
        assertEq(lender.getDebtOf(user), 0, "Debt should be zero after excess repayment");
        assertEq(coin.balanceOf(user), 100e18, "Remaining coin balance incorrect after excess repayment");
        
        vm.stopPrank();
    }
    
    function test_repay_byThirdParty(uint collateralAmount, bool chooseRedeemable) public {
        // Bound amounts to prevent overflows
        collateralAmount = bound(collateralAmount, 2000e18, type(uint128).max);
        uint borrowAmount = collateralAmount * lender.collateralFactor() / 10000;
        
        // Prepare test data
        address user = address(0xBEEF);
        address thirdParty = address(0xCAFE);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        
        // Setup: mint collateral to user
        collateral.mint(user, collateralAmount);
        // Mint coin to third party for repayment
        coin.mint(thirdParty, borrowAmount);
        
        // Setup: deposit collateral first (from user)
        vm.startPrank(user);
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(user, int256(collateralAmount), 0);
        
        // Borrow
        lender.adjust(user, 0, int256(borrowAmount), chooseRedeemable);
        vm.stopPrank();
        
        // Execute: third party repays on behalf of user (no delegation needed)
        vm.startPrank(thirdParty);
        coin.approve(address(lender), borrowAmount);
        lender.adjust(user, 0, -int256(borrowAmount));
        vm.stopPrank();
        
        // Verify final state
        assertEq(lender.getDebtOf(user), 0, "Debt should be zero after third party repayment");
        assertEq(coin.balanceOf(thirdParty), 0, "Third party coin balance should be zero after repayment");
        assertEq(coin.balanceOf(user), borrowAmount, "User coin balance incorrect after third party repayment");
    }
    
    function test_repay_multipleTransactions(uint collateralAmount, bool chooseRedeemable) public {
        // Bound deposit amount
        collateralAmount = bound(collateralAmount, 4000e18, type(uint128).max);
        uint borrowAmount = collateralAmount * lender.collateralFactor() / 10000;
        uint firstRepay = borrowAmount / 2;
        uint secondRepay = borrowAmount - firstRepay;
        
        // Prepare test data
        address user = address(0xBEEF);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        
        // Setup: mint collateral to user
        collateral.mint(user, collateralAmount);
        
        // Setup: approve collateral for lender
        vm.startPrank(user);
        collateral.approve(address(lender), collateralAmount);
        
        // Deposit collateral first
        lender.adjust(user, int256(collateralAmount), 0);
        
        // Set redemption status
        lender.setRedemptionStatus(user, chooseRedeemable);
        
        // Borrow
        lender.adjust(user, 0, int256(borrowAmount));
        
        // Approve coin for repayment
        coin.approve(address(lender), borrowAmount);
        
        // Execute: first repayment
        lender.adjust(user, 0, -int256(firstRepay));
        
        // Verify intermediate state
        assertEq(lender.getDebtOf(user), borrowAmount - firstRepay, "Debt amount incorrect after first repayment");
        assertEq(coin.balanceOf(user), borrowAmount - firstRepay, "Coin balance incorrect after first repayment");
        
        // Execute: second repayment (more than remaining debt)
        lender.adjust(user, 0, -int256(secondRepay));
        
        // Verify final state
        assertEq(lender.getDebtOf(user), 0, "Debt should be zero after second repayment");
        assertEq(coin.balanceOf(user), 0, "Coin balance should be zero after second repayment");
        
        vm.stopPrank();
    }
    
    function test_repay_withInterestModelRevert(uint collateralAmount, uint repayAmount, bool chooseRedeemable) public {
        // Bound amounts to prevent overflows
        collateralAmount = bound(collateralAmount, lender.minDebt() * 4, type(uint128).max);
        uint borrowAmount = collateralAmount * lender.collateralFactor() / 10000;
        repayAmount = bound(repayAmount, 1, borrowAmount - lender.minDebt());
        
        // Prepare test data
        address user = address(0xBEEF);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        
        // Setup: mint collateral to user
        collateral.mint(user, collateralAmount);
        
        // Setup: approve collateral for lender
        vm.startPrank(user);
        collateral.approve(address(lender), collateralAmount);
        
        // Deposit collateral first
        lender.adjust(user, int256(collateralAmount), 0);
        
        // Set redemption status
        lender.setRedemptionStatus(user, chooseRedeemable);
        
        // Borrow
        lender.adjust(user, 0, int256(borrowAmount));
        
        // Configure the InterestModel to revert
        InterestModelMock interestModel = InterestModelMock(address(lender.interestModel()));
        interestModel.setShouldRevert(true);
        
        // Get initial lastAccrue value
        uint40 initialLastAccrue = lender.lastAccrue();
        
        // Warp 1 second into the future
        vm.warp(block.timestamp + 1);
        
        // Approve coin for repayment
        coin.approve(address(lender), repayAmount);
        
        // Execute: repayment (should still work even if IRM reverts)
        lender.adjust(user, 0, -int256(repayAmount));
        
        // Verify final state
        assertEq(lender.getDebtOf(user), borrowAmount - repayAmount, "Debt amount incorrect after repayment with IRM revert");
        assertEq(coin.balanceOf(user), borrowAmount - repayAmount, "Coin balance incorrect after repayment with IRM revert");
        
        // Check if lastAccrue was updated or not
        uint40 finalLastAccrue = lender.lastAccrue();
        assertEq(finalLastAccrue, initialLastAccrue, "lastAccrue should not be updated when interest model reverts");
        
        // Set the IRM back to normal
        interestModel.setShouldRevert(false);
        
        vm.stopPrank();
    }
    
    function test_repay_reduceOnlyMode(uint collateralAmount, uint repayAmount) public {
        // Bound amounts to prevent overflows
        collateralAmount = bound(collateralAmount, lender.minDebt() * 4, type(uint128).max);
        uint borrowAmount = collateralAmount * lender.collateralFactor() / 10000;
        repayAmount = bound(repayAmount, 1, borrowAmount - lender.minDebt());
        
        // Prepare test data
        address user = address(0xBEEF);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        FeedMock feed = FeedMock(address(lender.feed()));
        
        // Setup: mint collateral to user
        collateral.mint(user, collateralAmount);
        
        // Setup: approve collateral for lender
        vm.startPrank(user);
        collateral.approve(address(lender), collateralAmount);
        
        // Deposit collateral first
        lender.adjust(user, int256(collateralAmount), 0);
        
        // Borrow
        lender.adjust(user, 0, int256(borrowAmount));
        
        // Enable the feed to revert to trigger reduce-only mode
        feed.setShouldRevert(true);
        
        // Approve coin for repayment
        coin.approve(address(lender), repayAmount);
        
        // Execute: repayment in reduce-only mode (should work since it's reducing debt)
        lender.adjust(user, 0, -int256(repayAmount));
        
        // Verify final state
        assertEq(lender.getDebtOf(user), borrowAmount - repayAmount, "Debt amount incorrect after repayment in reduce-only mode");
        assertEq(coin.balanceOf(user), borrowAmount - repayAmount, "Coin balance incorrect after repayment in reduce-only mode");
        
        vm.stopPrank();
    }

    // this one must be non-redeemable (which is the default) to accrue interest
    function test_repay_withInterestAccrual(uint collateralAmount) public {
        // Bound amounts to prevent overflows
        collateralAmount = bound(collateralAmount, lender.minDebt() * 2, type(uint128).max);
        uint borrowAmount = collateralAmount * lender.collateralFactor() / 10000;
        
        // Prepare test data
        address user = address(0xBEEF);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        
        // Setup: mint collateral to user
        collateral.mint(user, collateralAmount);
        
        // Setup: approve collateral for lender
        vm.startPrank(user);
        collateral.approve(address(lender), collateralAmount);
        
        // Deposit collateral and borrow
        lender.adjust(user, int256(collateralAmount), int256(borrowAmount));
        
        // Record timestamp and debt before time advance
        uint initialTimestamp = block.timestamp;
        uint initialDebt = lender.getDebtOf(user);
        
        // Advance time by 6 months to accrue interest (the mock interest model returns 1e18 per year)
        uint timeElapsed = 182 days; // ~half a year
        vm.warp(initialTimestamp + timeElapsed);
        
        // Calculate expected interest (mock model has fixed 100% APR)
        uint borrowRate = 1e18;
        uint expectedInterest = initialDebt * borrowRate * timeElapsed / 365 days / 1e18;
        uint expectedTotalDebt = initialDebt + expectedInterest;
        
        // Mint additional coins to user to cover interest
        coin.mint(user, expectedInterest);
        
        // Approve coin for full repayment
        coin.approve(address(lender), expectedTotalDebt);
        
        // Force interest accrual by calling accrueInterest
        lender.accrueInterest();

        // Verify the interest has been accrued by checking lastAccrue has been updated
        assertEq(lender.lastAccrue(), initialTimestamp + timeElapsed, "lastAccrue should have been updated");
        
        // Verify the debt has increased due to interest
        uint debtAfterInterest = lender.getDebtOf(user);
        assertEq(debtAfterInterest, expectedTotalDebt, "Debt should have increased after interest accrual");
        
        // Execute: full repayment including interest
        lender.adjust(user, 0, -int256(expectedTotalDebt));
        
        // Verify final state
        assertEq(lender.getDebtOf(user), 0, "Debt should be zero after full repayment with interest");
        
        // Verify remaining coin balance
        assertEq(coin.balanceOf(user), 0, "Remaining coin balance incorrect after repayment with interest");
        
        vm.stopPrank();
    }

    function test_liquidation_successAfterPriceDecrease() public {
        // Setup: create a position that will become underwater when price changes
        uint collateralAmount = 4000e18;
        uint borrowAmount = collateralAmount * lender.collateralFactor() / 20000; // Using 25% of capacity
        
        // Prepare test data
        address borrower = address(0xBEEF);
        address liquidator = address(0xCAFE);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        FeedMock feed = FeedMock(address(lender.feed()));
        
        // Mint coins to liquidator
        coin.mint(liquidator, borrowAmount); 
        
        // Setup: mint collateral to borrower
        collateral.mint(borrower, collateralAmount);
        
        // Setup: approve collateral for lender
        vm.startPrank(borrower);
        collateral.approve(address(lender), collateralAmount);
        
        // Deposit collateral and borrow
        lender.adjust(borrower, int256(collateralAmount), int256(borrowAmount));
        vm.stopPrank();
        
        // Make the position underwater by reducing collateral price by 60%
        feed.setPrice(0.4e18);
        
        // Calculate expected liquidation results - we expect about 25% of debt to be repaid
        uint expectedDebtRepaid = borrowAmount / 4; // 25% of debt
        
        // Get position info before liquidation
        uint preDebt = lender.getDebtOf(borrower);
        uint preCollateral = lender._cachedCollateralBalances(borrower);
        
        // Liquidate the position
        vm.startPrank(liquidator);
        coin.approve(address(lender), expectedDebtRepaid);
        uint collateralReceived = lender.liquidate(borrower, expectedDebtRepaid, 0);
        vm.stopPrank();
        
        // Verify liquidation results
        assertLt(lender.getDebtOf(borrower), preDebt, "Borrower debt should decrease");
        assertLt(lender._cachedCollateralBalances(borrower), preCollateral, "Borrower collateral should decrease");
        
        // Verify liquidator received the expected collateral
        assertEq(collateral.balanceOf(liquidator), collateralReceived, "Liquidator should receive collateral");
        
        // Verify debt repaid
        assertEq(preDebt - lender.getDebtOf(borrower), expectedDebtRepaid, "Correct amount of debt should be repaid");
        
        // Confirm liquidation bonus was applied (collateral received should be worth more than debt repaid)
        (uint price, , ) = lender.getCollateralPrice();
        uint collateralValue = collateralReceived * price / 1e18;
        assertGt(collateralValue, expectedDebtRepaid, "Liquidator should receive bonus collateral value");
    }
    
    function test_liquidation_maxRepaymentUnderMinLiquidatableDebt() public {
        // Setup: create a position that will become underwater when price changes
        uint collateralAmount = 4000e18;
        uint borrowAmount = collateralAmount * lender.collateralFactor() / 10000;
        
        // Prepare test data
        address borrower = address(0xBEEF);
        address liquidator = address(0xCAFE);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        FeedMock feed = FeedMock(address(lender.feed()));
        
        // Mint coins to liquidator (full debt amount)
        coin.mint(liquidator, borrowAmount); 
        
        // Setup: mint collateral to borrower
        collateral.mint(borrower, collateralAmount);
        
        // Setup: approve collateral for lender
        vm.startPrank(borrower);
        collateral.approve(address(lender), collateralAmount);
        
        // Deposit collateral and borrow
        lender.adjust(borrower, int256(collateralAmount), int256(borrowAmount));
        vm.stopPrank();
        
        // Make the position severely underwater
        feed.setPrice(0.5e18-1);
        
        // Get position info before liquidation
        uint preDebt = lender.getDebtOf(borrower);
        uint preCollateral = lender._cachedCollateralBalances(borrower);
        
        // Liquidate using max amount (type(uint256).max)
        vm.startPrank(liquidator);
        coin.approve(address(lender), borrowAmount); // approve full repayment
        uint collateralReceived = lender.liquidate(borrower, type(uint256).max, 0);
        vm.stopPrank();
        
        // The max repayment should be capped at the liquidatable amount
        assertGt(collateralReceived, 0, "Liquidator should receive collateral");
        assertLt(lender.getDebtOf(borrower), preDebt, "Borrower debt should decrease");
        assertLt(lender._cachedCollateralBalances(borrower), preCollateral, "Borrower collateral should decrease");
    }
    
    function test_liquidation_revertIfNotLiquidatable() public {
        // Setup: create a safe position
        uint collateralAmount = 4000e18;
        uint borrowAmount = collateralAmount * lender.collateralFactor() / 20000; // Only 25% of capacity
        
        // Prepare test data
        address borrower = address(0xBEEF);
        address liquidator = address(0xCAFE);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        
        // Mint coins to liquidator
        coin.mint(liquidator, borrowAmount);
        
        // Setup: mint collateral to borrower
        collateral.mint(borrower, collateralAmount);
        
        // Setup: approve collateral for lender
        vm.startPrank(borrower);
        collateral.approve(address(lender), collateralAmount);
        
        // Deposit collateral and borrow
        lender.adjust(borrower, int256(collateralAmount), int256(borrowAmount));
        vm.stopPrank();
        
        // Price remains the same (position is safe)
        
        // Attempt to liquidate (should revert)
        vm.startPrank(liquidator);
        coin.approve(address(lender), borrowAmount);
        
        vm.expectRevert("insufficient liquidatable debt");
        lender.liquidate(borrower, borrowAmount, 0);
        
        vm.stopPrank();
    }
    
    function test_liquidation_revertIfPriceFeedDisabled() public {
        // Setup: create a position
        uint collateralAmount = 4000e18;
        uint borrowAmount = collateralAmount * lender.collateralFactor() / 20000; // Only 25% of capacity
        
        // Prepare test data
        address borrower = address(0xBEEF);
        address liquidator = address(0xCAFE);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        FeedMock feed = FeedMock(address(lender.feed()));
        
        // Mint coins to liquidator
        coin.mint(liquidator, borrowAmount);
        
        // Setup: mint collateral to borrower
        collateral.mint(borrower, collateralAmount);
        
        // Setup: approve collateral for lender
        vm.startPrank(borrower);
        collateral.approve(address(lender), collateralAmount);
        
        // Deposit collateral and borrow
        lender.adjust(borrower, int256(collateralAmount), int256(borrowAmount));
        vm.stopPrank();
        
        // Disable price feed (make it revert)
        feed.setShouldRevert(true);
        
        // Attempt to liquidate (should revert because liquidations are disabled when feed reverts)
        vm.startPrank(liquidator);
        coin.approve(address(lender), borrowAmount);
        
        vm.expectRevert("liquidations disabled");
        lender.liquidate(borrower, borrowAmount, 0);
        
        vm.stopPrank();
    }
    
    function test_liquidation_revertIfMinCollateralOutNotMet() public {
        // Setup: create a position that will become underwater
        uint collateralAmount = 4000e18;
        uint borrowAmount = collateralAmount * lender.collateralFactor() / 20000; // Using 25% of capacity
        
        // Prepare test data
        address borrower = address(0xBEEF);
        address liquidator = address(0xCAFE);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        FeedMock feed = FeedMock(address(lender.feed()));
        
        // Mint coins to liquidator
        coin.mint(liquidator, borrowAmount);
        
        // Setup: mint collateral to borrower
        collateral.mint(borrower, collateralAmount);
        
        // Setup: approve collateral for lender
        vm.startPrank(borrower);
        collateral.approve(address(lender), collateralAmount);
        
        // Deposit collateral and borrow
        lender.adjust(borrower, int256(collateralAmount), int256(borrowAmount));
        vm.stopPrank();
        
        // Make the position underwater
        feed.setPrice(0.4e18);
        
        // Calculate debt to be repaid
        uint expectedDebtRepaid = borrowAmount / 4; // 25% of debt
        
        // Attempt to liquidate with unrealistically high minCollateralOut
        vm.startPrank(liquidator);
        coin.approve(address(lender), expectedDebtRepaid);
        
        // The expected collateral out would be around borrowAmount * 1.01 * 2.5 = borrowAmount * 2.525
        // Setting a value higher than this should cause revert
        uint unrealisticMinCollateralOut = borrowAmount * 3; // 3x the debt amount
        
        vm.expectRevert("insufficient collateral out");
        lender.liquidate(borrower, expectedDebtRepaid, unrealisticMinCollateralOut);
        
        vm.stopPrank();
    }
    
    function test_writeOff_success() public {
        // Setup: create a severely underwater position
        uint collateralAmount = 4000e18;
        uint borrowAmount = collateralAmount * lender.collateralFactor() / 10000; // Using 50% of capacity
        
        // Prepare test data
        address borrower = address(0xBEEF);
        address otherBorrower = address(0xF00D); // Add another borrower for debt redistribution
        address liquidator = address(0xCAFE);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        FeedMock feed = FeedMock(address(lender.feed()));
        
        // Setup: mint collateral to both borrowers
        collateral.mint(borrower, collateralAmount);
        collateral.mint(otherBorrower, collateralAmount);
        
        // Setup: borrower 1 deposits collateral and borrows
        vm.startPrank(borrower);
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(borrower, int256(collateralAmount), int256(borrowAmount));
        vm.stopPrank();
        
        // Setup: borrower 2 (other borrower) also deposits collateral and borrows
        vm.startPrank(otherBorrower);
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(otherBorrower, int256(collateralAmount), int256(borrowAmount));
        vm.stopPrank();
        
        // Make the first position severely underwater (price drops by 99.9%)
        feed.setPrice(0.001e18);
        
        // Get initial values
        uint initialDebt = lender.getDebtOf(borrower);
        uint initialCollateral = lender._cachedCollateralBalances(borrower);
        uint initialTotalFreeDebt = lender.totalFreeDebt();
        uint initialTotalPaidDebt = lender.totalPaidDebt();
        uint otherBorrowerInitialDebt = lender.getDebtOf(otherBorrower);
        
        // Execute write-off
        vm.prank(liquidator);
        bool result = lender.writeOff(borrower);
        
        // Verify write-off was successful
        assertTrue(result, "Write-off should be successful");
        
        // Verify borrower's debt is zero
        assertEq(lender.getDebtOf(borrower), 0, "Borrower's debt should be zero after write-off");
        
        // Verify borrower's collateral is zero
        assertEq(lender._cachedCollateralBalances(borrower), 0, "Borrower's collateral should be zero after write-off");
        
        // Verify liquidator received all collateral
        assertEq(collateral.balanceOf(liquidator), initialCollateral, "Liquidator should receive all borrower's collateral");
        
        // Verify debt was redistributed (total debt should still include the written off debt)
        assertEq(lender.totalFreeDebt() + lender.totalPaidDebt(), initialTotalFreeDebt + initialTotalPaidDebt, 
                 "Total debt should remain the same after write-off (redistributed)");
        
        // Verify other borrower's debt has increased due to redistribution
        assertGt(lender.getDebtOf(otherBorrower), otherBorrowerInitialDebt, 
                "Other borrower's debt should increase after write-off due to redistribution");
    }
    
    function test_writeOff_notDeepEnoughUnderwater() public {
        // Setup: create a position that's underwater but not deeply enough for write-off
        uint collateralAmount = 4000e18;
        uint borrowAmount = collateralAmount * lender.collateralFactor() / 20000; // Using 25% of capacity
        
        // Prepare test data
        address borrower = address(0xBEEF);
        address liquidator = address(0xCAFE);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        FeedMock feed = FeedMock(address(lender.feed()));
        
        // Setup: mint collateral to borrower
        collateral.mint(borrower, collateralAmount);
        
        // Setup: approve collateral for lender
        vm.startPrank(borrower);
        collateral.approve(address(lender), collateralAmount);
        
        // Deposit collateral and borrow
        lender.adjust(borrower, int256(collateralAmount), int256(borrowAmount));
        vm.stopPrank();
        
        // Make the position underwater but not by 100x (price drops by 75%)
        feed.setPrice(0.25e18);
        
        // Execute write-off (should return false because debt is not 100x the collateral value)
        vm.prank(liquidator);
        bool result = lender.writeOff(borrower);
        
        // Verify result is false
        assertFalse(result, "Write-off should not succeed if position isn't deeply underwater");
        
        // Verify debt and collateral remain unchanged
        assertGt(lender.getDebtOf(borrower), 0, "Borrower's debt should remain after failed write-off");
        assertEq(lender._cachedCollateralBalances(borrower), collateralAmount, "Borrower's collateral should remain after failed write-off");
    }

    function test_redeem_basic() public {
        // Setup: create a scenario with free debt (redeemable)
        uint collateralAmount = 5000e18;
        uint borrowAmount = 2000e18;
        uint redeemAmount = 1000e18;
        
        // Prepare test data
        address borrower = address(0xBEEF);
        address redeemer = address(0xCAFE);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        
        // Setup: mint collateral to borrower and coins to redeemer
        collateral.mint(borrower, collateralAmount);
        coin.mint(redeemer, redeemAmount);
        
        // Setup: borrower creates a redeemable position
        vm.startPrank(borrower);
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(borrower, int256(collateralAmount), int256(borrowAmount), true); // opt into redemptions
        vm.stopPrank();
        
        // Verify borrower has redeemable debt
        assertTrue(lender.isRedeemable(borrower), "Borrower should have redeemable debt");
        assertEq(lender.totalFreeDebt(), borrowAmount, "Total free debt should match borrowed amount");
        assertEq(lender.getDebtOf(borrower), borrowAmount, "Borrower's debt should match borrowed amount");
        
        // Calculate expected collateral out based on redeem fee
        uint redeemFeeBps = lender.redeemFeeBps();
        uint expectedCollateralOut = redeemAmount * (10000 - redeemFeeBps) / 10000; // 1:1 price with fee applied
        
        // Redeemer exchanges Coin for collateral
        vm.startPrank(redeemer);
        coin.approve(address(lender), redeemAmount);
        uint collateralOut = lender.redeem(redeemAmount, expectedCollateralOut);
        vm.stopPrank();
        
        // Verify results
        assertEq(collateralOut, expectedCollateralOut, "Collateral out should match expected amount");
        assertEq(collateral.balanceOf(redeemer), expectedCollateralOut, "Redeemer should receive expected collateral");
        assertEq(lender.totalFreeDebt(), borrowAmount - redeemAmount, "Total free debt should be reduced by redeem amount");
        
        lender.updateBorrower(borrower);
        assertEq(lender._cachedCollateralBalances(borrower), collateralAmount - collateralOut, "Borrower's collateral should be reduced by redeem amount");
        assertEq(lender.getDebtOf(borrower), borrowAmount - redeemAmount, "Borrower's debt should be reduced by redeem amount");
    }
    
    function test_redeem_withMultipleBorrowers() public {
        // Setup: create multiple borrowers with redeemable debt
        uint collateralAmount = 5000e18;
        uint borrowAmount = 1000e18;
        uint redeemAmount = 1500e18;
        
        // Prepare test data
        address borrower1 = address(0xBEEF);
        address borrower2 = address(0xF00D);
        address redeemer = address(0xCAFE);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        
        // Setup: mint collateral to borrowers and coins to redeemer
        collateral.mint(borrower1, collateralAmount);
        collateral.mint(borrower2, collateralAmount);
        coin.mint(redeemer, redeemAmount);
        
        // Setup: borrower1 creates a redeemable position
        vm.startPrank(borrower1);
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(borrower1, int256(collateralAmount), int256(borrowAmount), true); // opt into redemptions
        vm.stopPrank();
        
        // Setup: borrower2 creates a redeemable position
        vm.startPrank(borrower2);
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(borrower2, int256(collateralAmount), int256(borrowAmount), true); // opt into redemptions
        vm.stopPrank();
        
        // Verify both borrowers have redeemable debt
        assertTrue(lender.isRedeemable(borrower1), "Borrower1 should have redeemable debt");
        assertTrue(lender.isRedeemable(borrower2), "Borrower2 should have redeemable debt");
        assertEq(lender.totalFreeDebt(), borrowAmount * 2, "Total free debt should match combined borrowed amount");
        
        // Calculate expected collateral out based on redeem fee
        uint redeemFeeBps = lender.redeemFeeBps();
        uint expectedCollateralOut = redeemAmount * (10000 - redeemFeeBps) / 10000; // 1:1 price with fee applied
        
        // Redeemer exchanges Coin for collateral
        vm.startPrank(redeemer);
        coin.approve(address(lender), redeemAmount);
        lender.redeem(redeemAmount, expectedCollateralOut);
        vm.stopPrank();
        
        // Verify results
        assertEq(collateral.balanceOf(redeemer), expectedCollateralOut, "Collateral out should match expected amount");
        assertEq(collateral.balanceOf(redeemer), expectedCollateralOut, "Redeemer should receive expected collateral");
        assertEq(lender.totalFreeDebt(), borrowAmount * 2 - redeemAmount, "Total free debt should be reduced by redeem amount");

        lender.updateBorrower(borrower1);
        assertEq(lender._cachedCollateralBalances(borrower1), collateralAmount - (expectedCollateralOut / 2), "Borrower1's collateral should be reduced by redeem amount");
        assertEq(lender.getDebtOf(borrower1), borrowAmount - (redeemAmount / 2), "Borrower1's debt should be reduced by redeem amount");

        lender.updateBorrower(borrower2);
        assertEq(lender._cachedCollateralBalances(borrower2), collateralAmount - (expectedCollateralOut / 2), "Borrower2's collateral should be reduced by redeem amount");
        assertEq(lender.getDebtOf(borrower2), borrowAmount - (redeemAmount / 2), "Borrower2's debt should be reduced by redeem amount");
    }
    
    function test_redeem_withDifferentPrice() public {
        // Setup: create a scenario with free debt (redeemable) and change price
        uint collateralAmount = 5000e18;
        uint borrowAmount = 2000e18;
        uint redeemAmount = 1000e18;
        
        // Prepare test data
        address borrower = address(0xBEEF);
        address redeemer = address(0xCAFE);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        FeedMock feed = FeedMock(address(lender.feed()));
        
        // Setup: mint collateral to borrower and coins to redeemer
        collateral.mint(borrower, collateralAmount);
        coin.mint(redeemer, redeemAmount);
        
        // Setup: borrower creates a redeemable position
        vm.startPrank(borrower);
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(borrower, int256(collateralAmount), int256(borrowAmount), true); // opt into redemptions
        vm.stopPrank();
        
        // Change price to 2x (collateral is now worth 2 coins per unit)
        feed.setPrice(2e18);
        
        // Calculate expected collateral out based on new price and redeem fee
        uint redeemFeeBps = lender.redeemFeeBps();
        uint expectedCollateralOut = redeemAmount * (10000 - redeemFeeBps) / 10000 / 2; // 2:1 price with fee applied
        
        // Redeemer exchanges Coin for collateral
        vm.startPrank(redeemer);
        coin.approve(address(lender), redeemAmount);
        lender.redeem(redeemAmount, expectedCollateralOut);
        vm.stopPrank();
        
        // Verify results
        assertEq(collateral.balanceOf(redeemer), expectedCollateralOut, "Collateral out should match expected amount");
        assertEq(collateral.balanceOf(redeemer), expectedCollateralOut, "Redeemer should receive expected collateral");
        assertEq(lender.totalFreeDebt(), borrowAmount - redeemAmount, "Total free debt should be reduced by redeem amount");

        lender.updateBorrower(borrower);
        assertEq(lender._cachedCollateralBalances(borrower), collateralAmount - expectedCollateralOut, "Borrower's collateral should be reduced by redeem amount");
        assertEq(lender.getDebtOf(borrower), borrowAmount - redeemAmount, "Borrower's debt should be reduced by redeem amount");
    }
    
    function test_redeem_withCustomRedeemFee() public {
        // Setup: create a scenario with free debt (redeemable) and change the redeem fee
        uint collateralAmount = 5000e18;
        uint borrowAmount = 2000e18;
        uint redeemAmount = 1000e18;
        uint newRedeemFeeBps = 100; // 1%
        
        // Prepare test data
        address borrower = address(0xBEEF);
        address redeemer = address(0xCAFE);
        address operatorAddr = lender.operator();
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        
        // Setup: mint collateral to borrower and coins to redeemer
        collateral.mint(borrower, collateralAmount);
        coin.mint(redeemer, redeemAmount);
        
        // Setup: borrower creates a redeemable position
        vm.startPrank(borrower);
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(borrower, int256(collateralAmount), int256(borrowAmount), true); // opt into redemptions
        vm.stopPrank();
        
        // Change the redeem fee
        vm.prank(operatorAddr);
        lender.setRedeemFeeBps(uint16(newRedeemFeeBps));
        
        // Verify the fee has been updated
        assertEq(lender.redeemFeeBps(), newRedeemFeeBps, "Redeem fee should be updated");
        
        // Calculate expected collateral out based on new fee
        uint expectedCollateralOut = redeemAmount * (10000 - newRedeemFeeBps) / 10000; // 1:1 price with new fee applied
        
        // Redeemer exchanges Coin for collateral
        vm.startPrank(redeemer);
        coin.approve(address(lender), redeemAmount);
        lender.redeem(redeemAmount, expectedCollateralOut);
        vm.stopPrank();
        
        // Verify results
        assertEq(collateral.balanceOf(redeemer), expectedCollateralOut, "Collateral out should match expected amount with new fee");
        assertEq(collateral.balanceOf(redeemer), expectedCollateralOut, "Redeemer should receive expected collateral");

        lender.updateBorrower(borrower);
        assertEq(lender._cachedCollateralBalances(borrower), collateralAmount - expectedCollateralOut, "Borrower's collateral should be reduced by redeem amount");
        assertEq(lender.getDebtOf(borrower), borrowAmount - redeemAmount, "Borrower's debt should be reduced by redeem amount");
    }
    
    function test_redeem_AllFreeDebtReverts() public {
        // Setup: create a scenario with less free debt than redeem amount
        uint collateralAmount = 5000e18;
        uint borrowAmount = 1000e18;
        uint redeemAmount = 1000e18; // the entire free debt
        
        // Prepare test data
        address borrower = address(0xBEEF);
        address redeemer = address(0xCAFE);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        
        // Setup: mint collateral to borrower and coins to redeemer
        collateral.mint(borrower, collateralAmount);
        coin.mint(redeemer, redeemAmount);
        
        // Setup: borrower creates a redeemable position
        vm.startPrank(borrower);
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(borrower, int256(collateralAmount), int256(borrowAmount), true); // opt into redemptions
        vm.stopPrank();
        
        // Verify state before redemption
        assertEq(lender.totalFreeDebt(), borrowAmount, "Total free debt should match borrowed amount");
        
        // Attempt to redeem more than available free debt
        vm.startPrank(redeemer);
        coin.approve(address(lender), redeemAmount);
        
        // This should revert when calling getRedeemAmountOut inside redeem function
        vm.expectRevert();
        lender.redeem(redeemAmount, 0);
        
        vm.stopPrank();
    }
    
    function test_redeem_withInsufficientAmountOutReverts() public {
        // Setup: create a scenario with free debt (redeemable)
        uint collateralAmount = 5000e18;
        uint borrowAmount = 2000e18;
        uint redeemAmount = 1000e18;
        
        // Prepare test data
        address borrower = address(0xBEEF);
        address redeemer = address(0xCAFE);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        
        // Setup: mint collateral to borrower and coins to redeemer
        collateral.mint(borrower, collateralAmount);
        coin.mint(redeemer, redeemAmount);
        
        // Setup: borrower creates a redeemable position
        vm.startPrank(borrower);
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(borrower, int256(collateralAmount), int256(borrowAmount), true); // opt into redemptions
        vm.stopPrank();
        
        // Calculate expected collateral out based on redeem fee
        uint redeemFeeBps = lender.redeemFeeBps();
        uint expectedCollateralOut = redeemAmount * (10000 - redeemFeeBps) / 10000; // 1:1 price with fee applied
        
        // Set minimum amount out higher than expected output
        uint tooHighMinAmountOut = expectedCollateralOut + 1;
        
        // Attempt to redeem with too high minAmountOut
        vm.startPrank(redeemer);
        coin.approve(address(lender), redeemAmount);
        
        vm.expectRevert("insufficient amount out");
        lender.redeem(redeemAmount, tooHighMinAmountOut);
        
        vm.stopPrank();
    }
    
    function test_redeem_withDisallowedLiquidationsMode() public {
        // Setup: create a scenario with free debt (redeemable)
        uint collateralAmount = 5000e18;
        uint borrowAmount = 2000e18;
        uint redeemAmount = 1000e18;
        
        // Prepare test data
        address borrower = address(0xBEEF);
        address redeemer = address(0xCAFE);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        FeedMock feed = FeedMock(address(lender.feed()));
        
        // Setup: mint collateral to borrower and coins to redeemer
        collateral.mint(borrower, collateralAmount);
        coin.mint(redeemer, redeemAmount);
        
        // Setup: borrower creates a redeemable position
        vm.startPrank(borrower);
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(borrower, int256(collateralAmount), int256(borrowAmount), true); // opt into redemptions
        vm.stopPrank();
        
        // Enable the feed to revert to trigger disallowed liquidations mode
        feed.setShouldRevert(true);
        
        // Attempt to redeem in disallowed liquidations mode (should fail)
        vm.startPrank(redeemer);
        coin.approve(address(lender), redeemAmount);
        
        // In disallowed liquidations mode, getRedeemAmountOut should return 0
        uint out = lender.redeem(redeemAmount, 0);
        assertEq(out, 0, "In disallowed liquidations mode, redeem should return 0");
        vm.stopPrank();
    }
    
    function test_redeem_triggersNewEpoch() public {
        // Setup: create a scenario where redeem causes a new epoch (totalFreeDebtShares / totalFreeDebt > 1e18)
        uint collateralAmount = 5000e18;
        uint borrowAmount = 2000e18;
        uint redeemAmount = 2000e18-1; // Almost all the free debt
        
        // Prepare test data
        address borrower = address(0xBEEF);
        address redeemer = address(0xCAFE);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        
        // Setup: mint collateral to borrower and coins to redeemer
        collateral.mint(borrower, collateralAmount);
        coin.mint(redeemer, redeemAmount);
        
        // Setup: borrower creates a redeemable position
        vm.startPrank(borrower);
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(borrower, int256(collateralAmount), int256(borrowAmount), true); // opt into redemptions
        vm.stopPrank();
        
        // Get initial epoch and debt shares
        uint initialEpoch = lender.epoch();
        uint initialDebtShares = lender.totalFreeDebtShares();
        
        // Calculate expected collateral out
        uint redeemFeeBps = lender.redeemFeeBps();
        uint expectedCollateralOut = redeemAmount * (10000 - redeemFeeBps) / 10000;
        
        // Redeemer exchanges Coin for collateral
        vm.startPrank(redeemer);
        coin.approve(address(lender), redeemAmount);
        lender.redeem(redeemAmount, expectedCollateralOut);
        vm.stopPrank();
        
        // Verify a new epoch was created
        uint newEpoch = lender.epoch();
        uint newDebtShares = lender.totalFreeDebtShares();
        
        assertEq(newEpoch, initialEpoch + 1, "A new epoch should be created");
        assertLt(newDebtShares, initialDebtShares, "Debt shares should be reduced in new epoch");
    }
    
    function test_redeem_epochRedeemedCollateralUpdates() public {
        // Setup: create a scenario with free debt (redeemable)
        uint collateralAmount = 5000e18;
        uint borrowAmount = 2000e18;
        uint redeemAmount = 1000e18;
        
        // Prepare test data
        address borrower = address(0xBEEF);
        address redeemer = address(0xCAFE);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        
        // Setup: mint collateral to borrower and coins to redeemer
        collateral.mint(borrower, collateralAmount);
        coin.mint(redeemer, redeemAmount);
        
        // Setup: borrower creates a redeemable position
        vm.startPrank(borrower);
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(borrower, int256(collateralAmount), int256(borrowAmount), true); // opt into redemptions
        vm.stopPrank();
        
        // Get current epoch
        uint currentEpoch = lender.epoch();
        uint initialEpochRedeemed = lender.epochRedeemedCollateral(currentEpoch);
        
        // Calculate expected collateral out
        uint redeemFeeBps = lender.redeemFeeBps();
        uint expectedCollateralOut = redeemAmount * (10000 - redeemFeeBps) / 10000;
        
        // Redeemer exchanges Coin for collateral
        vm.startPrank(redeemer);
        coin.approve(address(lender), redeemAmount);
        lender.redeem(redeemAmount, expectedCollateralOut);
        vm.stopPrank();
        
        // Check that epochRedeemedCollateral was updated
        uint updatedEpochRedeemed = lender.epochRedeemedCollateral(currentEpoch);
        assertGt(updatedEpochRedeemed, initialEpochRedeemed, "Epoch redeemed collateral should increase");
        
        // Calculate expected update to the epoch redeemed collateral
        uint expectedIndex = expectedCollateralOut * 1e18 / lender.totalFreeDebtShares();
        assertEq(updatedEpochRedeemed - initialEpochRedeemed, expectedIndex, "Epoch redeemed collateral should increase by the correct amount");
    }
    
    function test_redeem_updateBorrowerReducesCollateral() public {
        // Setup: create a scenario with free debt (redeemable)
        uint collateralAmount = 5000e18;
        uint borrowAmount = 2000e18;
        uint redeemAmount = 1000e18;
        
        // Prepare test data
        address borrower = address(0xBEEF);
        address redeemer = address(0xCAFE);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        
        // Setup: mint collateral to borrower and coins to redeemer
        collateral.mint(borrower, collateralAmount);
        coin.mint(redeemer, redeemAmount);
        
        // Setup: borrower creates a redeemable position
        vm.startPrank(borrower);
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(borrower, int256(collateralAmount), int256(borrowAmount), true); // opt into redemptions
        vm.stopPrank();
        
        // Get borrower's initial collateral balance
        uint initialCollateralBalance = lender._cachedCollateralBalances(borrower);
        
        // Calculate expected collateral out
        uint redeemFeeBps = lender.redeemFeeBps();
        uint expectedCollateralOut = redeemAmount * (10000 - redeemFeeBps) / 10000;
        
        // Redeemer exchanges Coin for collateral
        vm.startPrank(redeemer);
        coin.approve(address(lender), redeemAmount);
        lender.redeem(redeemAmount, expectedCollateralOut);
        vm.stopPrank();
        
        // The first redeem doesn't immediately affect the borrower's balance, 
        // it only updates the epochRedeemedCollateral
        
        lender.updateBorrower(borrower);
        
        // After updateBorrower, the borrower's collateral should be reduced
        uint newCollateralBalance = lender._cachedCollateralBalances(borrower);
        assertEq(newCollateralBalance, initialCollateralBalance - expectedCollateralOut, "Borrower's collateral should be reduced after updateBorrower");
        
        // The reduction should be proportional to their debt share of the redeemed amount
        uint borrowerDebtShare = lender.freeDebtShares(borrower);
        uint totalDebtShares = lender.totalFreeDebtShares();
        uint expectedReduction = expectedCollateralOut * borrowerDebtShare / totalDebtShares;
        
        assertEq(initialCollateralBalance - newCollateralBalance, expectedReduction, 
            "Borrower's collateral reduction should be proportional to their debt share");
    }
    
    function test_redeem_updateBorrowerReducesCollateralMultipleBorrowers() public {
        // Setup: create 2 borrowers with different collateral and debt amounts
        uint collateralAmount = 5000e18;
                
        // those were commented to save on stack space
        // address borrower1 = address(0xBEEF);
        // address borrower2 = address(0xF00D);
        address redeemer = address(0xCAFE);
        
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        
        // Setup: mint collateral to borrowers and coins to redeemer
        collateral.mint(address(0xBEEF), collateralAmount);
        collateral.mint(address(0xF00D), collateralAmount);
        uint redeemAmount = 1500e18; // Redeem 50% of total debt
        coin.mint(redeemer, redeemAmount);
        
        // Setup: borrowers create redeemable positions
        vm.startPrank(address(0xBEEF));
        collateral.approve(address(lender), collateralAmount);
        uint borrowAmount = 2000e18;
        lender.adjust(address(0xBEEF), int256(collateralAmount), int256(borrowAmount), true);
        vm.stopPrank();
        
        vm.startPrank(address(0xF00D));
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(address(0xF00D), int256(collateralAmount), int256(borrowAmount), true);
        vm.stopPrank();
        
        // Get total free debt and store initial collateral balances
        uint totalFreeDebt = lender.totalFreeDebt();
        uint totalFreeDebtShares = lender.totalFreeDebtShares();
        
        uint initialCollateralBalance1 = lender._cachedCollateralBalances(address(0xBEEF));
        uint initialCollateralBalance2 = lender._cachedCollateralBalances(address(0xF00D));
        
        // Store debt shares for each borrower
        uint debtShares1 = lender.freeDebtShares(address(0xBEEF));
        uint debtShares2 = lender.freeDebtShares(address(0xF00D));
        
        // Calculate expected collateral out based on redeem fee
        uint redeemFeeBps = lender.redeemFeeBps();
        uint expectedCollateralOut = redeemAmount * (10000 - redeemFeeBps) / 10000;
        
        // Perform redemption
        vm.startPrank(redeemer);
        uint _redeemAmount = redeemAmount;
        coin.approve(address(lender), _redeemAmount);
        uint collateralOut = lender.redeem(_redeemAmount, expectedCollateralOut);
        vm.stopPrank();
        
        // Verify redemption results
        address _redeemer = redeemer;
        assertEq(collateralOut, expectedCollateralOut, "Collateral out should match expected amount");
        assertEq(collateral.balanceOf(_redeemer), collateralOut, "Redeemer should receive expected collateral");
        assertEq(lender.totalFreeDebt(), totalFreeDebt - _redeemAmount, "Total free debt should be reduced by redeem amount");
        
        // Call updateBorrower for each borrower and verify collateral reduction
        lender.updateBorrower(address(0xBEEF)); // borrower1
        lender.updateBorrower(address(0xF00D)); // borrower2
        
        // Calculate expected collateral reduction for each borrower based on their debt share
        uint expectedReduction1 = expectedCollateralOut * debtShares1 / totalFreeDebtShares;
        uint expectedReduction2 = expectedCollateralOut * debtShares2 / totalFreeDebtShares;
        
        // Verify final collateral balances
        assertEq(lender._cachedCollateralBalances(address(0xBEEF)), initialCollateralBalance1 - expectedReduction1, 
            "Borrower1's collateral should be reduced proportionally to debt share");
        assertEq(lender._cachedCollateralBalances(address(0xF00D)), initialCollateralBalance2 - expectedReduction2, 
            "Borrower2's collateral should be reduced proportionally to debt share");
        
        // Verify final debt for each borrower
        uint expectedDebtReduction1 = _redeemAmount * debtShares1 / totalFreeDebtShares;
        uint expectedDebtReduction2 = _redeemAmount * debtShares2 / totalFreeDebtShares;
        uint _borrowAmount = 2000e18; // stack too deep
        assertEq(lender.getDebtOf(address(0xBEEF)), _borrowAmount - expectedDebtReduction1, 
            "Borrower1's debt should be reduced proportionally to debt share");
        assertEq(lender.getDebtOf(address(0xF00D)), _borrowAmount - expectedDebtReduction2, 
            "Borrower2's debt should be reduced proportionally to debt share");
        
        // Verify that the sum of reductions equals the total collateral out (within rounding error)
        uint totalReduction = expectedReduction1 + expectedReduction2;
        assertEq(totalReduction, expectedCollateralOut, "Sum of collateral reductions should equal total collateral out");
        
        // Verify that the sum of debt reductions equals the total redeem amount (within rounding error)
        uint totalDebtReduction = expectedDebtReduction1 + expectedDebtReduction2;
        assertEq(totalDebtReduction, _redeemAmount, "Sum of debt reductions should equal total redeem amount");
    }
}