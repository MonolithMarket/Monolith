// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Coin} from "src/Coin.sol";

contract CoinTest is Test {
    Coin coin;
    address public minterAddr;
    address public nonMinterAddr;
    address public userAddr;

    function setUp() public {
        // Set minter address
        minterAddr = address(0x123);
        nonMinterAddr = address(0x456);
        userAddr = address(0xBEEF);
        
        // Deploy Coin contract
        coin = new Coin(minterAddr, "Test Coin", "TCOIN");
    }
    
    function test_constructor() public {
        // Test constructor parameters set correctly
        assertEq(coin.minter(), minterAddr, "Minter address mismatch");
        assertEq(coin.name(), "Test Coin", "Token name mismatch");
        assertEq(coin.symbol(), "TCOIN", "Token symbol mismatch");
        assertEq(coin.decimals(), 18, "Decimals mismatch");
        
        // Deploy another Coin contract with different parameters
        address newMinter = address(0x789);
        Coin newCoin = new Coin(newMinter, "Another Coin", "ACOIN");
        
        // Verify different parameters
        assertEq(newCoin.minter(), newMinter, "New minter address mismatch");
        assertEq(newCoin.name(), "Another Coin", "New token name mismatch");
        assertEq(newCoin.symbol(), "ACOIN", "New token symbol mismatch");
        assertEq(newCoin.decimals(), 18, "New decimals mismatch");
    }
    
    function test_mint_byMinter(uint256 amount) public {
        // Bound the amount to prevent overflow
        amount = bound(amount, 1, type(uint128).max);
        
        // Check initial balance is zero
        assertEq(coin.balanceOf(userAddr), 0, "Initial balance should be zero");
        assertEq(coin.totalSupply(), 0, "Initial total supply should be zero");
        
        // Mint tokens as minter
        vm.prank(minterAddr);
        coin.mint(userAddr, amount);
        
        // Verify balances after minting
        assertEq(coin.balanceOf(userAddr), amount, "User balance incorrect after minting");
        assertEq(coin.totalSupply(), amount, "Total supply incorrect after minting");
    }
    
    function test_mint_byNonMinterReverts(uint256 amount) public {
        // Bound the amount to prevent overflow
        amount = bound(amount, 1, type(uint128).max);
        
        // Try to mint tokens as non-minter (should revert)
        vm.prank(nonMinterAddr);
        vm.expectRevert("Only minter can mint");
        coin.mint(userAddr, amount);
        
        // Verify balances remain unchanged
        assertEq(coin.balanceOf(userAddr), 0, "User balance should remain zero");
        assertEq(coin.totalSupply(), 0, "Total supply should remain zero");
    }
    
    function test_mint_multipleTransactions(uint256 firstAmount, uint256 secondAmount) public {
        // Bound the amounts to prevent overflow
        firstAmount = bound(firstAmount, 1, type(uint128).max / 2);
        secondAmount = bound(secondAmount, 1, type(uint128).max / 2);
        
        // First mint
        vm.prank(minterAddr);
        coin.mint(userAddr, firstAmount);
        
        // Verify balances after first mint
        assertEq(coin.balanceOf(userAddr), firstAmount, "User balance incorrect after first mint");
        assertEq(coin.totalSupply(), firstAmount, "Total supply incorrect after first mint");
        
        // Second mint
        vm.prank(minterAddr);
        coin.mint(userAddr, secondAmount);
        
        // Verify balances after second mint
        assertEq(coin.balanceOf(userAddr), firstAmount + secondAmount, "User balance incorrect after second mint");
        assertEq(coin.totalSupply(), firstAmount + secondAmount, "Total supply incorrect after second mint");
    }

    function test_mint_zero(address recipient) public {
        // Mint zero tokens
        vm.prank(minterAddr);
        coin.mint(recipient, 0);
        
        // Verify balances
        assertEq(coin.balanceOf(recipient), 0, "Balance should be zero after minting zero tokens");
        assertEq(coin.totalSupply(), 0, "Total supply should be zero after minting zero tokens");
    }
    
    function test_burn(uint256 mintAmount, uint256 burnAmount) public {
        // Bound the amounts to prevent overflow and ensure burn amount ≤ mint amount
        mintAmount = bound(mintAmount, 1, type(uint128).max);
        burnAmount = bound(burnAmount, 1, mintAmount);
        
        // Mint tokens first
        vm.prank(minterAddr);
        coin.mint(userAddr, mintAmount);
        
        // Verify balances after minting
        assertEq(coin.balanceOf(userAddr), mintAmount, "User balance incorrect after minting");
        assertEq(coin.totalSupply(), mintAmount, "Total supply incorrect after minting");
        
        // Burn tokens
        vm.prank(userAddr);
        coin.burn(burnAmount);
        
        // Verify balances after burning
        assertEq(coin.balanceOf(userAddr), mintAmount - burnAmount, "User balance incorrect after burning");
        assertEq(coin.totalSupply(), mintAmount - burnAmount, "Total supply incorrect after burning");
    }
    
    function test_burn_entireBalance(uint256 amount) public {
        // Bound the amount to prevent overflow
        amount = bound(amount, 1, type(uint128).max);
        
        // Mint tokens
        vm.prank(minterAddr);
        coin.mint(userAddr, amount);
        
        // Burn entire balance
        vm.prank(userAddr);
        coin.burn(amount);
        
        // Verify balances after burning
        assertEq(coin.balanceOf(userAddr), 0, "User balance should be zero after burning entire balance");
        assertEq(coin.totalSupply(), 0, "Total supply should be zero after burning entire balance");
    }
    
    function test_burn_multipleTransactions(uint256 amount) public {
        // Bound the amount to prevent overflow
        amount = bound(amount, 2, type(uint128).max);
        
        // Mint tokens
        vm.prank(minterAddr);
        coin.mint(userAddr, amount);
        
        // First burn (half)
        uint256 firstBurn = amount / 2;
        vm.prank(userAddr);
        coin.burn(firstBurn);
        
        // Verify balances after first burn
        assertEq(coin.balanceOf(userAddr), amount - firstBurn, "User balance incorrect after first burn");
        assertEq(coin.totalSupply(), amount - firstBurn, "Total supply incorrect after first burn");
        
        // Second burn (remaining balance)
        uint256 secondBurn = amount - firstBurn;
        vm.prank(userAddr);
        coin.burn(secondBurn);
        
        // Verify balances after second burn
        assertEq(coin.balanceOf(userAddr), 0, "User balance should be zero after second burn");
        assertEq(coin.totalSupply(), 0, "Total supply should be zero after second burn");
    }
    
    function test_burn_insufficientBalanceReverts(uint256 mintAmount, uint256 burnAmount) public {
        // Bound mint amount and ensure burn amount exceeds it
        mintAmount = bound(mintAmount, 0, type(uint128).max - 1);
        burnAmount = bound(burnAmount, mintAmount + 1, type(uint128).max);
        
        // Mint tokens
        vm.prank(minterAddr);
        coin.mint(userAddr, mintAmount);
        
        // Try to burn more than balance
        vm.prank(userAddr);
        vm.expectRevert(); // solmate's ERC20 implementation should revert on underflow
        coin.burn(burnAmount);
        
        // Verify balances remain unchanged
        assertEq(coin.balanceOf(userAddr), mintAmount, "Balance should remain unchanged after failed burn");
        assertEq(coin.totalSupply(), mintAmount, "Total supply should remain unchanged after failed burn");
    }
    
    function test_burn_zero() public {
        // Burn zero tokens (should succeed even with no balance)
        vm.prank(userAddr);
        coin.burn(0);
        
        // Verify balances
        assertEq(coin.balanceOf(userAddr), 0, "Balance should remain zero after burning zero tokens");
        assertEq(coin.totalSupply(), 0, "Total supply should remain zero after burning zero tokens");
    }

}