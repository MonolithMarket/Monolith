// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Lender, ERC20, Coin, Vault, InterestModel, IChainlinkFeed, IFactory} from "src/Lender.sol";
import {ERC4626} from "lib/solmate/src/tokens/ERC4626.sol";

contract FeedMock {
    uint8 public decimals = 18;
    int256 public price = 1e18;

    function setPrice(int256 _price) external {
        price = _price;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (0, price, 0, block.timestamp, 0);
    }
}

contract ERC20Mock is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol, 18) {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function burn(uint256 amount) public {
        _burn(msg.sender, amount);
    }
}

contract VaultMock {}

contract InterestModelMock {
    function calculateInterest(
        uint totalPaidDebt,
        uint lastRate,
        uint timeElapsed,
        uint,
        uint,
        uint,
        uint
    ) external pure returns (uint currBorrowRate, uint interest) {
        currBorrowRate = lastRate;
        interest = totalPaidDebt * timeElapsed / 365 days / 10;
    }
}

contract FactoryMock {
    uint public minDebtFloor = 1e15;

    function getFeeOf(address) external pure returns (uint) {
        return 0;
    }
}

contract LenderTest is Test {
    Lender lender;
    ERC20Mock collateral;
    ERC20Mock coin;
    ERC20Mock psmAsset;
    FeedMock feed;

    address operator = address(0x123);
    address manager = address(0x456);
    address eventTriggerOperator = address(0x789);
    address borrower = address(0xBEEF);

    function setUp() public {
        collateral = new ERC20Mock("Collateral", "COL");
        coin = new ERC20Mock("Coin", "COIN");
        psmAsset = new ERC20Mock("PSM", "PSM");
        feed = new FeedMock();

        lender = newLender(address(psmAsset), address(0), eventTriggerOperator);
    }

    function newLender(address _psmAsset, address _psmVault, address _eventTriggerOperator) internal returns (Lender) {
        return new Lender(Lender.LenderParams({
            collateral: ERC20(address(collateral)),
            psmAsset: ERC20(_psmAsset),
            psmVault: ERC4626(_psmVault),
            feed: IChainlinkFeed(address(feed)),
            coin: Coin(address(coin)),
            vault: Vault(address(new VaultMock())),
            interestModel: InterestModel(address(new InterestModelMock())),
            factory: IFactory(address(new FactoryMock())),
            operator: operator,
            manager: manager,
            eventTriggerOperator: _eventTriggerOperator,
            collateralFactor: 5000,
            minDebt: 1000e18,
            timeUntilImmutability: 365 days,
            halfLife: 7 days,
            targetPsmDebtRatioStartBps: 2000,
            targetPsmDebtRatioEndBps: 4000,
            stalenessThreshold: 48 hours,
            maxBorrowDeltaBps: 50,
            psmVaultMinTotalSupply: 1
        }));
    }

    function openPosition(uint collateralAmount, uint borrowAmount) internal {
        collateral.mint(borrower, collateralAmount);
        vm.startPrank(borrower);
        collateral.approve(address(lender), collateralAmount);
        lender.adjust(borrower, int256(collateralAmount), int256(borrowAmount));
        vm.stopPrank();
    }

    function test_constructor_setsEventTriggerOperator() public view {
        assertEq(lender.eventTriggerOperator(), eventTriggerOperator);
        assertFalse(lender.eventTriggerMode());
    }

    function test_constructor_revertsWhenEventTriggerOperatorIsOperator() public {
        VaultMock vaultMock = new VaultMock();
        InterestModelMock interestModel = new InterestModelMock();
        FactoryMock factory = new FactoryMock();

        vm.expectRevert("Event trigger operator cannot be operator");
        new Lender(Lender.LenderParams({
            collateral: ERC20(address(collateral)),
            psmAsset: ERC20(address(psmAsset)),
            psmVault: ERC4626(address(0)),
            feed: IChainlinkFeed(address(feed)),
            coin: Coin(address(coin)),
            vault: Vault(address(vaultMock)),
            interestModel: InterestModel(address(interestModel)),
            factory: IFactory(address(factory)),
            operator: operator,
            manager: manager,
            eventTriggerOperator: operator,
            collateralFactor: 5000,
            minDebt: 1000e18,
            timeUntilImmutability: 365 days,
            halfLife: 7 days,
            targetPsmDebtRatioStartBps: 2000,
            targetPsmDebtRatioEndBps: 4000,
            stalenessThreshold: 48 hours,
            maxBorrowDeltaBps: 50,
            psmVaultMinTotalSupply: 1
        }));
    }

    function test_borrow_usesOnlyPaidDebt() public {
        openPosition(10_000e18, 1_000e18);

        assertEq(lender.totalPaidDebt(), 1_000e18);
        assertEq(lender.totalPaidDebtShares(), 1_000e18);
        assertEq(lender.paidDebtShares(borrower), 1_000e18);
        assertEq(lender.getDebtOf(borrower), 1_000e18);
    }

    function test_getPsmDebtRatio_usesPsmLiquidityAndPaidDebt() public {
        openPosition(10_000e18, 1_000e18);

        psmAsset.mint(address(this), 250e18);
        psmAsset.approve(address(lender), 250e18);
        lender.buy(250e18, 250e18);

        assertEq(lender.getPsmDebtRatio(), 2000);
    }

    function test_getPsmDebtRatio_returnsZeroWhenSupplyIsZero() public view {
        assertEq(lender.getPsmDebtRatio(), 0);
    }

    function test_getPsmDebtRatio_returnsFullRatioWhenSupplyIsOnlyPsm() public {
        psmAsset.mint(address(this), 1_000e18);
        psmAsset.approve(address(lender), 1_000e18);
        lender.buy(1_000e18, 1_000e18);

        assertEq(lender.getPsmDebtRatio(), 10000);
    }

    function test_psmBuyAfterImmutabilityDeadline_hasNoFee() public {
        uint deadline = lender.immutabilityDeadline();
        vm.warp(deadline + 1);

        psmAsset.mint(address(this), 1_000e18);
        psmAsset.approve(address(lender), 1_000e18);

        uint preview = lender.getBuyAmountOut(1_000e18);
        assertEq(preview, 1_000e18);

        uint coinOut = lender.buy(1_000e18, 1_000e18);
        assertEq(coinOut, 1_000e18);
        assertEq(coin.balanceOf(address(this)), 1_000e18);
        assertEq(lender.accruedLocalReserves(), 0);
    }

    function test_eventTriggerMode_onlyRoleCanEnableAndIsPermanent() public {
        vm.prank(operator);
        vm.expectRevert("Unauthorized");
        lender.enableEventTriggerMode();

        vm.prank(eventTriggerOperator);
        lender.enableEventTriggerMode();

        assertTrue(lender.eventTriggerMode());

        vm.prank(eventTriggerOperator);
        vm.expectRevert("Event trigger mode active");
        lender.enableEventTriggerMode();
    }

    function test_eventTriggerMode_disablesNewBorrows() public {
        vm.prank(eventTriggerOperator);
        lender.enableEventTriggerMode();

        collateral.mint(borrower, 10_000e18);
        vm.startPrank(borrower);
        collateral.approve(address(lender), 10_000e18);
        vm.expectRevert("Event trigger mode active");
        lender.adjust(borrower, 10_000e18, 1_000e18);
        vm.stopPrank();
    }

    function test_eventTriggerMode_allowsCollateralWithdrawWithoutRepayment() public {
        openPosition(10_000e18, 1_000e18);

        vm.prank(eventTriggerOperator);
        lender.enableEventTriggerMode();

        vm.prank(borrower);
        lender.adjust(borrower, -10_000e18, 0);

        assertEq(collateral.balanceOf(borrower), 10_000e18);
        assertEq(lender.collateralBalances(borrower), 0);
        assertEq(lender.getDebtOf(borrower), lender.totalPaidDebt());
        assertGt(lender.getDebtOf(borrower), 0);
    }

    function test_eventTriggerMode_disablesLiquidationsAndWriteOffs() public {
        openPosition(10_000e18, 1_000e18);

        vm.prank(eventTriggerOperator);
        lender.enableEventTriggerMode();

        coin.mint(address(this), 1_000e18);
        coin.approve(address(lender), 1_000e18);

        vm.expectRevert("Event trigger mode active");
        lender.liquidate(borrower, 1_000e18, 0);

        vm.expectRevert("Event trigger mode active");
        lender.writeOff(borrower, address(this));
    }

    function test_eventTriggerMode_stopsNewInterestAccrual() public {
        openPosition(10_000e18, 1_000e18);
        vm.warp(block.timestamp + 30 days);

        vm.prank(eventTriggerOperator);
        lender.enableEventTriggerMode();

        uint debtAfterTrigger = lender.totalPaidDebt();
        vm.warp(block.timestamp + 365 days);
        lender.accrueInterest();

        assertEq(lender.totalPaidDebt(), debtAfterTrigger);
        assertEq(lender.getPendingInterest(), 0);
    }
}
