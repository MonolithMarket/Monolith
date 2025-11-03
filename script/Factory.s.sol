// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Factory} from "src/Factory.sol";

contract FactoryScript is Script {

    address constant operator = 0xD9a3f7E1AEC3ED77d5Eb7f738Eb27a936bf7F790;
    uint256 constant minDebtFloor = 1e15;

    function setUp() public {}

    function run() public {
        vm.broadcast();
        
        Factory factory = new Factory(operator, minDebtFloor);
        
        console.log("Factory deployed at:", address(factory));
        console.log("Interest Model deployed at:", factory.interestModel());
    }
}
