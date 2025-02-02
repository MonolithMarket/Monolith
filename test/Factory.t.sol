// // SPDX-License-Identifier: UNLICENSED
// pragma solidity 0.8.13;

// import {Test, console} from "forge-std/Test.sol";
// import {Factory} from "src/Factory.sol";
// import  "lib/solmate/src/tokens/ERC20.sol";
// import {USD2} from "src/USD2.sol";
// import {SUSD2} from "src/SUSD2.sol";

// contract MockCollateral is ERC20 {
//     constructor() ERC20("MockCollateral", "MCOLL", 18) {}
// }

// contract FactoryTest is Test {


//     function test_constructor() public {
//         address collateral = address(new MockCollateral());
//         address feed = address(1);
//         address operator = address(2);
//         Factory factory = new Factory(collateral, feed, operator);

//         assertNotEq(factory.usd2(), address(0));
//         assertNotEq(factory.susd2(), address(0));

//         assertEq(address(USD2(factory.usd2()).sUSD2()), factory.susd2());
//         assertEq(address(SUSD2(factory.susd2()).asset()), factory.usd2());

//         assertEq(address(USD2(factory.usd2()).collateral()), collateral);
//         assertEq(address(USD2(factory.usd2()).feed()), feed);
//         assertEq(USD2(factory.usd2()).symbol(), "USD2");
//         assertEq(USD2(factory.usd2()).operator(), operator);

//         assertEq(USD2(factory.susd2()).operator(), operator);
//         assertEq(USD2(factory.susd2()).symbol(), "sUSD2");
//     }
// }