// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Factory} from "src/Factory.sol";

contract FactoryScript is Script {

    address constant operator = 0x3FcB35a1CbFB6007f9BC638D388958Bc4550cB28;
    uint256 constant minDebtFloor = 1e15;

    function setUp() public {}

    function run() public {
        vm.broadcast();
        
        Factory factory = new Factory(operator, minDebtFloor);
        
        console.log("Factory deployed at:", address(factory));
        console.log("Interest Model deployed at:", factory.interestModel());
    }
}
