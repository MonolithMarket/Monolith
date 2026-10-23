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
    StakingRewards
} from "./HelperFixture.sol";

contract HelperHandler is Test {
    PersonalStakingHelperFactory public immutable factory;
    IERC4626 public immutable vault;
    StakingRewards public immutable pool;
    MockToken public immutable token;
    LenderStub public immutable lender;
    address[3] public actors;
    mapping(address => uint256) public expectedShares;
    uint256 public deposits;
    uint256 public withdrawals;
    uint256 public redemptions;
    uint256 public claims;

    constructor(PersonalStakingHelperFactory factory_, MockToken token_, LenderStub lender_, StakingRewards pool_) {
        factory = factory_;
        token = token_;
        lender = lender_;
        pool = pool_;
        vault = factory_.vault();
        actors = [address(0xA11CE), address(0xB0B), address(0xCA401)];
        for (uint256 i; i < actors.length; ++i) {
            token.mint(actors[i], 1e32);
            vm.prank(actors[i]);
            token.approve(address(factory), type(uint256).max);
        }
    }

    function deposit(uint256 actorSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % 3];
        // Keep deposits well above rounding dust even after arbitrary yield additions.
        uint256 amount = 1e18 + amountSeed % 1e24;
        uint256 quote = vault.previewDeposit(amount);
        if (quote == 0) return;
        vm.prank(actor);
        (, uint256 shares) = factory.depositAndStake(amount, quote);
        expectedShares[actor] += shares;
        deposits++;
    }

    function withdraw(uint256 actorSeed, uint256 sharesSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 staked = expectedShares[actor];
        if (staked == 0) return;
        uint256 shares = 1 + sharesSeed % staked;
        PersonalStakingHelper helper = factory.helperOf(actor);
        uint256 beforeBalance = vault.balanceOf(actor);
        vm.prank(actor);
        helper.withdraw(shares);
        assertEq(vault.balanceOf(actor) - beforeBalance, shares);
        expectedShares[actor] -= shares;
        withdrawals++;
    }

    function redeem(uint256 actorSeed, uint256 sharesSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 staked = expectedShares[actor];
        if (staked == 0) return;
        uint256 shares = 1 + sharesSeed % staked;
        uint256 quote = vault.previewRedeem(shares);
        if (quote == 0) return;
        PersonalStakingHelper helper = factory.helperOf(actor);
        uint256 beforeBalance = token.balanceOf(actor);
        vm.prank(actor);
        helper.withdrawAndRedeem(shares, quote);
        assertEq(token.balanceOf(actor) - beforeBalance, quote);
        expectedShares[actor] -= shares;
        redemptions++;
    }

    function claim(uint256 actorSeed) external {
        address actor = actors[actorSeed % 3];
        PersonalStakingHelper helper = factory.helperOf(actor);
        if (address(helper) == address(0)) return;
        uint256 quote = pool.earned(address(helper));
        MockToken gov = MockToken(address(pool.rewardsToken()));
        uint256 beforeBalance = gov.balanceOf(actor);
        vm.prank(actor);
        helper.claim();
        assertEq(gov.balanceOf(actor) - beforeBalance, quote);
        claims++;
    }

    function accrue(uint256 elapsedSeed, uint256 interestSeed) external {
        vm.warp(block.timestamp + elapsedSeed % 3 days);
        if (vault.totalSupply() > 0) lender.addInterest(interestSeed % 1e20);
    }
}

contract PersonalStakingHelperInvariantTest is HelperFixture {
    HelperHandler internal handler;

    // Compatibility with current Foundry and the pinned older forge-std interface.
    function excludeSelectors() external pure returns (FuzzSelector[] memory) {
        return new FuzzSelector[](0);
    }

    function setUp() public override {
        super.setUp();
        handler = new HelperHandler(factory, token, lender, pool);
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
        uint256 total;
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            PersonalStakingHelper helper = factory.helperOf(actor);
            uint256 expected = handler.expectedShares(actor);
            if (address(helper) == address(0)) {
                assertEq(expected, 0);
                continue;
            }
            assertEq(helper.owner(), actor);
            assertEq(helper.stakedShares(), expected);
            assertClean(helper);
            total += expected;
        }
        assertEq(pool.totalSupply(), total);
        assertEq(vault.balanceOf(address(pool)), total);
    }
}
