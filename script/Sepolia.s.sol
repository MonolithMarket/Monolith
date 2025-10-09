// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Factory} from "../src/Factory.sol";
import {Coin} from "../src/Coin.sol";
import {Lender} from "../src/Lender.sol";
import {TestCollateral} from "../src/TestCollateral.sol";

contract SepoliaScript is Script {
    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        uint minDebt = 100000000000000000000; // 100
        address operatorAddress = vm.envAddress("OPERATOR");
        address wstETHFeedSepolia = 0xaaabb530434B0EeAAc9A42E25dbC6A22D7bE218E;
        // address wstETHFeedSepolia = 0x894B896cDc772656Cbb1eE28e6Bd4a704caA7b61;

        vm.addr(deployerPrivateKey);
        vm.startBroadcast(deployerPrivateKey);

        Lens lens = Lens("0x3De0b01AA2a59F960E48dc00dFdC39EaD51d0d62");

        TestCollateral testCol = TestCollateral(
            0xe5a27D68F7f6b6a2d24966bd58a9c5fd8BcE75f2
        );

        console.log("TestCollateral", address(testCol));

        Factory factory = new Factory(operatorAddress);

        console.log("factory", address(factory));

        Factory.DeployParams memory deployParams = Factory.DeployParams({
            name: "sepoUSD",
            symbol: "sepoUSD",
            collateral: address(testCol),
            psmAsset: address(0),
            psmVault: address(0),
            feed: wstETHFeedSepolia,
            collateralFactor: 8900,
            minDebt: minDebt,
            timeUntilImmutability: 365 days,
            operator: operatorAddress,
            manager: operatorAddress,
            halfLife: 2 days,
            targetFreeDebtRatioStartBps: 2000,
            targetFreeDebtRatioEndBps: 4000,
            redeemFeeBps: 30
        });

        (address lender, address coin, address vault) = factory.deploy(
            deployParams
        );

        uint nbDeployments = factory.deploymentsLength();

        // testCol.sendFreeTokens(
        //     operatorAddress,
        //     100000000000000000000000
        // );

        Lender lender = Lender(factory.deployments(nbDeployments - 1));

        console.log("lender", address(lender));
        console.log("coin", address(coin));
        console.log("vault", address(coin));
        // vm.stopBroadcast();
    }
}
