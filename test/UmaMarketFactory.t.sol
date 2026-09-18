// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {Coin} from "src/Coin.sol";
import {Factory} from "src/Factory.sol";
import {Lender} from "src/Lender.sol";
import {UmaEventTriggerOracle, IUmaOptimisticOracleV3} from "src/UmaEventTriggerOracle.sol";
import {UmaMarketFactory} from "src/UmaMarketFactory.sol";
import {Vault} from "src/Vault.sol";

interface IUmaCallbackRecipient {
    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external;
}

contract UmaMarketFactoryERC20Mock is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol, 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract UmaMarketFactoryFeedMock {
    int256 public price = 1e18;
    uint8 public decimals = 18;

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, price, 0, block.timestamp, 0);
    }
}

contract UmaMarketFactoryOptimisticOracleV3Mock is IUmaOptimisticOracleV3 {
    ERC20 public defaultCurrency;
    uint64 public defaultLiveness = 7200;
    uint256 public minimumBond = 100e18;

    uint256 public assertionCount;
    bytes32 public lastAssertionId;

    mapping(bytes32 => bool) public assertionExists;
    mapping(bytes32 => bool) public settlementResult;
    mapping(bytes32 => address) public callbackRecipient;

    constructor(ERC20 _defaultCurrency) {
        defaultCurrency = _defaultCurrency;
    }

    function getMinimumBond(address) external view returns (uint256) {
        return minimumBond;
    }

    function assertTruth(
        bytes memory claim,
        address asserter,
        address _callbackRecipient,
        address,
        uint64,
        ERC20 currency,
        uint256 bond,
        bytes32,
        bytes32
    ) external returns (bytes32 assertionId) {
        if (bond > 0) currency.transferFrom(msg.sender, address(this), bond);

        assertionId = keccak256(abi.encode(claim, asserter, ++assertionCount));
        assertionExists[assertionId] = true;
        callbackRecipient[assertionId] = _callbackRecipient;
        lastAssertionId = assertionId;
    }

    function settleAndGetAssertionResult(bytes32 assertionId) external returns (bool) {
        require(assertionExists[assertionId], "unknown assertion");

        bool result = settlementResult[assertionId];
        IUmaCallbackRecipient(callbackRecipient[assertionId]).assertionResolvedCallback(assertionId, result);
        return result;
    }

    function setSettlementResult(bytes32 assertionId, bool result) external {
        settlementResult[assertionId] = result;
    }
}

contract UmaMarketFactoryTest is Test {
    bytes constant TRIGGER_CLAIM = "The configured Monolith event trigger has occurred.";
    uint256 constant MIN_DEBT_FLOOR = 1e15;

    Factory factory;
    UmaMarketFactory umaMarketFactory;
    UmaMarketFactoryERC20Mock collateral;
    UmaMarketFactoryERC20Mock currency;
    UmaMarketFactoryFeedMock priceFeed;
    UmaMarketFactoryOptimisticOracleV3Mock optimisticOracleV3;

    address factoryOperator = address(0x123);
    address marketCreator = address(0xBEEF);
    address marketOperator = address(0xCAFE);
    address manager = address(0xD00D);
    address asserter = address(0xA55E);

    function setUp() public {
        collateral = new UmaMarketFactoryERC20Mock("Test Collateral", "TCOL");
        currency = new UmaMarketFactoryERC20Mock("UMA Bond", "BOND");
        priceFeed = new UmaMarketFactoryFeedMock();
        optimisticOracleV3 = new UmaMarketFactoryOptimisticOracleV3Mock(ERC20(address(currency)));

        factory = new Factory(factoryOperator, MIN_DEBT_FLOOR);
        umaMarketFactory = new UmaMarketFactory(address(factory), address(optimisticOracleV3));
    }

    function test_constructorValidatesInputs() public {
        vm.expectRevert("Invalid factory");
        new UmaMarketFactory(address(0), address(optimisticOracleV3));

        vm.expectRevert("Invalid oracle");
        new UmaMarketFactory(address(factory), address(0));
    }

    function test_deployCreatesAndBindsUmaMarket() public {
        (address lender, address coin, address vault, address eventTriggerOracle) = _deployUmaMarket();

        assertEq(factory.deploymentsLength(), 1);
        assertEq(factory.deployments(0), lender);
        assertTrue(factory.isDeployed(lender));

        assertEq(umaMarketFactory.umaMarketsLength(), 1);
        assertEq(umaMarketFactory.umaMarkets(0), lender);
        assertEq(umaMarketFactory.eventTriggerOracleOf(lender), eventTriggerOracle);

        Lender lenderContract = Lender(lender);
        assertEq(lenderContract.operator(), marketOperator);
        assertEq(lenderContract.manager(), manager);
        assertEq(lenderContract.eventTriggerOperator(), eventTriggerOracle);

        UmaEventTriggerOracle adapter = UmaEventTriggerOracle(eventTriggerOracle);
        assertEq(address(adapter.optimisticOracleV3()), address(optimisticOracleV3));
        assertEq(adapter.owner(), address(umaMarketFactory));
        assertEq(address(adapter.lender()), lender);
        assertEq(adapter.triggerClaim(), TRIGGER_CLAIM);

        Coin coinContract = Coin(coin);
        assertEq(coinContract.name(), "Test USD");
        assertEq(coinContract.symbol(), "tUSD");
        assertEq(coinContract.minter(), lender);

        Vault vaultContract = Vault(vault);
        assertEq(vaultContract.name(), "Staked Test USD");
        assertEq(vaultContract.symbol(), "stUSD");
        assertEq(address(vaultContract.lender()), lender);
    }

    function test_deployRevertsForEmptyTriggerClaim() public {
        UmaMarketFactory.DeployParams memory params = _defaultParams();
        params.triggerClaim = "";

        vm.prank(marketCreator);
        vm.expectRevert("Invalid claim");
        umaMarketFactory.deploy(params);
    }

    function test_truthfulUmaResolutionActivatesLender() public {
        (address lender,,, address eventTriggerOracle) = _deployUmaMarket();
        UmaEventTriggerOracle adapter = UmaEventTriggerOracle(eventTriggerOracle);

        uint256 bond = optimisticOracleV3.minimumBond();
        currency.mint(asserter, bond);

        vm.prank(asserter);
        currency.approve(address(adapter), bond);

        vm.prank(asserter);
        bytes32 assertionId = adapter.assertEventTrigger();

        optimisticOracleV3.setSettlementResult(assertionId, true);
        assertTrue(adapter.settleAndGetAssertionResult(assertionId));
        assertTrue(Lender(lender).eventTriggerMode());
    }

    function _deployUmaMarket()
        internal
        returns (address lender, address coin, address vault, address eventTriggerOracle)
    {
        vm.prank(marketCreator);
        return umaMarketFactory.deploy(_defaultParams());
    }

    function _defaultParams() internal view returns (UmaMarketFactory.DeployParams memory) {
        return UmaMarketFactory.DeployParams({
            name: "Test USD",
            symbol: "tUSD",
            collateral: address(collateral),
            psmAsset: address(0),
            psmVault: address(0),
            feed: address(priceFeed),
            collateralFactor: 5000,
            minDebt: 1000e18,
            timeUntilImmutability: 365 days,
            operator: marketOperator,
            manager: manager,
            halfLife: 7 days,
            targetPsmDebtRatioStartBps: 2000,
            targetPsmDebtRatioEndBps: 4000,
            stalenessThreshold: 48 hours,
            maxBorrowDeltaBps: 50,
            psmVaultMinTotalSupply: 1,
            triggerClaim: TRIGGER_CLAIM
        });
    }
}
