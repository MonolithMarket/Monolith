// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Metadata} from "src/Metadata.sol";

contract MetadataScript is Script {

    function setUp() public {}

    function run() public {
        vm.broadcast();

        Metadata metadata = new Metadata();

        console.log("Metadata deployed at:", address(metadata));
    }
}
