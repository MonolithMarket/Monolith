// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {
    HelperFixture,
    MockToken,
    LenderStub,
    PersonalStakingHelper,
    PersonalStakingHelperFactory,
    IERC4626,
    StakingRewards,
    TestMarket
} from "./HelperFixture.sol";

contract HelperHandler is Test {
    PersonalStakingHelperFactory public immutable factory;
    TestMarket[2] internal markets;
    uint256[2] public daoIds;
    address[3] public actors;
    mapping(uint256 => mapping(address => uint256)) public expectedShares;
    uint256 public deposits;
    uint256 public withdrawals;
    uint256 public redemptions;
    uint256 public claims;

    constructor(PersonalStakingHelperFactory factory_, uint256[2] memory daoIds_, TestMarket[2] memory markets_) {
        factory = factory_;
        daoIds = daoIds_;
        markets = markets_;
        actors = [address(0xA11CE), address(0xB0B), address(0xCA401)];
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < markets.length; ++j) {
                markets[j].token.mint(actors[i], 1e32);
                vm.prank(actors[i]);
                markets[j].token.approve(address(factory), type(uint256).max);
            }
        }
    }

    function deposit(uint256 marketSeed, uint256 actorSeed, uint256 amountSeed) external {
        uint256 index = marketSeed % markets.length;
        uint256 id = daoIds[index];
        TestMarket memory market = markets[index];
        address actor = actors[actorSeed % 3];
        // Keep deposits well above rounding dust even after arbitrary yield additions.
        uint256 amount = 1e18 + amountSeed % 1e24;
        uint256 quote = market.vault.previewDeposit(amount);
        if (quote == 0) return;
        vm.prank(actor);
        (, uint256 shares) = factory.depositAndStake(id, amount, quote);
        expectedShares[id][actor] += shares;
        deposits++;
    }

    function withdraw(uint256 marketSeed, uint256 actorSeed, uint256 sharesSeed, bool claimRewards) external {
        uint256 index = marketSeed % markets.length;
        uint256 id = daoIds[index];
        TestMarket memory market = markets[index];
        IERC4626 vault = market.vault;
        address actor = actors[actorSeed % 3];
        uint256 staked = expectedShares[id][actor];
        if (staked == 0) return;
        uint256 shares = 1 + sharesSeed % staked;
        PersonalStakingHelper helper = factory.helperOf(id, actor);
        uint256 beforeBalance = vault.balanceOf(actor);
        uint256 reward = helper.earned();
        uint256 beforeGov = market.gov.balanceOf(actor);
        vm.prank(actor);
        helper.withdraw(shares, claimRewards);
        assertEq(vault.balanceOf(actor) - beforeBalance, shares);
        assertEq(market.gov.balanceOf(actor) - beforeGov, claimRewards ? reward : 0);
        expectedShares[id][actor] -= shares;
        withdrawals++;
    }

    function redeem(uint256 marketSeed, uint256 actorSeed, uint256 sharesSeed, bool claimRewards) external {
        uint256 index = marketSeed % markets.length;
        uint256 id = daoIds[index];
        TestMarket memory market = markets[index];
        address actor = actors[actorSeed % 3];
        uint256 staked = expectedShares[id][actor];
        if (staked == 0) return;
        uint256 shares = 1 + sharesSeed % staked;
        uint256 quote = market.vault.previewRedeem(shares);
        if (quote == 0) return;
        PersonalStakingHelper helper = factory.helperOf(id, actor);
        uint256 beforeBalance = market.token.balanceOf(actor);
        uint256 reward = helper.earned();
        uint256 beforeGov = market.gov.balanceOf(actor);
        vm.prank(actor);
        helper.withdrawAndRedeem(shares, quote, claimRewards);
        assertEq(market.token.balanceOf(actor) - beforeBalance, quote);
        assertEq(market.gov.balanceOf(actor) - beforeGov, claimRewards ? reward : 0);
        expectedShares[id][actor] -= shares;
        redemptions++;
    }

    function claim(uint256 marketSeed, uint256 actorSeed) external {
        uint256 index = marketSeed % markets.length;
        TestMarket memory market = markets[index];
        address actor = actors[actorSeed % 3];
        PersonalStakingHelper helper = factory.helperOf(daoIds[index], actor);
        if (address(helper) == address(0)) return;
        uint256 quote = market.pool.earned(address(helper));
        MockToken gov = market.gov;
        uint256 beforeBalance = gov.balanceOf(actor);
        vm.prank(actor);
        helper.claim();
        assertEq(gov.balanceOf(actor) - beforeBalance, quote);
        claims++;
    }

    function accrue(uint256 marketSeed, uint256 elapsedSeed, uint256 interestSeed) external {
        TestMarket memory market = markets[marketSeed % markets.length];
        vm.warp(vm.getBlockTimestamp() + elapsedSeed % 3 days);
        if (market.vault.totalSupply() > 0) market.lender.addInterest(interestSeed % 1e20);
    }
}

contract PersonalStakingHelperInvariantTest is HelperFixture {
    HelperHandler internal handler;
    TestMarket[2] internal markets;
    uint256[2] internal daoIds;

    // Compatibility with current Foundry and the pinned older forge-std interface.
    function excludeSelectors() external pure returns (FuzzSelector[] memory) {
        return new FuzzSelector[](0);
    }

    function setUp() public override {
        super.setUp();
        daoIds[0] = daoId;
        markets[0] = TestMarket(token, gov, lender, vault, pool);
        (daoIds[1], markets[1]) = createDAO("SecondToken", true);
        handler = new HelperHandler(factory, daoIds, markets);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.redeem.selector;
        selectors[3] = handler.claim.selector;
        selectors[4] = handler.accrue.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_PositionsRemainIsolatedAndFullyBacked() public view {
        for (uint256 j; j < markets.length; ++j) {
            uint256 total;
            TestMarket memory market = markets[j];
            for (uint256 i; i < 3; ++i) {
                address actor = handler.actors(i);
                PersonalStakingHelper helper = factory.helperOf(daoIds[j], actor);
                uint256 expected = handler.expectedShares(daoIds[j], actor);
                if (address(helper) == address(0)) {
                    assertEq(expected, 0);
                    continue;
                }
                assertEq(helper.owner(), actor);
                assertEq(address(helper.asset()), address(market.token));
                assertEq(address(helper.vault()), address(market.vault));
                assertEq(address(helper.stakingRewards()), address(market.pool));
                assertEq(address(helper.rewardToken()), address(market.gov));
                assertEq(helper.stakedShares(), expected);
                assertClean(helper);
                total += expected;
            }
            assertEq(market.pool.totalSupply(), total);
            assertEq(market.vault.balanceOf(address(market.pool)), total);
        }
    }
}
