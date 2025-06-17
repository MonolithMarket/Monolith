// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Lens} from "src/Lens.sol";

contract LensScript is Script {

    function setUp() public {}

    function run() public {
        vm.broadcast();
        
        Lens lens = new Lens();
        
        console.log("Lens deployed at:", address(lens));
    }
}
