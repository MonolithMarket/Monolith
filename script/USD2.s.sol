// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Factory} from "../src/Factory.sol";
import {USD2} from "../src/USD2.sol";
import {TestCollateral} from "../src/TestCollateral.sol";

contract USD2Script is Script {
    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address operatorAddress = vm.envAddress("OPERATOR");
        vm.addr(deployerPrivateKey);
        vm.startBroadcast(deployerPrivateKey);

        // sepolia
        TestCollateral testCol = new TestCollateral();
        Factory factory = new Factory(address(testCol), 0xaaabb530434B0EeAAc9A42E25dbC6A22D7bE218E, operatorAddress);
        // weth
        // Factory factory = new Factory(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, 0x894B896cDc772656Cbb1eE28e6Bd4a704caA7b61, operatorAddress);
        // wsteth
        // Factory factory = new Factory(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0, 0x894B896cDc772656Cbb1eE28e6Bd4a704caA7b61, operatorAddress);
        // testCol.sendFreeTokens(operatorAddress, 1000000000000000000000);
        testCol.sendFreeTokens(0x9c3F0A86967010E451F139D81A4df5e3aA0a743C, 100000000000000000000000);
        // testCol.sendFreeTokens(0xF1c28b589734F9f18E43C8750B37Cf9c48F39a91, 1000000000000000000000);
        // testCol.sendFreeTokens(0x2bCE8eDe42b6068d9669D81160966F6A0cEBE528, 1000000000000000000000);
        console.log("TestCollateral");
        console.log(address(testCol));
        console.log("usd2");
        console.log(factory.usd2());
        console.log("savings");
        console.log(factory.susd2());
        console.log("Col manager");
        USD2 usd2 = USD2(address(factory.usd2()));
        console.log(address(usd2.collateralManager()));
        // vm.stopBroadcast();
    }
}
