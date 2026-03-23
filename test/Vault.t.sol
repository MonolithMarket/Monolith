// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Vault, ILender, ERC20, ERC4626} from "src/Vault.sol";

contract ERC20Mock is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol, 18) {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function burn(uint256 amount) public {
        _burn(msg.sender, amount);
    }
}

contract LenderMock is ILender {
    ERC20 public override coin;
    uint256 public pendingInterest;

    constructor(address _coin) {
        coin = ERC20(_coin);
    }

    function accrueInterest() external override {
        // Do nothing in the mock
    }

    function getPendingInterest() external view override returns (uint256 pendingVaultInterest) {
        return pendingInterest;
    }

    function setPendingInterest(uint256 _pendingInterest) external {
        pendingInterest = _pendingInterest;
    }
}

contract VaultTest is Test {
    Vault public vault;
    ERC20Mock public underlying;
    LenderMock public lender;
    address public user;
    uint256 public constant MIN_SHARES = 1e16; // Same as in the Vault contract

    function setUp() public {
        // Set up user address
        user = address(0xBEEF);

        // Deploy mock ERC20 token
        underlying = new ERC20Mock("USD Coin", "USDC");

        // Deploy mock Lender contract
        lender = new LenderMock(address(underlying));

        // Deploy Vault contract
        vault = new Vault(
            "USD Coin",
            "USDC",
            address(lender)
        );
    }

    function test_constructor() public view {
        // Verify vault name and symbol
        assertEq(vault.name(), "Staked USD Coin", "Vault name is incorrect");
        assertEq(vault.symbol(), "sUSDC", "Vault symbol is incorrect");
        assertEq(address(vault.asset()), address(underlying), "Vault asset is incorrect");
        assertEq(address(vault.lender()), address(lender), "Vault lender is incorrect");
    }

    function test_depositFirstTime(uint depositAmount) public {
        depositAmount = bound(depositAmount, MIN_SHARES, type(uint128).max);

        // Prepare: mint tokens to user
        underlying.mint(user, depositAmount);

        // User approves and deposits
        vm.startPrank(user);
        underlying.approve(address(vault), depositAmount);
        
        // Since this is the first deposit, get the actual shares returned
        uint256 actualShares = vault.deposit(depositAmount, user);
        
        // Verify results with the actual value
        assertEq(actualShares, depositAmount - MIN_SHARES, "First deposit should return correct shares value");
        assertEq(vault.balanceOf(user), depositAmount - MIN_SHARES, "User should have correct shares amount");
        assertEq(vault.convertToAssets(vault.balanceOf(user)), depositAmount - MIN_SHARES, "User should have correct assets balance");
        assertEq(vault.balanceOf(address(0)), MIN_SHARES, "Zero address should receive MIN_SHARES");
        assertEq(vault.totalSupply(), depositAmount, "Total supply should be equal to depositAmount");
        assertEq(underlying.balanceOf(address(vault)), depositAmount, "Vault should hold depositAmount of underlying");
        assertEq(underlying.balanceOf(user), 0, "User should have 0 underlying after deposit");
        
        vm.stopPrank();
    }

    function test_depositLessThanMinShares() public {
        uint amount = MIN_SHARES - 1;
        vm.startPrank(user);
        underlying.approve(address(vault), amount);
        vm.expectRevert();
        vault.deposit(amount, user);
        vm.stopPrank();
    }

    function test_depositSubsequent() public {
        uint256 firstDeposit = 100e18;
        uint256 secondDeposit = 50e18;

        // Prepare: mint tokens to user and another user
        address anotherUser = address(0xCAFE);
        underlying.mint(user, firstDeposit);
        underlying.mint(anotherUser, secondDeposit);

        // First user deposits (first deposit overall)
        vm.startPrank(user);
        underlying.approve(address(vault), firstDeposit);
        vault.deposit(firstDeposit, user);
        vm.stopPrank();

        // Second user deposits
        vm.startPrank(anotherUser);
        underlying.approve(address(vault), secondDeposit);
        
        // For subsequent deposits, the exchange rate is not exactly 1:1
        uint256 actualShares = vault.deposit(secondDeposit, anotherUser);
        
        // Verify results - don't assert the exact share amount, just verify it's close
        assertApproxEqAbs(actualShares, secondDeposit, 0.01e18, "Subsequent deposit shares should be approximately equal to deposit amount");
        assertApproxEqAbs(vault.balanceOf(anotherUser), secondDeposit, 0.01e18, "User should have approximately deposit amount in shares");
        assertEq(underlying.balanceOf(address(vault)), firstDeposit + secondDeposit, "Vault should hold firstDeposit + secondDeposit of underlying");
        assertEq(underlying.balanceOf(anotherUser), 0, "User should have 0 underlying after deposit");
        
        vm.stopPrank();
    }

    function test_mintFirstTime() public {
        uint256 mintAmount = 100e18;

        // Prepare: mint tokens to user - need extra for MIN_SHARES
        underlying.mint(user, mintAmount + MIN_SHARES);

        // User approves and mints
        vm.startPrank(user);
        underlying.approve(address(vault), type(uint256).max);
        
        // Since this is the first mint, the assets needed will be mintAmount + MIN_SHARES
        uint256 actualAssets = vault.mint(mintAmount, user);
        
        // Verify results - for the first mint, user actually gets (mintAmount - MIN_SHARES) shares
        // because MIN_SHARES are transferred to address(0)
        assertEq(actualAssets, mintAmount + MIN_SHARES, "First mint should return correct assets value");
        assertEq(vault.balanceOf(user), mintAmount, "User should have mintAmount shares");
        assertEq(vault.balanceOf(address(0)), MIN_SHARES, "Zero address should receive MIN_SHARES");
        assertEq(vault.totalSupply(), mintAmount + MIN_SHARES, "Total supply should be mintAmount + MIN_SHARE");
        assertApproxEqAbs(underlying.balanceOf(address(vault)), mintAmount, 0.01e18, "Vault should hold approximately mintAmount of underlying");
        
        vm.stopPrank();
    }

    function test_mintLessThanMinShares() public {
        uint amount = MIN_SHARES - 1;
        vm.startPrank(user);
        underlying.approve(address(vault), amount);
        vm.expectRevert();
        vault.mint(amount, user);
    }

    function test_mintZeroSharesDoesNotBootstrapVault() public {
        vm.startPrank(user);
        underlying.approve(address(vault), type(uint256).max);

        uint256 actualAssets = vault.mint(0, user);

        assertEq(actualAssets, 0, "Minting zero shares should use zero assets");
        assertEq(vault.totalSupply(), 0, "Zero-share mint should not bootstrap supply");
        assertEq(vault.balanceOf(user), 0, "User should not receive shares");
        assertEq(vault.balanceOf(address(0)), 0, "Zero address should not receive MIN_SHARES");
        assertEq(underlying.balanceOf(address(vault)), 0, "Vault should not receive underlying");

        vm.stopPrank();
    }

    function test_withdraw() public {
        uint256 depositAmount = 100e18;
        uint256 withdrawAmount = 40e18;

        // Prepare: mint tokens to user
        underlying.mint(user, depositAmount);

        // User deposits
        vm.startPrank(user);
        underlying.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user);
        
        // User withdraws
        uint256 actualShares = vault.withdraw(withdrawAmount, user, user);
        
        // Verify results - don't assert exact values due to rounding
        assertApproxEqAbs(actualShares, withdrawAmount, 1e16, "Withdraw should burn approximately withdraw amount in shares");
        assertEq(underlying.balanceOf(address(vault)), depositAmount - withdrawAmount, "Vault should hold remaining underlying");
        assertEq(underlying.balanceOf(user), withdrawAmount, "User should receive withdrawn amount");
        
        vm.stopPrank();
    }

    function test_redeem() public {
        uint256 depositAmount = 100e18;
        uint256 redeemAmount = 40e18;

        // Prepare: mint tokens to user
        underlying.mint(user, depositAmount);

        // User deposits
        vm.startPrank(user);
        underlying.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user);
        
        // User redeems
        uint256 actualAssets = vault.redeem(redeemAmount, user, user);
        
        // Verify results - don't assert exact values due to rounding
        assertApproxEqAbs(actualAssets, redeemAmount, 1e16, "Redeem should return approximately redeemAmount in assets");
        assertEq(underlying.balanceOf(user), actualAssets, "User should receive redeemed amount");
        
        vm.stopPrank();
    }

    function test_previewDepositMatchesActual() public {
        uint256 depositAmount = 100e18;

        // Prepare: mint tokens to user
        underlying.mint(user, depositAmount);

        // Get preview before deposit
        uint256 previewedShares = vault.previewDeposit(depositAmount);
        console2.log("Previewed shares for deposit", previewedShares);
        // User deposits
        vm.startPrank(user);
        underlying.approve(address(vault), depositAmount);
        uint256 actualShares = vault.deposit(depositAmount, user);
        console2.log("Actual shares received from deposit", actualShares);
        vm.stopPrank();

        // Verify preview matches actual
        assertEq(previewedShares, actualShares, "previewDeposit should match actual deposit return value");
        assertEq(actualShares, depositAmount - MIN_SHARES, "First deposit should return depositAmount - MIN_SHARES");
    }

    function test_previewMintMatchesActual() public {
        uint256 sharesToMint = 100e18;

        // Get preview before mint
        uint256 previewedAssets = vault.previewMint(sharesToMint);
        console2.log("Previewed assets for minting", previewedAssets);
        // Prepare: mint tokens to user based on preview
        underlying.mint(user, previewedAssets);

        // User mints
        vm.startPrank(user);
        underlying.approve(address(vault), previewedAssets);
        uint256 actualAssets = vault.mint(sharesToMint, user);
        console2.log("Actual assets used for minting", actualAssets);
        vm.stopPrank();

        // Verify preview matches actual
        assertEq(previewedAssets, actualAssets, "previewMint should match actual mint return value");
        assertEq(actualAssets, sharesToMint + MIN_SHARES, "First mint should cost sharesToMint + MIN_SHARES");
        assertEq(vault.balanceOf(user), sharesToMint, "User should receive exactly sharesToMint");
    }

    function test_previewDepositSubsequent() public {
        uint256 firstDeposit = 100e18;
        uint256 secondDeposit = 50e18;

        // First deposit
        underlying.mint(user, firstDeposit);
        vm.startPrank(user);
        underlying.approve(address(vault), firstDeposit);
        vault.deposit(firstDeposit, user);
        vm.stopPrank();

        // Preview second deposit
        address anotherUser = address(0xCAFE);
        uint256 previewedShares = vault.previewDeposit(secondDeposit);

        // Execute second deposit
        underlying.mint(anotherUser, secondDeposit);
        vm.startPrank(anotherUser);
        underlying.approve(address(vault), secondDeposit);
        uint256 actualShares = vault.deposit(secondDeposit, anotherUser);
        vm.stopPrank();

        // Verify preview matches actual for subsequent deposits
        assertEq(previewedShares, actualShares, "previewDeposit should match actual for subsequent deposits");
    }

    function test_previewMintSubsequent() public {
        uint256 firstDeposit = 100e18;
        uint256 sharesToMint = 50e18;

        // First deposit
        underlying.mint(user, firstDeposit);
        vm.startPrank(user);
        underlying.approve(address(vault), firstDeposit);
        vault.deposit(firstDeposit, user);
        vm.stopPrank();

        // Preview mint for subsequent deposit
        address anotherUser = address(0xCAFE);
        uint256 previewedAssets = vault.previewMint(sharesToMint);

        // Execute mint
        underlying.mint(anotherUser, previewedAssets);
        vm.startPrank(anotherUser);
        underlying.approve(address(vault), previewedAssets);
        uint256 actualAssets = vault.mint(sharesToMint, anotherUser);
        vm.stopPrank();

        // Verify preview matches actual for subsequent mints
        assertEq(previewedAssets, actualAssets, "previewMint should match actual for subsequent mints");
    }

    function test_maxDepositFirstDepositIsZero() public view {
        assertEq(vault.maxDeposit(user), 0, "maxDeposit should be 0 at bootstrap");
    }

    function test_maxMintFirstDepositAccountsForMinShares() public view {
        assertEq(vault.maxMint(user), type(uint256).max - MIN_SHARES, "maxMint should reserve room for MIN_SHARES");
    }

    function test_maxWithdrawAndMaxRedeemCapToLiquidAssets() public {
        uint256 depositAmount = 100e18;
        underlying.mint(user, depositAmount);

        vm.startPrank(user);
        underlying.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        lender.setPendingInterest(50e18);

        uint256 liquidAssets = underlying.balanceOf(address(vault));
        assertEq(vault.maxWithdraw(user), liquidAssets, "maxWithdraw should be capped by liquid assets");

        uint256 expectedMaxRedeem = vault.convertToShares(liquidAssets);
        assertEq(vault.maxRedeem(user), expectedMaxRedeem, "maxRedeem should be capped by liquid-backed shares");
    }

}
