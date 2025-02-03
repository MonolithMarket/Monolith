// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Factory} from "src/Factory.sol";
import  "lib/solmate/src/tokens/ERC20.sol";
import {USD2} from "src/USD2.sol";
import {SUSD2} from "src/SUSD2.sol";

contract MockCollateral is ERC20 {
    constructor() ERC20("MockCollateral", "MCOLL", 18) {}
}

contract FactoryTest is Test {
    
    Factory factory;
    address operator = address(1);
    address feeRecipient = address(2);

    function setUp() public {
        factory = new Factory(operator);
    }

    function test_constructor() public {
        assertEq(factory.operator(), operator);
        assertEq(factory.feeRecipient(), address(0));
        assertEq(factory.feeBps(), 0);
    }

    function test_deploy() public {
        address collateral = address(new MockCollateral());
        address feed = address(1);
        uint collateralFactor = 5000;
        address operator = address(2);
        
        (address core, address staked) = factory.deploy(
            "TestUSD",
            "USD2",
            collateral,
            feed,
            collateralFactor,
            operator
        );

        assertNotEq(core, address(0));
        assertNotEq(staked, address(0));

        assertEq(address(USD2(core).sUSD2()), staked);
        assertEq(address(SUSD2(staked).asset()), core);

        assertEq(address(USD2(core).collateral()), collateral);
        assertEq(address(USD2(core).feed()), feed);
        assertEq(USD2(core).symbol(), "USD2");
        assertEq(USD2(core).operator(), operator);

        assertEq(USD2(core).name(), "TestUSD");
        assertEq(USD2(core).COLLATERAL_FACTOR_BPS(), collateralFactor);
        assertEq(USD2(core).factory(), address(factory));
        assertEq(SUSD2(staked).symbol(), "sUSD2");

        assertEq(factory.deploymentsLength(), 1);
        assertTrue(factory.isDeployed(core));
    }

    function test_deploy_duplicate() public {
        address collateral = address(new MockCollateral());
        (address core1, address staked1) = _deployTestToken();
        (address core2, address staked2) = _deployTestToken();
        
        assertNotEq(core1, core2);
        assertNotEq(staked1, staked2);
        assertEq(factory.deploymentsLength(), 2);
        assertTrue(factory.isDeployed(core1));
        assertTrue(factory.isDeployed(core2));
    }

    function test_setPendingOperator() public {
        vm.prank(operator);
        factory.setPendingOperator(address(1));
        assertEq(factory.pendingOperator(), address(1));
    }

    function test_setPendingOperator_notOperator() public {
        vm.expectRevert("Only operator can call this function");
        factory.setPendingOperator(address(1));
    }

    function test_acceptOperator() public {
        test_setPendingOperator();
        vm.prank(address(1));
        factory.acceptOperator();
        assertEq(factory.operator(), address(1));
    }

    function test_acceptOperator_notPending() public {
        vm.expectRevert("Only pending operator can accept");
        factory.acceptOperator();
    }

    function test_setFeeRecipient() public {
        vm.prank(operator);
        factory.setFeeRecipient(address(1));
        assertEq(factory.feeRecipient(), address(1));
    }

    function test_setFeeRecipient_notOperator() public {
        vm.expectRevert("Only operator can call this function");
        factory.setFeeRecipient(address(1));
    }

    function test_setFeeBps() public {
        vm.prank(operator);
        factory.setFeeBps(500);
        assertEq(factory.feeBps(), 500);
    }

    function test_setFeeBps_notOperator() public {
        vm.expectRevert("Only operator can call this function");
        factory.setFeeBps(500);
    }

    function test_setFeeBps_exceedsMax() public {
        vm.prank(operator);
        vm.expectRevert("Feebps must be less than or equal to 1000");
        factory.setFeeBps(1001);
    }

    function test_pullFees_notDeployed() public {
        vm.prank(operator);
        factory.setFeeRecipient(address(this));
        vm.expectRevert("Deployment not found");
        factory.pullFees(address(0xdead));
    }

    function test_pullFees_notFeeRecipient() public {
        vm.expectRevert("Only fee recipient can pull fees");
        factory.pullFees(address(0xdead));
    }

    // Helper function for repeated deployments
    function _deployTestToken() internal returns (address, address) {
        address collateral = address(new MockCollateral());
        return factory.deploy(
            "TestUSD",
            "USD2",
            collateral,
            address(1),
            5000,
            operator
        );
    }
}