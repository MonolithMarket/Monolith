// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import {Test, console} from "forge-std/Test.sol";
import "src/Factory.sol";
import "src/Lender.sol";
import "src/Vault.sol";
import "src/Coin.sol";
import "src/InterestModel.sol";
import "lib/solmate/src/utils/CREATE3.sol";
import "lib/solmate/src/tokens/ERC20.sol";

// Mock contracts
contract ERC20Mock is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol, 18) {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract ChainlinkMock {
    int256 public price = 1e18;
    uint8 public decimals = 18;
    
    function setPrice(int256 _price) public {
        price = _price;
    }
    
    function latestRoundData() external view returns (
        uint80, int256, uint256, uint256, uint80
    ) {
        return (0, price, 0, block.timestamp, 0);
    }
}

// Add TestFactory after the mock contracts and before FactoryTest
// TestFactory inherits from Factory and adds test helpers
contract TestFactory is Factory {
    constructor(address _operator) Factory(_operator) {}
    
    // Helper function for testing that directly adds a deployment
    function addTestDeployment(address _deployment) external {
        deployments.push(_deployment);
        isDeployed[_deployment] = true;
    }
}

contract FactoryTest is Test {
    Factory factory;
    address public operatorAddr;
    address public feeRecipientAddr;
    ERC20Mock public collateral;
    ChainlinkMock public priceFeed;
    
    // Test constants
    uint256 constant DEFAULT_FEE_BPS = 500; // 5%
    uint256 constant MAX_FEE_BPS = 1000; // 10%
    
    function setUp() public {
        // Set operator and fee recipient addresses
        operatorAddr = address(0x123);
        feeRecipientAddr = address(0x456);
        
        // Deploy mock contracts
        collateral = new ERC20Mock("Test Collateral", "TCOL");
        priceFeed = new ChainlinkMock();
        
        // Deploy factory with operator address
        factory = new Factory(operatorAddr);
        
        // Set fee recipient
        vm.prank(operatorAddr);
        factory.setFeeRecipient(feeRecipientAddr);
        
        // Set default fee
        vm.prank(operatorAddr);
        factory.setFeeBps(DEFAULT_FEE_BPS);
    }
    
    function test_constructor() public {
        // Deploy a new factory for testing constructor
        address newOperator = address(0x789);
        Factory newFactory = new Factory(newOperator);
        
        // Verify initial state
        assertEq(newFactory.operator(), newOperator, "Operator should be set correctly");
        assertEq(newFactory.pendingOperator(), address(0), "Initial pendingOperator should be zero address");
        assertEq(newFactory.feeBps(), 0, "Initial fee should be zero");
        assertEq(newFactory.feeRecipient(), address(0), "Initial feeRecipient should be zero address");
        
        // Verify interest model was deployed
        address interestModel = newFactory.interestModel();
        assertTrue(interestModel != address(0), "Interest model should be deployed");
    }
    
    function test_setPendingOperator() public {
        address newOperator = address(0x789);
        
        // Call setPendingOperator as the current operator
        vm.prank(operatorAddr);
        factory.setPendingOperator(newOperator);
        
        // Verify pendingOperator was updated
        assertEq(factory.pendingOperator(), newOperator, "pendingOperator should be updated");
        assertEq(factory.operator(), operatorAddr, "operator should remain unchanged");
    }
    
    function test_setPendingOperator_revertsForNonOperator() public {
        address newOperator = address(0x789);
        address unauthorizedCaller = address(0xBAD);
        
        // Attempt to call setPendingOperator from unauthorized address
        vm.prank(unauthorizedCaller);
        vm.expectRevert("Only operator can call this function");
        factory.setPendingOperator(newOperator);
        
        // Verify pendingOperator remains unchanged
        assertEq(factory.pendingOperator(), address(0), "pendingOperator should remain unchanged");
    }
    
    function test_acceptOperator() public {
        address newOperator = address(0x789);
        
        // First set pending operator
        vm.prank(operatorAddr);
        factory.setPendingOperator(newOperator);
        
        // Accept operator role
        vm.prank(newOperator);
        factory.acceptOperator();
        
        // Verify operator was updated
        assertEq(factory.operator(), newOperator, "operator should be updated");
        assertEq(factory.pendingOperator(), address(0), "pendingOperator should be reset to zero address");
    }
    
    function test_acceptOperator_revertsForNonPendingOperator() public {
        address newOperator = address(0x789);
        address unauthorizedCaller = address(0xBAD);
        
        // First set pending operator
        vm.prank(operatorAddr);
        factory.setPendingOperator(newOperator);
        
        // Attempt to accept operator role from unauthorized address
        vm.prank(unauthorizedCaller);
        vm.expectRevert("Only pending operator can accept");
        factory.acceptOperator();
        
        // Verify operator remains unchanged
        assertEq(factory.operator(), operatorAddr, "operator should remain unchanged");
        assertEq(factory.pendingOperator(), newOperator, "pendingOperator should remain unchanged");
    }
    
    function test_setFeeRecipient() public {
        address newFeeRecipient = address(0xFEE);
        
        // Call setFeeRecipient as the operator
        vm.prank(operatorAddr);
        factory.setFeeRecipient(newFeeRecipient);
        
        // Verify feeRecipient was updated
        assertEq(factory.feeRecipient(), newFeeRecipient, "feeRecipient should be updated");
    }
    
    function test_setFeeRecipient_revertsForNonOperator() public {
        address newFeeRecipient = address(0xFEE);
        address unauthorizedCaller = address(0xBAD);
        
        // Attempt to call setFeeRecipient from unauthorized address
        vm.prank(unauthorizedCaller);
        vm.expectRevert("Only operator can call this function");
        factory.setFeeRecipient(newFeeRecipient);
        
        // Verify feeRecipient remains unchanged
        assertEq(factory.feeRecipient(), feeRecipientAddr, "feeRecipient should remain unchanged");
    }
    
    function test_setFeeBps() public {
        uint256 newFeeBps = 750; // 7.5%
        
        // Call setFeeBps as the operator
        vm.prank(operatorAddr);
        factory.setFeeBps(newFeeBps);
        
        // Verify feeBps was updated
        assertEq(factory.feeBps(), newFeeBps, "feeBps should be updated");
    }
    
    function test_setFeeBps_revertsForNonOperator() public {
        uint256 newFeeBps = 750; // 7.5%
        address unauthorizedCaller = address(0xBAD);
        
        // Attempt to call setFeeBps from unauthorized address
        vm.prank(unauthorizedCaller);
        vm.expectRevert("Only operator can call this function");
        factory.setFeeBps(newFeeBps);
        
        // Verify feeBps remains unchanged
        assertEq(factory.feeBps(), DEFAULT_FEE_BPS, "feeBps should remain unchanged");
    }
    
    function test_setFeeBps_revertsForExcessiveFee() public {
        uint256 excessiveFeeBps = MAX_FEE_BPS + 1; // Above 10%
        
        // Attempt to set fee above maximum
        vm.prank(operatorAddr);
        vm.expectRevert("Feebps must be less than or equal to 1000");
        factory.setFeeBps(excessiveFeeBps);
        
        // Verify feeBps remains unchanged
        assertEq(factory.feeBps(), DEFAULT_FEE_BPS, "feeBps should remain unchanged");
    }
    
    function test_setCustomFeeBps() public {
        address lenderAddr = address(0xDEF);
        uint256 customFeeBps = 300; // 3%
        
        // Call setCustomFeeBps as the operator
        vm.prank(operatorAddr);
        factory.setCustomFeeBps(lenderAddr, customFeeBps);
        
        // Verify custom fee was set
        assertEq(factory.customFeeBps(lenderAddr), customFeeBps, "Custom fee should be set");
        
        // Verify getFeeOf returns custom fee
        assertEq(factory.getFeeOf(lenderAddr), customFeeBps, "getFeeOf should return custom fee");
    }
    
    function test_setCustomFeeBps_revertsForNonOperator() public {
        address lenderAddr = address(0xDEF);
        uint256 customFeeBps = 300; // 3%
        address unauthorizedCaller = address(0xBAD);
        
        // Attempt to call setCustomFeeBps from unauthorized address
        vm.prank(unauthorizedCaller);
        vm.expectRevert("Only operator can call this function");
        factory.setCustomFeeBps(lenderAddr, customFeeBps);
        
        // Verify custom fee was not set
        assertEq(factory.customFeeBps(lenderAddr), 0, "Custom fee should not be set");
        
        // Verify getFeeOf returns default fee
        assertEq(factory.getFeeOf(lenderAddr), DEFAULT_FEE_BPS, "getFeeOf should return default fee");
    }
    
    function test_setCustomFeeBps_revertsForExcessiveFee() public {
        address lenderAddr = address(0xDEF);
        uint256 excessiveFeeBps = MAX_FEE_BPS + 1; // Above 10%
        
        // Attempt to set custom fee above maximum
        vm.prank(operatorAddr);
        vm.expectRevert("Feebps must be less than or equal to 1000");
        factory.setCustomFeeBps(lenderAddr, excessiveFeeBps);
        
        // Verify custom fee was not set
        assertEq(factory.customFeeBps(lenderAddr), 0, "Custom fee should not be set");
    }
    
    function test_getFeeOf() public {
        address lenderWithDefaultFee = address(0xDEF1);
        address lenderWithCustomFee = address(0xDEF2);
        uint256 customFeeBps = 300; // 3%
        
        // Set custom fee for one lender
        vm.prank(operatorAddr);
        factory.setCustomFeeBps(lenderWithCustomFee, customFeeBps);
        
        // Verify getFeeOf returns correct fees
        assertEq(factory.getFeeOf(lenderWithDefaultFee), DEFAULT_FEE_BPS, "getFeeOf should return default fee for lender without custom fee");
        assertEq(factory.getFeeOf(lenderWithCustomFee), customFeeBps, "getFeeOf should return custom fee for lender with custom fee");
    }
    
    function test_deploy() public {
        // Test parameters
        string memory name = "Test USD";
        string memory symbol = "tUSD";
        address collateralAddr = address(collateral);
        address feedAddr = address(priceFeed);
        uint256 collateralFactor = 5000; // 50%
        uint256 minDebt = 1000e18;
        uint256 timeUntilImmutability = 365 days;
        address deployerOperator = address(0xBEEF);
        address managerAddr = address(0x1234);

        // Deploy new lending market
        vm.prank(deployerOperator);
        Factory.DeployParams memory params = Factory.DeployParams({
            name: name,
            symbol: symbol,
            collateral: collateralAddr,
            psmAsset: address(0),
            psmVault: address(0),
            feed: feedAddr,
            collateralFactor: collateralFactor,
            minDebt: minDebt,
            timeUntilImmutability: timeUntilImmutability,
            operator: deployerOperator,
            manager: managerAddr,
            halfLife: 7 days,
            targetFreeDebtRatioStartBps: 2000,
            targetFreeDebtRatioEndBps: 4000,
            redeemFeeBps: 30,
            stalenessThreshold: 48 hours,
            maxBorrowDeltaBps: 50
        });
        (address lender, address coin, address vault) = factory.deploy(params);

        // Verify addresses are non-zero
        assertTrue(lender != address(0), "Lender address should be non-zero");
        assertTrue(coin != address(0), "Coin address should be non-zero");
        assertTrue(vault != address(0), "Vault address should be non-zero");
        
        // Verify deployment was recorded
        assertEq(factory.deploymentsLength(), 1, "Deployments length should be 1");
        assertEq(factory.deployments(0), lender, "Deployment should be recorded in deployments array");
        assertTrue(factory.isDeployed(lender), "isDeployed should be true for lender");
        
        // Verify lender configuration
        Lender lenderContract = Lender(lender);
        assertEq(address(lenderContract.collateral()), collateralAddr, "Lender collateral should be set correctly");
        assertEq(address(lenderContract.feed()), feedAddr, "Lender feed should be set correctly");
        assertEq(lenderContract.collateralFactor(), collateralFactor, "Lender collateralFactor should be set correctly");
        assertEq(lenderContract.minDebt(), minDebt, "Lender minDebt should be set correctly");
        assertEq(lenderContract.manager(), managerAddr, "Lender manager should be set correctly");
        
        // Verify coin configuration
        Coin coinContract = Coin(coin);
        assertEq(coinContract.name(), params.name, "Coin name should be set correctly");
        assertEq(coinContract.symbol(), params.symbol, "Coin symbol should be set correctly");
        assertEq(coinContract.minter(), lender, "Coin minter should be set to lender");
        
        // Verify vault configuration
        Vault vaultContract = Vault(vault);
        assertEq(vaultContract.name(), string(abi.encodePacked("Staked ", params.name)), "Vault name should be set correctly");
        assertEq(vaultContract.symbol(), string(abi.encodePacked("s", params.symbol)), "Vault symbol should be set correctly");
        assertEq(address(vaultContract.lender()), lender, "Vault lender should be set correctly");
    }
    
    function test_multiDeploy() public {
        // Test parameters for first deployment
        string memory name1 = "Test USD";
        string memory symbol1 = "tUSD";
        // Test parameters for second deployment
        string memory name2 = "Test EUR";
        string memory symbol2 = "tEUR";

        address deployerOperator = address(0xBEEF);
        address managerAddr1 = address(0x1234);
        address managerAddr2 = address(0x5678);

        // Deploy first lending market
        vm.prank(deployerOperator);
        Factory.DeployParams memory params1 = Factory.DeployParams({
            name: name1,
            symbol: symbol1,
            collateral: address(collateral),
            psmAsset: address(0),
            psmVault: address(0),
            feed: address(priceFeed),
            collateralFactor: 5000, // 50%
            minDebt: 1000e18,
            timeUntilImmutability: 365 days,
            operator: deployerOperator,
            manager: managerAddr1,
            halfLife: 7 days,
            targetFreeDebtRatioStartBps: 2000,
            targetFreeDebtRatioEndBps: 4000,
            redeemFeeBps: 30,
            stalenessThreshold: 48 hours,
            maxBorrowDeltaBps: 50
        });
        (address lender1, address coin1, address vault1) = factory.deploy(params1);

        // Deploy second lending market
        vm.prank(deployerOperator);
        Factory.DeployParams memory params2 = Factory.DeployParams({
            name: name2,
            symbol: symbol2,
            collateral: address(collateral),
            psmAsset: address(0),
            psmVault: address(0),
            feed: address(priceFeed),
            collateralFactor: 5000, // 50%
            minDebt: 1000e18,
            timeUntilImmutability: 365 days,
            operator: deployerOperator,
            manager: managerAddr2,
            halfLife: 7 days,
            targetFreeDebtRatioStartBps: 2000,
            targetFreeDebtRatioEndBps: 4000,
            redeemFeeBps: 30,
            stalenessThreshold: 48 hours,
            maxBorrowDeltaBps: 50
        });
        (address lender2, address coin2, address vault2) = factory.deploy(params2);
        
        // Verify deployments were recorded
        assertEq(factory.deploymentsLength(), 2, "Deployments length should be 2");
        assertEq(factory.deployments(0), lender1, "First deployment should be recorded in deployments array");
        assertEq(factory.deployments(1), lender2, "Second deployment should be recorded in deployments array");
        assertTrue(factory.isDeployed(lender1), "isDeployed should be true for first lender");
        assertTrue(factory.isDeployed(lender2), "isDeployed should be true for second lender");
        
        // Verify all addresses are unique
        assertTrue(lender1 != lender2, "Lender addresses should be different");
        assertTrue(coin1 != coin2, "Coin addresses should be different");
        assertTrue(vault1 != vault2, "Vault addresses should be different");
        
        // Verify correct configuration for second deployment
        Coin coinContract2 = Coin(coin2);
        assertEq(coinContract2.name(), name2, "Second coin name should be set correctly");
        assertEq(coinContract2.symbol(), symbol2, "Second coin symbol should be set correctly");
    }

    function test_managerPermissions() public {
        // Test parameters
        string memory name = "Test Manager";
        string memory symbol = "TMGR";
        address collateralAddr = address(collateral);
        address feedAddr = address(priceFeed);
        uint256 collateralFactor = 5000; // 50%
        uint256 minDebt = 1000e18;
        uint256 timeUntilImmutability = 365 days;
        address deployerOperator = address(0xBEEF);
        address managerAddr = address(0x1234);

        // Deploy new lending market
        vm.prank(deployerOperator);
        Factory.DeployParams memory params = Factory.DeployParams({
            name: name,
            symbol: symbol,
            collateral: collateralAddr,
            psmAsset: address(0),
            psmVault: address(0),
            feed: feedAddr,
            collateralFactor: collateralFactor,
            minDebt: minDebt,
            timeUntilImmutability: timeUntilImmutability,
            operator: deployerOperator,
            manager: managerAddr,
            halfLife: 7 days,
            targetFreeDebtRatioStartBps: 2000,
            targetFreeDebtRatioEndBps: 4000,
            redeemFeeBps: 30,
            stalenessThreshold: 48 hours,
            maxBorrowDeltaBps: 50
        });
        (address lender, address coin, address vault) = factory.deploy(params);

        // Verify manager is correctly stored in Lender
        Lender lenderContract = Lender(lender);
        assertEq(lenderContract.manager(), managerAddr, "Manager should be set correctly in Lender");

        // Test manager setter function - operator can set manager
        address newManagerAddr = address(0x1111111111111111111111111111111111111111);
        vm.prank(deployerOperator);
        lenderContract.setManager(newManagerAddr);
        assertEq(lenderContract.manager(), newManagerAddr, "Manager should be updated directly by operator");

        // Test that manager can also set manager (self-update)
        address anotherManagerAddr = address(0x2222222222222222222222222222222222222222);
        vm.prank(newManagerAddr);
        lenderContract.setManager(anotherManagerAddr);
        assertEq(lenderContract.manager(), anotherManagerAddr, "Manager should be able to update themselves");
    }
    
    function test_pullReserves() public {
        // Create a mock lender for testing
        LenderMock mockLender = new LenderMock();
        
        // Deploy a test factory with the testing helper method
        TestFactory testFactory = new TestFactory(operatorAddr);
        
        // Set the fee recipient
        vm.prank(operatorAddr);
        testFactory.setFeeRecipient(feeRecipientAddr);
        
        // Directly add the mock lender to deployments and mark it as deployed
        testFactory.addTestDeployment(address(mockLender));
        
        // Call pullReserves as fee recipient
        vm.prank(feeRecipientAddr);
        testFactory.pullReserves(address(mockLender));
        
        // Verify that pullGlobalReserves was called on the lender
        assertTrue(mockLender.pullGlobalReservesCalled(), "pullGlobalReserves should be called on the lender");
        assertEq(mockLender.pullGlobalReservesRecipient(), feeRecipientAddr, "Fee recipient should be passed to lender");
    }
    
    function test_pullReserves_revertsForNonFeeRecipient() public {
        // Create a mock lender for testing
        LenderMock mockLender = new LenderMock();
        
        // Deploy a test factory with the testing helper method
        TestFactory testFactory = new TestFactory(operatorAddr);
        
        // Set the fee recipient
        vm.prank(operatorAddr);
        testFactory.setFeeRecipient(feeRecipientAddr);
        
        // Directly add the mock lender to deployments and mark it as deployed
        testFactory.addTestDeployment(address(mockLender));
        
        // Attempt to call pullReserves from unauthorized address
        address unauthorizedCaller = address(0xBAD);
        vm.prank(unauthorizedCaller);
        vm.expectRevert("Only fee recipient can pull reserves");
        testFactory.pullReserves(address(mockLender));
        
        // Verify pullGlobalReserves was not called
        assertFalse(mockLender.pullGlobalReservesCalled(), "pullGlobalReserves should not be called");
    }
    
    function test_pullReserves_revertsForNonDeployment() public {
        // Create a non-deployed lender mock
        LenderMock nonDeployedLender = new LenderMock();
        
        // Attempt to pull reserves from non-deployed lender
        vm.prank(feeRecipientAddr);
        vm.expectRevert("Deployment not found");
        factory.pullReserves(address(nonDeployedLender));
        
        // Verify pullGlobalReserves was not called
        assertFalse(nonDeployedLender.pullGlobalReservesCalled(), "pullGlobalReserves should not be called");
    }
}

// Mock for testing pullReserves
contract LenderMock {
    bool private _pullGlobalReservesCalled;
    address private _pullGlobalReservesRecipient;
    
    function pullGlobalReserves(address recipient) external {
        _pullGlobalReservesCalled = true;
        _pullGlobalReservesRecipient = recipient;
    }
    
    function pullGlobalReservesCalled() external view returns (bool) {
        return _pullGlobalReservesCalled;
    }
    
    function pullGlobalReservesRecipient() external view returns (address) {
        return _pullGlobalReservesRecipient;
    }
} 