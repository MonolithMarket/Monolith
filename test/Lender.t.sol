// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Lender, ERC20, Coin, Vault, InterestModel, IChainlinkFeed} from "src/Lender.sol";


contract LenderTest is Test {

    Lender lender;


    function setUp() public {
        lender = new Lender(
            ERC20(address(0)),
            IChainlinkFeed(address(1)),
            Coin(address(2)),
            Vault(address(3)),
            InterestModel(address(4)),
            address(5),
            address(6),
            1000,
            1000,
            1000
        );
    }
    
    function test_constructor() public {
        lender = new Lender(
            ERC20(address(0)),
            IChainlinkFeed(address(1)),
            Coin(address(2)),
            Vault(address(3)),
            InterestModel(address(4)),
            address(5),
            address(6),
            1000,
            1000,
            1000
        );
        assertEq(address(lender.collateral()), address(0));
        assertEq(address(lender.feed()), address(1));
        assertEq(address(lender.coin()), address(2));
        assertEq(address(lender.vault()), address(3));
        assertEq(address(lender.interestModel()), address(4));
        assertEq(lender.factory(), address(5));
        assertEq(lender.operator(), address(6));
        assertEq(lender.collateralFactor(), 1000);
        assertEq(lender.minDebt(), 1000);
        assertEq(lender.immutabilityDeadline(), block.timestamp + 1000);
    }

}