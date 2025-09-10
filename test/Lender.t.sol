// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

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

    function getFeeOf(address) external view returns (uint) {
        return fee;
    }

    function setFee(uint newFee) external {
        fee = newFee;
    }
}

contract LenderTest is Test {

    Lender lender;
    address public operatorAddr;
       Lens lens = Lens(address(0xedb597C9715c648e4cf546464d365D5923d7F6c8));
    function setUp() public {
        // Set operator address
        operatorAddr = address(0x123);
        
        // deploy lender
        address managerAddr = address(0x456);
        lender = new Lender(
            ERC20(address(new ERC20Mock("Collateral", "COL"))),
            ERC20(address(0)), // optional PSM asset
            ERC4626(address(0)), // optional PSM vault
            IChainlinkFeed(address(new FeedMock())),
            Coin(address(new ERC20Mock("Coin", "COIN"))),
            Vault(address(new VaultMock())),
            InterestModel(address(new InterestModelMock())),
            IFactory(address(new FactoryMock())),
            operatorAddr, // use operator address
            managerAddr, // manager address
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
        address newManagerAddr = address(0x789);
        Lender newLender = new Lender(
            ERC20(address(newCollateral)),
            ERC20(address(0)), // optional PSM asset
            ERC4626(address(0)), // optional PSM vault
            IChainlinkFeed(address(newFeed)),
            Coin(address(newCoin)),
            Vault(address(newVault)),
            InterestModel(address(newInterestModel)),
            IFactory(address(newFactory)),
            operatorAddr, // use operator address
            newManagerAddr, // manager address
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

    function test_repay_multipleUsers(uint borrowAmount1, uint borrowAmount2) public {
        // Bound amounts to prevent overflows and ensure valid debt amounts
        borrowAmount1 = bound(borrowAmount1, lender.minDebt() * 2, lender.minDebt() * 4);
        borrowAmount2 = bound(borrowAmount2, lender.minDebt() * 2, lender.minDebt() * 3);
        
        address borrower1 = address(0xBEEF);
        address borrower2 = address(0xF00D);
        address repayer = address(0xDEAD);
        
        uint collateralAmount = lender.minDebt() * 8; // Large enough for both borrowers
        
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        
        // Setup: mint collateral to both borrowers
        collateral.mint(borrower1, collateralAmount);
        collateral.mint(borrower2, collateralAmount);
        
        // Setup: mint coins to repayer for all repayments
        uint totalRepayAmount = borrowAmount1 + borrowAmount2;
        coin.mint(repayer, totalRepayAmount);
        
        // Setup: borrower1 deposits collateral and borrows
        vm.startPrank(borrower1);
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(borrower1, int256(collateralAmount), int256(borrowAmount1));
        vm.stopPrank();
        
        // Setup: borrower2 deposits collateral and borrows
        vm.startPrank(borrower2);
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(borrower2, int256(collateralAmount), int256(borrowAmount2));
        vm.stopPrank();
        
        // Verify initial state
        assertEq(lender.getDebtOf(borrower1), borrowAmount1, "Borrower1 initial debt incorrect");
        assertEq(lender.getDebtOf(borrower2), borrowAmount2, "Borrower2 initial debt incorrect");
        assertEq(coin.balanceOf(borrower1), borrowAmount1, "Borrower1 initial coin balance incorrect");
        assertEq(coin.balanceOf(borrower2), borrowAmount2, "Borrower2 initial coin balance incorrect");
        
        // Calculate partial repayment amounts (repay half of each borrower's debt)
        uint repayAmount1 = borrowAmount1 / 2;
        uint repayAmount2 = borrowAmount2 / 2;
        
        // Execute: repayer repays partial debt for both borrowers
        vm.startPrank(repayer);
        coin.approve(address(lender), totalRepayAmount);
        
        // Repay for borrower1
        lender.adjust(borrower1, 0, -int256(repayAmount1));
        
        // Repay for borrower2
        lender.adjust(borrower2, 0, -int256(repayAmount2));
        
        vm.stopPrank();
        
        // Verify state after partial repayments
        assertEq(lender.getDebtOf(borrower1), borrowAmount1 - repayAmount1, "Borrower1 debt incorrect after partial repayment");
        assertEq(lender.getDebtOf(borrower2), borrowAmount2 - repayAmount2, "Borrower2 debt incorrect after partial repayment");
        
        // Verify borrowers' coin balances remain unchanged (repayer paid from their own balance)
        assertEq(coin.balanceOf(borrower1), borrowAmount1, "Borrower1 coin balance should remain unchanged");
        assertEq(coin.balanceOf(borrower2), borrowAmount2, "Borrower2 coin balance should remain unchanged");
        
        // Verify repayer's coin balance decreased by total repaid amount
        uint totalRepaid = repayAmount1 + repayAmount2;
        assertEq(coin.balanceOf(repayer), totalRepayAmount - totalRepaid, "Repayer coin balance incorrect after repayments");
        
        // Execute: full repayment of remaining debt for both borrowers
        uint remainingDebt1 = borrowAmount1 - repayAmount1;
        uint remainingDebt2 = borrowAmount2 - repayAmount2;
        
        vm.startPrank(repayer);
        
        // Full repayment for borrower1
        lender.adjust(borrower1, 0, -int256(remainingDebt1));
        
        // Full repayment for borrower2
        lender.adjust(borrower2, 0, -int256(remainingDebt2));
        
        vm.stopPrank();
        
        // Verify final state - all debts should be zero
        assertEq(lender.getDebtOf(borrower1), 0, "Borrower1 debt should be zero after full repayment");
        assertEq(lender.getDebtOf(borrower2), 0, "Borrower2 debt should be zero after full repayment");
        
        // Verify repayer's coin balance is now zero (used all coins for repayments)
        assertEq(coin.balanceOf(repayer), 0, "Repayer should have used all coins for repayments");
        
        // Verify borrowers still have their original coin balances
        assertEq(coin.balanceOf(borrower1), borrowAmount1, "Borrower1 final coin balance incorrect");
        assertEq(coin.balanceOf(borrower2), borrowAmount2, "Borrower2 final coin balance incorrect");
        
        // Verify collateral balances remain unchanged
        assertEq(lender._cachedCollateralBalances(borrower1), collateralAmount, "Borrower1 collateral should remain unchanged");
        assertEq(lender._cachedCollateralBalances(borrower2), collateralAmount, "Borrower2 collateral should remain unchanged");
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
        uint initialCollateral = lender._cachedCollateralBalances(borrower);
        uint initialTotalFreeDebt = lender.totalFreeDebt();
        uint initialTotalPaidDebt = lender.totalPaidDebt();
        uint otherBorrowerInitialDebt = lender.getDebtOf(otherBorrower);
        
        // Execute write-off
        vm.prank(liquidator);
        bool result = lender.writeOff(borrower, liquidator);
        
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
        bool result = lender.writeOff(borrower, liquidator);
        
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
        
        lender.adjust(borrower, 0, 0);
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

        lender.adjust(borrower1, 0, 0);

        assertEq(lender._cachedCollateralBalances(borrower1), collateralAmount - (expectedCollateralOut / 2), "Borrower1's collateral should be reduced by redeem amount");
        assertEq(lender.getDebtOf(borrower1), borrowAmount - (redeemAmount / 2), "Borrower1's debt should be reduced by redeem amount");

        lender.adjust(borrower2, 0, 0);
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

        lender.adjust(borrower, 0, 0);
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

        lender.adjust(borrower, 0, 0);
        assertEq(lender._cachedCollateralBalances(borrower), collateralAmount - expectedCollateralOut, "Borrower's collateral should be reduced by redeem amount");
        assertEq(lender.getDebtOf(borrower), borrowAmount - redeemAmount, "Borrower's debt should be reduced by redeem amount");
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
        uint expectedIndex = expectedCollateralOut * 1e36 / lender.totalFreeDebtShares();
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
        
        lender.adjust(borrower, 0, 0);
        
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
        uint redeemAmount = 2000e18-1; // Redeem most of total debt
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
        
        uint initialCollateralBalance1 = lender._cachedCollateralBalances(address(0xBEEF));
        uint initialCollateralBalance2 = lender._cachedCollateralBalances(address(0xF00D));
        
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
        lender.adjust(address(0xBEEF), 0, 0); // borrower1
        lender.adjust(address(0xF00D), 0, 0); // borrower2
        
        // Calculate expected collateral reduction for each borrower based on their debt share
        uint expectedReduction1 = expectedCollateralOut / 2;
        uint expectedReduction2 = expectedCollateralOut / 2;
        
        // Verify final collateral balances
        assertApproxEqAbs(lender._cachedCollateralBalances(address(0xBEEF)), initialCollateralBalance1 - expectedReduction1, 1e4,
            "Borrower1's collateral should be reduced proportionally to debt share");
        assertApproxEqAbs(lender._cachedCollateralBalances(address(0xF00D)), initialCollateralBalance2 - expectedReduction2, 1e4,
            "Borrower2's collateral should be reduced proportionally to debt share");
        
        // Verify final debt for each borrower
        uint expectedDebtReduction1 = _redeemAmount / 2;
        uint expectedDebtReduction2 = _redeemAmount / 2;
        uint _borrowAmount = 2000e18; // stack too deep
        assertApproxEqAbs(lender.getDebtOf(address(0xBEEF)), _borrowAmount - expectedDebtReduction1, 1, 
            "Borrower1's debt should be reduced proportionally to debt share");
        assertApproxEqAbs(lender.getDebtOf(address(0xF00D)), _borrowAmount - expectedDebtReduction2, 1, 
            "Borrower2's debt should be reduced proportionally to debt share");
        
        // Verify that the sum of reductions equals the total collateral out (within rounding error)
        uint totalReduction = expectedReduction1 + expectedReduction2;
        assertApproxEqAbs(totalReduction, expectedCollateralOut, 1, "Sum of collateral reductions should equal total collateral out");
        
        // Verify that the sum of debt reductions equals the total redeem amount (within rounding error)
        uint totalDebtReduction = expectedDebtReduction1 + expectedDebtReduction2;
        assertApproxEqAbs(totalDebtReduction, _redeemAmount, 1, "Sum of debt reductions should equal total redeem amount");
    }

    function test_repeated_redemptions_bug(int collateralPrice) public {
        collateralPrice = bound(collateralPrice, 1e16, 1e25);

        // Setup: create multiple borrowers with redeemable debt
        uint collateralAmount1 = 25e24;
        uint collateralAmount2 = 5e23;
        uint borrowAmount1 = 1000e18;
        uint borrowAmount2 = 1000e18;

        // Set collateral price to $3000 (similar to eth)
        FeedMock(address(lender.feed())).setPrice(collateralPrice);
        
        // Prepare test data
        address borrower1 = address(0xBEEF);
        address borrower2 = address(0xF00D);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        
        // Setup: mint collateral to borrowers and coins to redeemer
        collateral.mint(borrower1, collateralAmount1);
        collateral.mint(borrower2, collateralAmount2);

        // Setup: borrower2 creates a redeemable position
        vm.startPrank(borrower2);
        collateral.approve(address(lender), collateralAmount2);
        lender.adjust(borrower2, int256(collateralAmount2), int256(borrowAmount2), true); // opt into redemptions
        vm.stopPrank();

        // Setup: borrower1 creates a redeemable position
        vm.startPrank(borrower1);
        collateral.approve(address(lender), type(uint).max);
        coin.approve(address(lender), type(uint).max);
        lender.adjust(borrower1, int256(collateralAmount1), int256(borrowAmount1), true); // opt into redemptions
        vm.stopPrank();

        for(uint i; i < 100; i++){
            vm.startPrank(borrower1);
            lender.adjust(borrower1, int256(collateral.balanceOf(borrower1)), 0);
            (uint price,,) = lender.getCollateralPrice();
            uint borrowingPower = price * lender._cachedCollateralBalances(borrower1) * lender.collateralFactor() / 1e18 / 10000 - lender.getDebtOf(borrower1);
            lender.adjust(borrower1, 0, int256(borrowingPower));
            uint maxRedeem = collateral.balanceOf(address(lender)) * price * 10000 / 1e18 / (10000 - lender.redeemFeeBps());
            uint balance = coin.balanceOf(borrower1);
            uint redeemAmount = balance > maxRedeem ? maxRedeem : balance;
            lender.redeem(redeemAmount, 0);
            vm.stopPrank();
            emit log_string("epoch");
            emit log_uint(lender.epoch());
            emit log_string("totalFreeDebtShares");
            emit log_uint(lender.totalFreeDebtShares());
            emit log_string("totalFreeDebt");
            emit log_uint(lender.totalFreeDebt());
            emit log_string("cachedCollateralBalance");
            emit log_uint(lender._cachedCollateralBalances(borrower1));
            emit log_string("Lender collateral balance");
            emit log_uint(collateral.balanceOf(address(lender)));
            emit log_string("borrower1 freeDebtShares");
            emit log_uint(lender.freeDebtShares(borrower1));
            assertLt(collateral.balanceOf(borrower1), collateralAmount1, "Profitable redemptions");
        }
    }

    function test_repeated_redemptions_fork_vulnerable() public {
        string memory url = vm.rpcUrl("mainnet");
        uint mainnetFork = vm.createSelectFork(url, 22867366);
        lender = Lender(0x44AfC35b52dbeBF43e1940D4f12C372446D52D5A);
        // Setup: create multiple borrowers with redeemable debt
        uint collateralAmount1 = 25000e18;
        uint collateralAmount = 5000e18;
        uint borrowAmount = 1000e18;
        
        // Prepare test data
        address borrower1 = address(0xBEEF);
        address borrower2 = address(0xF00D);
        ERC20 collateral = ERC20(address(lender.collateral()));
        ERC20 coin = ERC20(address(lender.coin()));
        
        // Setup: mint collateral to borrowers and coins to redeemer
        deal(address(collateral), borrower1, collateralAmount1);
        deal(address(collateral), borrower2, collateralAmount);

        // Setup: borrower2 creates a redeemable position
        vm.startPrank(borrower2);
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(borrower2, int256(collateralAmount), int256(borrowAmount), true); // opt into redemptions
        vm.stopPrank();

        // Setup: borrower1 creates a redeemable position
        vm.startPrank(borrower1);
        collateral.approve(address(lender), type(uint).max);
        coin.approve(address(lender), type(uint).max);
        lender.adjust(borrower1, int256(collateralAmount1), int256(borrowAmount), true); // opt into redemptions
        vm.stopPrank();

        for(uint i; i < 40; i++){
            vm.startPrank(borrower1);
            lender.adjust(borrower1, int256(collateral.balanceOf(borrower1)), 0);
            (uint price,,) = lender.getCollateralPrice();
            uint borrowingPower = price * lender._cachedCollateralBalances(borrower1) * lender.collateralFactor() / 1e18 / 10000 - lender.getDebtOf(borrower1);
            lender.adjust(borrower1, 0, int256(borrowingPower));
            uint maxRedeem = collateral.balanceOf(address(lender)) * price * 10000 / 1e18 / (10000 - lender.redeemFeeBps());
            uint balance = coin.balanceOf(borrower1);
            uint redeemAmount = balance > maxRedeem ? maxRedeem : balance;
            lender.redeem(redeemAmount, 0);
            vm.stopPrank();
        }

        assertGt(collateral.balanceOf(borrower1), collateralAmount1, "Profitable redemptions");
    }

    function test_repeated_redemptions_fork_fixed() public {
        string memory url = vm.rpcUrl("mainnet");
        uint mainnetFork = vm.createSelectFork(url, 22867366);
        
        // Get the existing Lender contract address
        address lenderAddress = 0x44AfC35b52dbeBF43e1940D4f12C372446D52D5A;
        lender = Lender(lenderAddress);
        lens = new Lens();
        // Deploy a new Lender contract with the same immutable variables as the existing contract
        // Note: The existing contract doesn't have a manager, so we use address(0)
        Lender newLenderImplementation = new Lender(
            lender.collateral(),
            ERC20(address(0)), // optional PSM asset
            ERC4626(address(0)), // optional PSM vault
            lender.feed(),
            lender.coin(),
            lender.vault(),
            lender.interestModel(),
            lender.factory(),
            lender.operator(), // use existing operator
            address(0), // no manager in old contract
            lender.collateralFactor(),
            lender.minDebt(),
            365 days // dummy immutability deadline (this won't matter since we're replacing bytecode)
        );
        
        // Replace the bytecode at the existing Lender address with the new implementation
        vm.etch(lenderAddress, address(newLenderImplementation).code);
        
        // Setup: create multiple borrowers with redeemable debt
        uint collateralAmount1 = 25000e18;
        uint collateralAmount = 5000e18;
        uint borrowAmount = 1000e18;
        
        // Prepare test data
        address borrower1 = address(0xBEEF);
        address borrower2 = address(0xF00D);
        ERC20 collateral = ERC20(address(lender.collateral()));
        ERC20 coin = ERC20(address(lender.coin()));
        
        // Setup: mint collateral to borrowers and coins to redeemer
        deal(address(collateral), borrower1, collateralAmount1);
        deal(address(collateral), borrower2, collateralAmount);

        // Setup: borrower2 creates a redeemable position
        vm.startPrank(borrower2);
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(borrower2, int256(collateralAmount), int256(borrowAmount), true); // opt into redemptions
        vm.stopPrank();

        // Setup: borrower1 creates a redeemable position
        vm.startPrank(borrower1);
        collateral.approve(address(lender), type(uint).max);
        coin.approve(address(lender), type(uint).max);
        lender.adjust(borrower1, int256(collateralAmount1), int256(borrowAmount), true); // opt into redemptions
        vm.stopPrank();

        for(uint i; i < 40; i++){
            vm.startPrank(borrower1);
            lender.adjust(borrower1, int256(collateral.balanceOf(borrower1)), 0);
            (uint price,,) = lender.getCollateralPrice();
            uint borrowingPower = price * lender._cachedCollateralBalances(borrower1) * lender.collateralFactor() / 1e18 / 10000 - lender.getDebtOf(borrower1);
            lender.adjust(borrower1, 0, int256(borrowingPower));
            uint maxRedeem = collateral.balanceOf(address(lender)) * price * 10000 / 1e18 / (10000 - lender.redeemFeeBps());
            uint balance = coin.balanceOf(borrower1);
            uint redeemAmount = balance > maxRedeem ? maxRedeem : balance;
            lender.redeem(redeemAmount, 0);
            vm.stopPrank();
        }
        // Attempts to repay debt and withdraw collateral for both borrowers
        uint256 collateralBalance2 = lens.getCollateralOf(lender, borrower2);
        uint256 debt2 = lender.getDebtOf(borrower2);
        uint256 collateralBalance1 = lens.getCollateralOf(lender, borrower1);
        uint256 debt1 = lender.getDebtOf(borrower1);
        vm.startPrank(borrower2);
        lender.coin().approve(address(lender), type(uint).max);
        lender.adjust(borrower2, -int(collateralBalance2) , -int(debt2)); 
        assertEq(lens.getCollateralOf(lender, borrower2), 0, "Borrower2's collateral should be zero after update");
        assertEq(lender._cachedCollateralBalances(borrower2), 0, "Borrower2's cached collateral should be zero after update");
        assertEq(lender.getDebtOf(borrower2), 0, "Borrower2's debt should be zero after update");
        vm.stopPrank();
        // Borrower1 should still have some collateral and debt
        assertGt(lens.getCollateralOf(lender, borrower1), 0, "Borrower1's collateral should be greater than zero after update");
        assertEq(lens.getCollateralOf(lender, borrower1), collateralBalance1, "Borrower1's collateral should be unchanged after update");
        //assertGt(lender.getDebtOf(borrower1), 0, "Borrower1's debt should be greater than zero after update");
        // When borrower1 attemps to repay debt and withdraw all it fails in the Lender with aritmetic underflow because totalFreeDebtShares are less than borrower's freeDebtShares
        //assertGt(lender.totalFreeDebtShares(), lender.freeDebtShares(borrower1), "Total Free Debt Shares are greater than borrower's Free Debt Shares");
        // Borrower1 should still have some collateral and debt
        vm.startPrank(borrower1);
        assertEq(lender.getDebtOf(borrower1), debt1, "Borrower1's debt should be unchanged before redeem");
        deal(address(coin), borrower1, lender.getDebtOf(borrower1)); // give borrower1 enough coins to redeem
        assertEq(lens.getCollateralOf(lender, borrower1), collateralBalance1, "Borrower1's collateral should be unchanged before update");
        lender.adjust(borrower1, -int(collateralBalance1), -int(lender.getDebtOf(borrower1))); 
        vm.stopPrank();
    }
    
    function test_setPendingOperator() public {
        // Define a new address for the pending operator
        address newOperator = address(0x456);
        
        // Ensure the initial operator is set correctly
        assertEq(lender.operator(), operatorAddr, "Initial operator should be operatorAddr");
        assertEq(lender.pendingOperator(), address(0), "Initial pendingOperator should be address(0)");
        
        // Call setPendingOperator as the current operator
        vm.prank(operatorAddr);
        lender.setPendingOperator(newOperator);
        
        // Verify the pendingOperator was updated correctly
        assertEq(lender.pendingOperator(), newOperator, "pendingOperator should be updated to newOperator");
        assertEq(lender.operator(), operatorAddr, "operator should remain unchanged");
    }
    
    function test_setPendingOperator_unauthorized() public {
        // Define a new address for the pending operator
        address newOperator = address(0x456);
        address unauthorized = address(0x789);
        
        // Attempt to call setPendingOperator from an unauthorized address
        vm.prank(unauthorized);
        vm.expectRevert("Unauthorized");
        lender.setPendingOperator(newOperator);
        
        // Verify state remains unchanged
        assertEq(lender.operator(), operatorAddr, "operator should remain unchanged");
        assertEq(lender.pendingOperator(), address(0), "pendingOperator should remain unchanged");
    }
    
    function test_acceptOperator() public {
        // Define a new address for the pending operator
        address newOperator = address(0x456);
        
        // Set the pending operator first
        vm.prank(operatorAddr);
        lender.setPendingOperator(newOperator);
        
        // Verify the pending operator was set
        assertEq(lender.pendingOperator(), newOperator, "pendingOperator should be set to newOperator");
        
        // Accept the operator role as the pending operator
        vm.prank(newOperator);
        lender.acceptOperator();
        
        // Verify the operator was changed
        assertEq(lender.operator(), newOperator, "operator should be updated to newOperator");
    }
    
    function test_acceptOperator_unauthorized() public {
        // Define addresses for the pending operator and an unauthorized address
        address newOperator = address(0x456);
        address unauthorized = address(0x789);
        
        // Set the pending operator first
        vm.prank(operatorAddr);
        lender.setPendingOperator(newOperator);
        
        // Attempt to accept the operator role from an unauthorized address
        vm.prank(unauthorized);
        vm.expectRevert("Unauthorized");
        lender.acceptOperator();
        
        // Verify state remains unchanged
        assertEq(lender.operator(), operatorAddr, "operator should remain unchanged");
        assertEq(lender.pendingOperator(), newOperator, "pendingOperator should remain unchanged");
    }
    
    function test_setHalfLife() public {
        // Get initial expRate
        uint64 initialExpRate = lender.expRate();
        
        // Set a new half-life (14 days)
        uint64 newHalfLife = 14 days;
        vm.prank(operatorAddr);
        lender.setHalfLife(newHalfLife);
        
        // Calculate expected new expRate based on the formula in the contract
        uint64 expectedExpRate = uint64(uint(wadLn(2*1e18)) / newHalfLife);
        
        // Verify expRate was updated correctly
        assertEq(lender.expRate(), expectedExpRate, "expRate should be updated based on new half-life");
        assertNotEq(lender.expRate(), initialExpRate, "expRate should be different from initial value");
    }

    function test_setHalfLife_revertUnauthorized() public {
        address unauthorized = address(0xBAD);
        
        vm.prank(unauthorized);
        vm.expectRevert("Unauthorized");
        lender.setHalfLife(14 days);
    }

    function test_setHalfLife_revertAfterImmutabilityDeadline() public {
        // Warp past immutability deadline
        vm.warp(block.timestamp + 366 days);
        
        vm.prank(operatorAddr);
        vm.expectRevert("Deadline passed");
        lender.setHalfLife(14 days);
    }

    function test_setHalfLife_revertInvalidValue() public {
        // Test too small half-life
        vm.startPrank(operatorAddr);
        vm.expectRevert("Invalid half life");
        lender.setHalfLife(12 hours - 1);
        
        // Test too large half-life
        vm.expectRevert("Invalid half life");
        lender.setHalfLife(30 days + 1);
        vm.stopPrank();
    }

    function test_setTargetFreeDebtRatio() public {
        // Get initial values
        uint16 initialStartBps = lender.targetFreeDebtRatioStartBps();
        uint16 initialEndBps = lender.targetFreeDebtRatioEndBps();
        
        // Set new values
        uint16 newStartBps = 1000;
        uint16 newEndBps = 3000;
        vm.prank(operatorAddr);
        lender.setTargetFreeDebtRatio(newStartBps, newEndBps);
        
        // Verify values were updated
        assertEq(lender.targetFreeDebtRatioStartBps(), newStartBps, "targetFreeDebtRatioStartBps should be updated");
        assertEq(lender.targetFreeDebtRatioEndBps(), newEndBps, "targetFreeDebtRatioEndBps should be updated");
        assertNotEq(lender.targetFreeDebtRatioStartBps(), initialStartBps, "targetFreeDebtRatioStartBps should be different from initial");
        assertNotEq(lender.targetFreeDebtRatioEndBps(), initialEndBps, "targetFreeDebtRatioEndBps should be different from initial");
    }

    function test_setTargetFreeDebtRatio_revertUnauthorized() public {
        address unauthorized = address(0xBAD);
        
        vm.prank(unauthorized);
        vm.expectRevert("Unauthorized");
        lender.setTargetFreeDebtRatio(1000, 3000);
    }

    function test_setTargetFreeDebtRatio_revertAfterImmutabilityDeadline() public {
        // Warp past immutability deadline
        vm.warp(block.timestamp + 366 days);
        
        vm.prank(operatorAddr);
        vm.expectRevert("Deadline passed");
        lender.setTargetFreeDebtRatio(1000, 3000);
    }

    function test_setTargetFreeDebtRatio_revertInvalidValues() public {
        vm.startPrank(operatorAddr);
        
        // Test start below minimum
        vm.expectRevert("Invalid start bps");
        lender.setTargetFreeDebtRatio(499, 3000);
        
        // Test start greater than end
        vm.expectRevert("Invalid start bps");
        lender.setTargetFreeDebtRatio(4000, 3000);
        
        // Test end above maximum
        vm.expectRevert("Invalid end bps");
        lender.setTargetFreeDebtRatio(1000, 9501);
        
        vm.stopPrank();
    }

    function test_setRedeemFeeBps() public {
        // Get initial value
        uint16 initialRedeemFeeBps = lender.redeemFeeBps();
        
        // Set new value
        uint16 newRedeemFeeBps = 100;
        vm.prank(operatorAddr);
        lender.setRedeemFeeBps(newRedeemFeeBps);
        
        // Verify value was updated
        assertEq(lender.redeemFeeBps(), newRedeemFeeBps, "redeemFeeBps should be updated");
        assertNotEq(lender.redeemFeeBps(), initialRedeemFeeBps, "redeemFeeBps should be different from initial");
    }

    function test_setRedeemFeeBps_revertUnauthorized() public {
        address unauthorized = address(0xBAD);
        
        vm.prank(unauthorized);
        vm.expectRevert("Unauthorized");
        lender.setRedeemFeeBps(100);
    }

    function test_setRedeemFeeBps_revertAfterImmutabilityDeadline() public {
        // Warp past immutability deadline
        vm.warp(block.timestamp + 366 days);
        
        vm.prank(operatorAddr);
        vm.expectRevert("Deadline passed");
        lender.setRedeemFeeBps(100);
    }

    function test_setRedeemFeeBps_revertInvalidValue() public {
        vm.prank(operatorAddr);
        vm.expectRevert("Invalid redeem fee bps");
        lender.setRedeemFeeBps(301); // Above max 300 bps
    }

    function test_setLocalReserveFeeBps() public {
        // Get initial value
        uint16 initialFeeBps = lender.feeBps();
        
        // Set new value
        uint newFeeBps = 500;
        vm.prank(operatorAddr);
        lender.setLocalReserveFeeBps(newFeeBps);
        
        // Verify value was updated
        assertEq(lender.feeBps(), newFeeBps, "feeBps should be updated");
        assertNotEq(lender.feeBps(), initialFeeBps, "feeBps should be different from initial");
    }

    function test_setLocalReserveFeeBps_revertUnauthorized() public {
        address unauthorized = address(0xBAD);
        
        vm.prank(unauthorized);
        vm.expectRevert("Unauthorized");
        lender.setLocalReserveFeeBps(500);
    }

    function test_setLocalReserveFeeBps_revertInvalidValue() public {
        vm.prank(operatorAddr);
        vm.expectRevert("Invalid fee");
        lender.setLocalReserveFeeBps(1001); // Above max 1000 bps (10%)
    }

    function test_enableImmutabilityNow() public {
        // Get initial deadline
        uint initialDeadline = lender.immutabilityDeadline();
        
        // Enable immutability immediately
        vm.prank(operatorAddr);
        lender.enableImmutabilityNow();
        
        // Verify deadline was updated to current timestamp
        assertEq(lender.immutabilityDeadline(), block.timestamp, "immutabilityDeadline should be set to current timestamp");
        assertLt(lender.immutabilityDeadline(), initialDeadline, "new deadline should be earlier than initial deadline");
    }

    function test_enableImmutabilityNow_revertUnauthorized() public {
        address unauthorized = address(0xBAD);
        
        vm.prank(unauthorized);
        vm.expectRevert("Unauthorized");
        lender.enableImmutabilityNow();
    }

    function test_enableImmutabilityNow_revertAfterDeadline() public {
        // Warp past immutability deadline
        vm.warp(block.timestamp + 366 days);
        
        vm.prank(operatorAddr);
        vm.expectRevert("Deadline passed");
        lender.enableImmutabilityNow();
    }

    function test_pullLocalReserves() public {
        // Generate some local reserves through interest accrual
        // Setup a borrower with debt
        address borrower = address(0xBEEF);
        uint collateralAmount = 4000e18;
        uint borrowAmount = 2000e18;
        
        // Setup collateral and borrow
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        collateral.mint(borrower, collateralAmount);
        
        vm.startPrank(borrower);
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(borrower, int256(collateralAmount), int256(borrowAmount), false); // non-redeemable debt
        vm.stopPrank();
        
        // Set local reserve fee to 10%
        vm.prank(operatorAddr);
        lender.setLocalReserveFeeBps(1000);
        
        // Advance time to accrue interest
        vm.warp(block.timestamp + 30 days);
        
        // Force interest accrual
        lender.accrueInterest();
        
        // Get local reserves amount
        uint localReserves = lender.accruedLocalReserves();
        assertGt(localReserves, 0, "Local reserves should be greater than 0 after interest accrual");
        
        // Pull local reserves
        vm.prank(operatorAddr);
        lender.pullLocalReserves();
        
        // Verify local reserves were reset to 0
        assertEq(lender.accruedLocalReserves(), 0, "Local reserves should be reset to 0 after pulling");
        
        // Verify operator received the coins
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        assertEq(coin.balanceOf(operatorAddr), localReserves, "Operator should receive local reserves");
    }

    function test_pullLocalReserves_revertUnauthorized() public {
        address unauthorized = address(0xBAD);
        
        vm.prank(unauthorized);
        vm.expectRevert("Unauthorized");
        lender.pullLocalReserves();
    }

    function test_pullGlobalReserves() public {
        // Generate some global reserves through interest accrual
        // Setup a borrower with debt
        address borrower = address(0xBEEF);
        uint collateralAmount = 4000e18;
        uint borrowAmount = 2000e18;
        
        // Setup collateral and borrow
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        collateral.mint(borrower, collateralAmount);
        
        vm.startPrank(borrower);
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(borrower, int256(collateralAmount), int256(borrowAmount), false); // non-redeemable debt
        vm.stopPrank();
        
        // Advance time to accrue interest
        vm.warp(block.timestamp + 30 days);
        
        // Force interest accrual
        lender.accrueInterest();
        
        // Get global reserves amount
        uint globalReserves = lender.accruedGlobalReserves();
        assertGt(globalReserves, 0, "Global reserves should be greater than 0 after interest accrual");
        
        // Pull global reserves (only factory can call this)
        address factoryAddr = address(lender.factory());
        address recipient = address(0xABCD);
        
        vm.prank(factoryAddr);
        lender.pullGlobalReserves(recipient);
        
        // Verify global reserves were reset to 0
        assertEq(lender.accruedGlobalReserves(), 0, "Global reserves should be reset to 0 after pulling");
        
        // Verify recipient received the coins
        ERC20Mock coin = ERC20Mock(address(lender.coin()));
        assertEq(coin.balanceOf(recipient), globalReserves, "Recipient should receive global reserves");
    }

    function test_pullGlobalReserves_revertUnauthorized() public {
        address unauthorized = address(0xBAD);
        address recipient = address(0xABCD);
        
        vm.prank(unauthorized);
        vm.expectRevert("Unauthorized");
        lender.pullGlobalReserves(recipient);
    }

    // Helper function for wadLn calculation (similar to the one in the contract)
    function wadLn(uint /*x*/) internal pure returns (uint r) {
        // This is a simplified version just for testing
        return 693147180559945309; // ln(2) * 1e18, approximate value
    }

    // Tests for setRedemptionStatus
    function test_setRedemptionStatus_noDebt() public {
        // Prepare test data
        address user = address(0xBEEF);
        
        // Verify initial state
        assertEq(lender.isRedeemable(user), false, "Initial isRedeemable should be false");
        
        // Execute: set redemption status to true with no debt
        vm.prank(user);
        lender.setRedemptionStatus(user, true);
        
        // Verify final state
        assertEq(lender.isRedeemable(user), true, "isRedeemable should be updated to true");
        
        // Execute: set redemption status back to false with no debt
        vm.prank(user);
        lender.setRedemptionStatus(user, false);
        
        // Verify final state
        assertEq(lender.isRedeemable(user), false, "isRedeemable should be updated to false");
    }
    
    function test_setRedemptionStatus_withDebt(uint collateralAmount, uint borrowAmount) public {
        // Bound amounts to prevent overflows
        collateralAmount = bound(collateralAmount, 2000e18, type(uint128).max);
        borrowAmount = bound(borrowAmount, lender.minDebt(), collateralAmount * lender.collateralFactor() / 10000);
        
        // Prepare test data
        address user = address(0xBEEF);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        
        // Setup: mint collateral to user
        collateral.mint(user, collateralAmount);
        
        // Setup: user deposits collateral and borrows as non-redeemable (default)
        vm.startPrank(user);
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(user, int256(collateralAmount), int256(borrowAmount));
        
        // Verify initial state
        assertEq(lender.isRedeemable(user), false, "Initial isRedeemable should be false");
        assertEq(lender.getDebtOf(user), borrowAmount, "Initial debt incorrect");
        assertEq(lender.paidDebtShares(user) > 0, true, "Should have paid debt shares");
        assertEq(lender.freeDebtShares(user), 0, "Should not have free debt shares");
        
        // Record pre-transition values
        uint initialTotalPaidDebt = lender.totalPaidDebt();
        uint initialTotalFreeDebt = lender.totalFreeDebt();
        
        // Execute: change to redeemable
        lender.setRedemptionStatus(user, true);
        
        // Verify state after transition
        assertEq(lender.isRedeemable(user), true, "isRedeemable should be true after transition");
        assertEq(lender.getDebtOf(user), borrowAmount, "Debt should remain the same after transition");
        assertEq(lender.paidDebtShares(user), 0, "Should have no paid debt shares after transition");
        assertEq(lender.freeDebtShares(user) > 0, true, "Should have free debt shares after transition");
        assertEq(lender.totalPaidDebt(), initialTotalPaidDebt - borrowAmount, "Total paid debt should decrease");
        assertEq(lender.totalFreeDebt(), initialTotalFreeDebt + borrowAmount, "Total free debt should increase");
        
        // Execute: change back to non-redeemable
        lender.setRedemptionStatus(user, false);
        
        // Verify final state
        assertEq(lender.isRedeemable(user), false, "isRedeemable should be false after second transition");
        assertEq(lender.getDebtOf(user), borrowAmount, "Debt should remain the same after second transition");
        assertEq(lender.freeDebtShares(user), 0, "Should have no free debt shares after second transition");
        assertEq(lender.paidDebtShares(user) > 0, true, "Should have paid debt shares after second transition");
        assertApproxEqAbs(lender.totalPaidDebt(), initialTotalPaidDebt, 1, "Total paid debt should be restored");
        assertApproxEqAbs(lender.totalFreeDebt(), initialTotalFreeDebt, 1, "Total free debt should be restored");
        
        vm.stopPrank();
    }
    
    function test_setRedemptionStatus_noOpWhenUnchanged(uint collateralAmount, uint borrowAmount) public {
        // Bound amounts to prevent overflows
        collateralAmount = bound(collateralAmount, 2000e18, type(uint128).max);
        borrowAmount = bound(borrowAmount, lender.minDebt(), collateralAmount * lender.collateralFactor() / 10000);
        
        // Prepare test data
        address user = address(0xBEEF);
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        
        // Setup: mint collateral to user
        collateral.mint(user, collateralAmount);
        
        // Setup: user deposits collateral and borrows with redeemable status
        vm.startPrank(user);
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(user, int256(collateralAmount), 0, true); // Set redeemable to true
        lender.adjust(user, 0, int256(borrowAmount)); // Borrow
        
        // Verify initial state
        assertEq(lender.isRedeemable(user), true, "Initial isRedeemable should be true");
        assertEq(lender.getDebtOf(user), borrowAmount, "Initial debt incorrect");
        assertEq(lender.freeDebtShares(user) > 0, true, "Should have free debt shares");
        
        // Record the initial state
        uint initialFreeShares = lender.freeDebtShares(user);
        uint initialTotalFreeShares = lender.totalFreeDebtShares();
        
        // Execute: set redemption status to true again (no-op)
        lender.setRedemptionStatus(user, true);
        
        // Verify state remains unchanged
        assertEq(lender.isRedeemable(user), true, "isRedeemable should still be true");
        assertEq(lender.getDebtOf(user), borrowAmount, "Debt should remain unchanged");
        assertEq(lender.freeDebtShares(user), initialFreeShares, "Free debt shares should remain unchanged");
        assertEq(lender.totalFreeDebtShares(), initialTotalFreeShares, "Total free debt shares should remain unchanged");
        
        vm.stopPrank();
    }
    
    function test_setRedemptionStatus_revertsUnauthorized() public {
        // Prepare test data
        address user = address(0xBEEF);
        address unauthorized = address(0xBAD);
        
        // Execute: unauthorized user attempts to set redemption status
        vm.prank(unauthorized);
        vm.expectRevert("Unauthorized");
        lender.setRedemptionStatus(user, true);
        
        // Verify state remains unchanged
        assertEq(lender.isRedeemable(user), false, "isRedeemable should remain false");
    }
    
    function test_setRedemptionStatus_byDelegation() public {
        // Prepare test data
        address user = address(0xBEEF);
        address delegate = address(0xCAFE);
        
        // Setup: delegate permissions
        vm.prank(user);
        lender.delegate(delegate, true);
        
        // Execute: delegate sets redemption status
        vm.prank(delegate);
        lender.setRedemptionStatus(user, true);
        
        // Verify status was updated
        assertEq(lender.isRedeemable(user), true, "isRedeemable should be updated by delegated call");
        
        // Execute: delegate sets it back
        vm.prank(delegate);
        lender.setRedemptionStatus(user, false);
        
        // Verify status was updated again
        assertEq(lender.isRedeemable(user), false, "isRedeemable should be updated again by delegated call");
    }
    
    function test_setRedemptionStatus_withInterestAccrual() public {
        // Prepare test data
        address user = address(0xBEEF);
        uint collateralAmount = 5000e18;
        uint borrowAmount = 2000e18;
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        
        // Setup: mint collateral to user
        collateral.mint(user, collateralAmount);
        
        // Setup: user deposits collateral and borrows as non-redeemable (default)
        vm.startPrank(user);
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(user, int256(collateralAmount), int256(borrowAmount));
        
        // Warp time to accrue interest
        vm.warp(block.timestamp + 30 days);
        
        // Execute: change to redeemable
        lender.setRedemptionStatus(user, true);
        
        // Verify lastAccrue was updated
        uint40 finalLastAccrue = lender.lastAccrue();
        assertEq(finalLastAccrue, block.timestamp, "lastAccrue should be updated during setRedemptionStatus");
        assertEq(lender.isRedeemable(user), true, "isRedeemable should be updated during setRedemptionStatus");
        
        vm.stopPrank();
    }
    
    function test_setRedemptionStatus_withInterestModelRevert() public {
        // Prepare test data
        address user = address(0xBEEF);
        uint collateralAmount = 5000e18;
        uint borrowAmount = 2000e18;
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        
        // Setup: mint collateral to user
        collateral.mint(user, collateralAmount);
        
        // Setup: user deposits collateral and borrows as non-redeemable (default)
        vm.startPrank(user);
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(user, int256(collateralAmount), int256(borrowAmount));
        
        // Configure the InterestModel to revert
        InterestModelMock interestModel = InterestModelMock(address(lender.interestModel()));
        interestModel.setShouldRevert(true);
        
        // Warp time to attempt interest accrual
        vm.warp(block.timestamp + 30 days);
        
        // Get initial lastAccrue value
        uint40 initialLastAccrue = lender.lastAccrue();
        
        // Execute: change to redeemable (should still work even if IRM reverts)
        lender.setRedemptionStatus(user, true);
        
        // Verify redemption status changed
        assertEq(lender.isRedeemable(user), true, "isRedeemable should be updated even with interest model revert");
        
        // Verify lastAccrue wasn't updated
        uint40 finalLastAccrue = lender.lastAccrue();
        assertEq(finalLastAccrue, initialLastAccrue, "lastAccrue should not be updated when interest model reverts");
        
        vm.stopPrank();
        
        // Set the IRM back to normal
        interestModel.setShouldRevert(false);
    }
    
    function test_setRedemptionStatus_complexInteractions() public {
        // Test setup with multiple borrowers with different statuses
        address userA = address(0xBEEF);
        address userB = address(0xF00D);
        uint collateralAmount = 5000e18;
        uint borrowAmount = 2000e18;
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        
        // Setup: mint collateral to users
        collateral.mint(userA, collateralAmount);
        collateral.mint(userB, collateralAmount);
        
        // Setup: userA borrows as non-redeemable (default)
        vm.startPrank(userA);
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(userA, int256(collateralAmount), int256(borrowAmount));
        vm.stopPrank();
        
        // Setup: userB borrows as redeemable
        vm.startPrank(userB);
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(userB, int256(collateralAmount), 0, true); // Set redeemable to true
        lender.adjust(userB, 0, int256(borrowAmount)); // Borrow
        vm.stopPrank();
        
        // Verify initial state
        assertEq(lender.isRedeemable(userA), false, "UserA should be non-redeemable");
        assertEq(lender.isRedeemable(userB), true, "UserB should be redeemable");
        assertEq(lender.getDebtOf(userA), borrowAmount, "UserA debt incorrect");
        assertEq(lender.getDebtOf(userB), borrowAmount, "UserB debt incorrect");
        
        // Record the state of debt pools
        uint initialTotalPaidDebt = lender.totalPaidDebt();
        uint initialTotalFreeDebt = lender.totalFreeDebt();
        
        // Switch userA to redeemable
        vm.prank(userA);
        lender.setRedemptionStatus(userA, true);
        
        // Switch userB to non-redeemable
        vm.prank(userB);
        lender.setRedemptionStatus(userB, false);
        
        // Verify debt pools have been updated correctly (swapped)
        assertEq(lender.totalPaidDebt(), initialTotalPaidDebt + borrowAmount - borrowAmount, "Paid debt pool should remain the same");
        assertEq(lender.totalFreeDebt(), initialTotalFreeDebt + borrowAmount - borrowAmount, "Free debt pool should remain the same");
        
        // Verify individual statuses
        assertEq(lender.isRedeemable(userA), true, "UserA should now be redeemable");
        assertEq(lender.isRedeemable(userB), false, "UserB should now be non-redeemable");
        assertEq(lender.getDebtOf(userA), borrowAmount, "UserA debt should remain the same");
        assertEq(lender.getDebtOf(userB), borrowAmount, "UserB debt should remain the same");
    }

    function test_cachedGlobalFeeBps() public {
        // Setup: create a borrower with debt to accrue interest
        address borrower = address(0xBEEF);
        uint collateralAmount = 4000e18;
        uint borrowAmount = 2000e18;
        
        // Setup collateral and borrow
        ERC20Mock collateral = ERC20Mock(address(lender.collateral()));
        collateral.mint(borrower, collateralAmount);
        
        // Create a factory mock that we can change the fee on
        FactoryMock factoryMock = new FactoryMock();
        
        // Deploy a new lender with this factory
        Lender lenderWithCustomFactory = new Lender(
            ERC20(address(collateral)),
            ERC20(address(0)), // optional PSM asset
            ERC4626(address(0)), // optional PSM vault
            IChainlinkFeed(address(new FeedMock())),
            Coin(address(new ERC20Mock("Coin", "COIN"))),
            Vault(address(new VaultMock())),
            InterestModel(address(new InterestModelMock())),
            IFactory(address(factoryMock)),
            operatorAddr,
            address(0xABC), // manager address
            5000, // 50% collateral factor
            1000e18, // 1000 Coin min debt
            365 days // 1 year immutability deadline
        );
        
        // Set local fee to 0% to make global fee effects more visible
        vm.prank(operatorAddr);
        lenderWithCustomFactory.setLocalReserveFeeBps(0);
        
        // Setup: borrower deposits collateral and borrows
        vm.startPrank(borrower);
        collateral.approve(address(lenderWithCustomFactory), collateralAmount);
        lenderWithCustomFactory.adjust(borrower, int256(collateralAmount), int256(borrowAmount));
        vm.stopPrank();
        
        // Verify the global fee was cached initially
        assertEq(lenderWithCustomFactory.cachedGlobalFeeBps(), 1000, "Initial cached global fee should be 10%");
        
        // Advance time to trigger interest accrual (7 days = ~1% interest with our mock model)
        vm.warp(block.timestamp + 7 days);
        
        // Call accrueInterest to accrue with 10% global fee
        lenderWithCustomFactory.accrueInterest();
        
        // Track the first interest accrual
        uint firstGlobalReserves = lenderWithCustomFactory.accruedGlobalReserves();
        assertGt(firstGlobalReserves, 0, "Should have accrued global reserves with 10% fee");
        
        // Calculate the expected global reserves based on expected interest amount with 10% fee
        // Our mock model returns 1e18 (100%) per year, so 7 days would be about 1.9% interest
        // 2000e18 (borrowAmount) * 0.019 (interest rate for 7 days) * 0.1 (10% fee) = ~3.8e18
        uint expectedInterestWithTenPercentFee = borrowAmount * 7 days * 1e18 / 365 days / 1e18 * 1000 / 10000;
        assertApproxEqRel(firstGlobalReserves, expectedInterestWithTenPercentFee, 0.01e18, 
            "Global reserves should match expected interest with 10% fee");
        
        // Change factory fee to 40%
        factoryMock.setFee(4000);
        
        // Advance time again
        vm.warp(block.timestamp + 7 days);
        
        // Call accrueInterest again - should still use cached 10% fee, not current 40%
        lenderWithCustomFactory.accrueInterest();
        
        // Get new global reserves
        uint secondGlobalReserves = lenderWithCustomFactory.accruedGlobalReserves();
        uint secondInterestAmount = secondGlobalReserves - firstGlobalReserves;
        
        // Calculate expected interest with cached 10% fee (not the 40% current fee)
        uint expectedInterestWithCachedFee = expectedInterestWithTenPercentFee;
        assertApproxEqRel(secondInterestAmount, expectedInterestWithCachedFee, 0.1e18, 
            "Second interest amount should use cached 10% fee, not current 40%");
        
        // Now we'll adjust a position, which should trigger interest accrual and refresh the cached fee
        vm.prank(borrower);
        lenderWithCustomFactory.adjust(borrower, 0, 0);
        
        // Verify fee was updated in the cache
        assertEq(lenderWithCustomFactory.cachedGlobalFeeBps(), 4000, "Cached global fee should be updated to 40%");
        
        // Get reserves before next accrual
        uint reservesBeforeThirdAccrual = lenderWithCustomFactory.accruedGlobalReserves();
        
        // Advance time again
        vm.warp(block.timestamp + 7 days);
        
        // Call accrueInterest again - now using new 40% fee
        lenderWithCustomFactory.accrueInterest();
        
        // Get new global reserves
        uint thirdGlobalReserves = lenderWithCustomFactory.accruedGlobalReserves();
        uint thirdInterestAmount = thirdGlobalReserves - reservesBeforeThirdAccrual;
        
        uint _borrowAmount = borrowAmount;
        // Calculate expected interest with new 40% fee
        uint expectedInterestWithFortyPercentFee = _borrowAmount * 7 days * 1e18 / 365 days / 1e18 * 4000 / 10000;
        assertApproxEqRel(thirdInterestAmount, expectedInterestWithFortyPercentFee, 0.1e18, 
            "Third interest amount should use updated 40% fee");
        
        // Verify relationship between interest amounts based on fee difference
        assertApproxEqRel(thirdInterestAmount, expectedInterestWithTenPercentFee * 4, 0.1e18, 
            "Interest with 40% fee should be about 4x the interest with 10% fee");
    }
}
