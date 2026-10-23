// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    HelperFixture,
    TestMarket,
    PersonalStakingHelper,
    PersonalStakingHelperFactory,
    ICoinDAOFactory,
    IStakingRewards,
    CoinDAOFactoryRegistry
} from "./HelperFixture.sol";

contract GeneralizedStakingHelperTest is HelperFixture {
    function test_PublicRegistryGetterDecodesDeploymentFields() public {
        CoinDAOFactoryRegistry.Deployment memory expected = CoinDAOFactoryRegistry.Deployment({
            govToken: address(0x101),
            staker: address(0x102),
            governor: address(0x103),
            timelock: address(0x104),
            lender: address(0x105),
            coin: address(0x106),
            vault: address(0x107),
            stakingToken: address(0x108),
            revenueRouter: address(0x109),
            coinStakingRewards: address(0x10a),
            coinStakingRewardsFunder: address(0x10b),
            treasuryVesting: address(0x10c),
            monolithVesting: address(0x10d),
            deployerVesting: address(0x10e)
        });
        uint256 id = coinDAOFactory.addDeployment(expected);
        ICoinDAOFactory.Deployment memory actual = factory.coinDAOFactory().deployments(id);
        assertEq(abi.encode(actual), abi.encode(expected));
        assertEq(actual.govToken, expected.govToken);
        assertEq(actual.coin, expected.coin);
        assertEq(actual.vault, expected.vault);
        assertEq(actual.stakingToken, expected.stakingToken);
        assertEq(actual.coinStakingRewards, expected.coinStakingRewards);
    }

    function test_NewDAOUsesTheExistingFactoryAndImplementation() public {
        address implementation = address(factory.implementation());
        (uint256 id, TestMarket memory second) = createDAO("SecondToken", true);
        fundAndApprove(second, alice, 1e30);
        (PersonalStakingHelper helper, uint256 shares) = depositIn(id, second, alice, 100e18);
        assertEq(address(factory.coinDAOFactory()), address(coinDAOFactory));
        assertEq(address(factory.implementation()), implementation);
        assertEq(address(factory.helperOf(id, alice)), address(helper));
        assertEq(address(factory.helperOf(daoId, alice)), address(0));
        assertEq(helper.owner(), alice);
        assertEq(helper.factory(), address(factory));
        assertEq(address(helper.asset()), address(second.token));
        assertEq(address(helper.vault()), address(second.vault));
        assertEq(address(helper.stakingRewards()), address(second.pool));
        assertEq(address(helper.rewardToken()), address(second.gov));
        assertEq(shares, 100e18 - MIN_SHARES);
        (PersonalStakingHelper again, uint256 added) = depositIn(id, second, alice, 10e18);
        assertEq(address(again), address(helper));
        assertEq(helper.stakedShares(), shares + added);
        assertClean(helper);
    }

    function test_OneOwnerHasIsolatedStakesRewardsAndExitsAcrossDAOs() public {
        (PersonalStakingHelper a, uint256 aShares) = deposit(alice, 100e18);
        (uint256 id, TestMarket memory second) = createDAO("SecondToken", true);
        fundAndApprove(second, alice, 1e30);
        (PersonalStakingHelper b, uint256 bShares) = depositIn(id, second, alice, 200e18);
        assertNotEq(address(a), address(b));
        lender.addInterest(20e18);
        second.lender.addInterest(30e18);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 earnedA = a.earned();
        uint256 earnedB = b.earned();
        assertGt(earnedA, 0);
        assertGt(earnedB, 0);
        vm.prank(alice);
        a.claim();
        assertEq(gov.balanceOf(alice), earnedA);
        assertEq(second.gov.balanceOf(alice), 0);
        assertEq(b.earned(), earnedB);
        vm.prank(alice);
        b.claim();
        assertEq(second.gov.balanceOf(alice), earnedB);
        assertEq(gov.balanceOf(alice), earnedA);
        uint256 secondBalance = second.token.balanceOf(alice);
        uint256 quote = vault.previewRedeem(aShares);
        vm.prank(alice);
        assertEq(a.withdrawAndRedeem(aShares, quote, false), quote);
        assertEq(a.stakedShares(), 0);
        assertEq(b.stakedShares(), bShares);
        assertEq(second.token.balanceOf(alice), secondBalance);
        vm.prank(alice);
        b.withdraw(bShares, false);
        assertEq(second.vault.balanceOf(alice), bShares);
        assertEq(b.stakedShares(), 0);
        assertClean(a);
        assertClean(b);
    }

    function test_EachDAORequiresApprovalForItsOwnToken() public {
        (uint256 id, TestMarket memory second) = createDAO("SecondToken", true);
        second.token.mint(alice, 100e18);
        uint256 firstBalance = token.balanceOf(alice);
        uint256 firstAllowance = token.allowance(alice, address(factory));
        vm.prank(alice);
        vm.expectRevert();
        factory.depositAndStake(id, 100e18, 1);
        assertEq(address(factory.helperOf(id, alice)), address(0));
        assertEq(token.balanceOf(alice), firstBalance);
        assertEq(token.allowance(alice, address(factory)), firstAllowance);
        assertEq(second.token.balanceOf(alice), 100e18);
        vm.prank(alice);
        second.token.approve(address(factory), 100e18);
        (PersonalStakingHelper helper,) = depositIn(id, second, alice, 100e18);
        assertEq(second.token.balanceOf(alice), 0);
        assertEq(token.balanceOf(alice), firstBalance);
        assertClean(helper);
    }

    function test_TokenStakingDAORejectedBeforeCloneCreationOrFunding() public {
        (uint256 id, TestMarket memory direct) = createDAO("DirectToken", false);
        fundAndApprove(direct, alice, 100e18);
        uint64 nonceBefore = vm.getNonce(address(factory));
        vm.prank(alice);
        vm.expectRevert(PersonalStakingHelperFactory.InvalidPair.selector);
        factory.depositAndStake(id, 100e18, 1);
        assertEq(address(factory.helperOf(id, alice)), address(0));
        assertEq(vm.getNonce(address(factory)), nonceBefore);
        assertEq(direct.token.balanceOf(alice), 100e18);
        assertEq(direct.token.balanceOf(address(factory)), 0);
        assertEq(direct.pool.totalSupply(), 0);
    }

    function test_UnknownDAORevertsWithoutSpendingAnotherDAOTokens() public {
        uint256 balanceBefore = token.balanceOf(alice);
        uint64 nonceBefore = vm.getNonce(address(factory));
        vm.prank(alice);
        vm.expectRevert();
        factory.depositAndStake(type(uint256).max, 100e18, 1);
        assertEq(token.balanceOf(alice), balanceBefore);
        assertEq(address(factory.helperOf(type(uint256).max, alice)), address(0));
        assertEq(vm.getNonce(address(factory)), nonceBefore);
    }

    function test_ZeroVaultRecordRejected() public {
        CoinDAOFactoryRegistry.Deployment memory empty;
        uint256 id = coinDAOFactory.addDeployment(empty);
        vm.prank(alice);
        vm.expectRevert(PersonalStakingHelperFactory.InvalidPair.selector);
        factory.depositAndStake(id, 100e18, 1);
        assertEq(address(factory.helperOf(id, alice)), address(0));
    }

    function test_HelperCannotBeReboundToAnotherDAO() public {
        (PersonalStakingHelper helper, uint256 shares) = deposit(alice, 100e18);
        (, TestMarket memory second) = createDAO("SecondToken", true);
        vm.prank(address(factory));
        vm.expectRevert(PersonalStakingHelper.AlreadyInitialized.selector);
        helper.initialize(alice, second.vault, IStakingRewards(address(second.pool)));
        assertEq(helper.owner(), alice);
        assertEq(address(helper.asset()), address(token));
        assertEq(address(helper.vault()), address(vault));
        assertEq(address(helper.stakingRewards()), address(pool));
        assertEq(address(helper.rewardToken()), address(gov));
        assertEq(helper.stakedShares(), shares);
    }

    function test_FailedSecondDAODepositLeavesFirstDAOPositionUntouched() public {
        (PersonalStakingHelper first, uint256 shares) = deposit(alice, 100e18);
        (uint256 id, TestMarket memory second) = createDAO("SecondToken", true);
        fundAndApprove(second, alice, 100e18);
        vm.prank(alice);
        second.token.approve(address(factory), 100e18);
        uint64 nonceBefore = vm.getNonce(address(factory));
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PersonalStakingHelper.InsufficientShares.selector, 100e18 - MIN_SHARES, 100e18)
        );
        factory.depositAndStake(id, 100e18, 100e18);
        assertEq(address(factory.helperOf(id, alice)), address(0));
        assertEq(vm.getNonce(address(factory)), nonceBefore);
        assertEq(second.token.balanceOf(alice), 100e18);
        assertEq(second.token.allowance(alice, address(factory)), 100e18);
        assertEq(second.vault.totalSupply(), 0);
        assertEq(second.pool.totalSupply(), 0);
        assertEq(address(factory.helperOf(daoId, alice)), address(first));
        assertEq(first.stakedShares(), shares);
        assertClean(first);
    }
}
