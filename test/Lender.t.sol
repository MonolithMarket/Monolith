// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Lender, ERC20, Coin, Vault, InterestModel, IChainlinkFeed, IFactory} from "src/Lender.sol";

contract FeedMock {

    uint8 public decimals = 18;
    bool public shouldRevert;

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
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
        return (0, 1e18, 0, 0, 0);
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

}