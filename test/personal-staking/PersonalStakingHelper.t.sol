// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    HelperFixture,
    MockToken,
    PersonalStakingHelper,
    PersonalStakingHelperFactory,
    IERC20,
    IERC4626,
    StakingRewards,
    IStakingRewards,
    Clones,
    TestMarket,
    ICoinDAOFactory,
    CoinDAOFactoryRegistry
} from "./HelperFixture.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract CallbackOwner {
    PersonalStakingHelper public helper;
    bool public success;
    bytes public result;

    function enter(MockToken token, PersonalStakingHelperFactory factory, uint256 daoId, uint256 amount) external {
        token.approve(address(factory), amount);
        (helper,) = factory.depositAndStake(daoId, amount, 1);
    }

    function claim() external {
        helper.claim();
    }

    function withdraw(uint256 shares, bool claimRewards) external {
        helper.withdraw(shares, claimRewards);
    }

    function withdrawAndRedeem(uint256 shares, uint256 minAssets, bool claimRewards) external {
        helper.withdrawAndRedeem(shares, minAssets, claimRewards);
    }

    function reenter() external {
        (success, result) = address(helper).call(abi.encodeCall(helper.claim, ()));
    }
}

contract PersonalStakingHelperTest is HelperFixture {
    function test_FirstDepositCreatesOwnedHelperAndBurnsMinimumShares() public {
        assertEq(address(factory.helperOf(daoId, alice)), address(0));
        (PersonalStakingHelper helper, uint256 shares) = deposit(alice, 100e18);
        assertEq(address(helper).code.length, 45);
        assertEq(address(factory.helperOf(daoId, alice)), address(helper));
        assertEq(helper.owner(), alice);
        assertEq(helper.factory(), address(factory));
        assertEq(address(helper.vault()), address(vault));
        assertEq(address(helper.stakingRewards()), address(pool));
        assertEq(address(helper.rewardToken()), address(gov));
        assertEq(shares, 100e18 - MIN_SHARES);
        assertEq(pool.balanceOf(address(helper)), shares);
        assertEq(helper.stakedShares(), shares);
        assertEq(vault.balanceOf(address(0)), MIN_SHARES);
        assertClean(helper);
    }

    function test_RepeatDepositReusesHelper() public {
        (PersonalStakingHelper helper, uint256 first) = deposit(alice, 100e18);
        (PersonalStakingHelper second, uint256 shares) = deposit(alice, 70e18);
        assertEq(address(second), address(helper));
        assertEq(pool.balanceOf(address(helper)), first + shares);
        assertEq(shares, 70e18);
        assertClean(helper);
    }

    function test_TwoUsersHaveIsolatedStakesAndClaims() public {
        (PersonalStakingHelper a, uint256 aShares) = deposit(alice, 100e18);
        (PersonalStakingHelper b, uint256 bShares) = deposit(bob, 200e18);
        assertNotEq(address(a), address(b));
        vm.warp(block.timestamp + 1 days);
        uint256 earnedA = pool.earned(address(a));
        uint256 earnedB = pool.earned(address(b));
        assertGt(earnedB, earnedA);
        vm.prank(alice);
        assertEq(a.claim(), earnedA);
        assertEq(gov.balanceOf(alice), earnedA);
        assertEq(gov.balanceOf(bob), 0);
        assertEq(pool.balanceOf(address(a)), aShares);
        assertEq(pool.balanceOf(address(b)), bShares);
        assertEq(pool.earned(address(b)), earnedB);
        vm.prank(bob);
        b.claim();
        assertEq(gov.balanceOf(bob), earnedB);
        assertClean(a);
        assertClean(b);
    }

    function test_StakedSharesKeepVaultYieldAndGovAccrual() public {
        (PersonalStakingHelper helper, uint256 shares) = deposit(alice, 100e18);
        lender.addInterest(20e18);
        vm.warp(block.timestamp + 1 days);
        uint256 quoted = vault.previewRedeem(shares);
        assertGt(quoted, 100e18);
        uint256 beforeBalance = token.balanceOf(alice);
        vm.prank(alice);
        uint256 redeemed = helper.withdrawAndRedeem(shares, quoted, false);
        assertEq(redeemed, quoted);
        assertEq(token.balanceOf(alice) - beforeBalance, quoted);
        assertEq(pool.balanceOf(address(helper)), 0);
        assertGt(pool.earned(address(helper)), 0);
        vm.prank(alice);
        helper.claim();
        assertGt(gov.balanceOf(alice), 0);
        assertClean(helper);
    }

    function test_WithdrawReturnsSharesAndKeepsGovClaimable() public {
        (PersonalStakingHelper helper, uint256 shares) = deposit(alice, 100e18);
        vm.warp(block.timestamp + 100);
        uint256 rewards = helper.earned();
        vm.prank(alice);
        helper.withdraw(shares / 2, false);
        assertEq(vault.balanceOf(alice), shares / 2);
        assertEq(helper.stakedShares(), shares - shares / 2);
        assertEq(helper.earned(), rewards);
        assertEq(gov.balanceOf(alice), 0);
        vm.prank(alice);
        helper.withdraw(shares - shares / 2, false);
        vm.prank(alice);
        helper.claim();
        assertEq(gov.balanceOf(alice), rewards);
        assertClean(helper);
    }

    function test_ClaimFailureDoesNotBlockEitherWithdrawalRoute() public {
        (PersonalStakingHelper helper, uint256 shares) = deposit(alice, 100e18);
        vm.warp(block.timestamp + 100);
        gov.setBlocked(true);
        vm.prank(alice);
        vm.expectRevert("TOKEN_BLOCKED");
        helper.claim();
        vm.prank(alice);
        helper.withdraw(shares / 2, false);
        vm.prank(alice);
        helper.withdrawAndRedeem(shares - shares / 2, 1, false);
        assertEq(helper.stakedShares(), 0);
        gov.setBlocked(false);
        vm.prank(alice);
        helper.claim();
        assertGt(gov.balanceOf(alice), 0);
        assertClean(helper);
    }

    function testFuzz_OptionalClaimAcrossWithdrawalRoutes(bool redeem, bool fullExit, bool claimRewards) public {
        (PersonalStakingHelper helper, uint256 shares) = deposit(alice, 100e18);
        (PersonalStakingHelper other, uint256 otherShares) = deposit(bob, 200e18);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 reward = helper.earned();
        uint256 otherReward = other.earned();
        assertGt(reward, 0);
        gov.mint(address(helper), 7e18);
        uint256 withdrawn = fullExit ? shares : shares / 2;
        uint256 quote = vault.previewRedeem(withdrawn);
        uint256 beforeTokens = token.balanceOf(alice);

        vm.prank(alice);
        if (redeem) {
            assertEq(helper.withdrawAndRedeem(withdrawn, quote, claimRewards), quote);
        } else {
            helper.withdraw(withdrawn, claimRewards);
        }

        assertEq(token.balanceOf(alice) - beforeTokens, redeem ? quote : 0);
        assertEq(vault.balanceOf(alice), redeem ? 0 : withdrawn);
        assertEq(helper.stakedShares(), shares - withdrawn);
        assertEq(gov.balanceOf(alice), claimRewards ? reward + 7e18 : 0);
        assertEq(gov.balanceOf(address(helper)), claimRewards ? 0 : 7e18);
        assertEq(helper.earned(), claimRewards ? 0 : reward);
        assertEq(other.stakedShares(), otherShares);
        assertEq(other.earned(), otherReward);
        assertEq(gov.balanceOf(bob), 0);
        assertClean(helper);

        // A partial exit keeps accruing; a full exit preserves only unpaid GOV.
        vm.warp(vm.getBlockTimestamp() + 1 days);
        if (fullExit) assertEq(helper.earned(), claimRewards ? 0 : reward);
        else assertGt(helper.earned(), claimRewards ? 0 : reward);
        uint256 stillOwed = helper.earned() + gov.balanceOf(address(helper));
        uint256 paid = gov.balanceOf(alice);
        vm.prank(alice);
        assertEq(helper.claim(), stillOwed);
        assertEq(gov.balanceOf(alice), paid + stillOwed);
        assertEq(helper.earned(), 0);
        assertEq(gov.balanceOf(address(helper)), 0);
    }

    function testFuzz_CombinedClaimFailureRollsBackAndPlainExitStillWorks(bool redeem, bool forwardingFails) public {
        (PersonalStakingHelper helper, uint256 shares) = deposit(alice, 100e18);
        vm.warp(vm.getBlockTimestamp() + 100);
        uint256 reward = helper.earned();
        uint256 checkpoint = pool.userRewardPerTokenPaid(address(helper));
        uint256 quote = vault.previewRedeem(shares);
        uint256 beforeTokens = token.balanceOf(alice);
        uint256 beforeVaultTokens = token.balanceOf(address(vault));
        uint256 beforeSupply = vault.totalSupply();
        uint256 beforePoolGov = gov.balanceOf(address(pool));
        if (forwardingFails) {
            // Let pool -> helper succeed, then fail helper -> owner forwarding.
            gov.setHook(address(pool), address(gov), abi.encodeCall(gov.setBlocked, (true)));
        } else {
            gov.setBlocked(true);
        }

        vm.prank(alice);
        vm.expectRevert("TOKEN_BLOCKED");
        if (redeem) helper.withdrawAndRedeem(shares, quote, true);
        else helper.withdraw(shares, true);

        assertEq(helper.stakedShares(), shares);
        assertEq(pool.totalSupply(), shares);
        assertEq(pool.userRewardPerTokenPaid(address(helper)), checkpoint);
        assertEq(helper.earned(), reward);
        assertEq(token.balanceOf(alice), beforeTokens);
        assertEq(token.balanceOf(address(vault)), beforeVaultTokens);
        assertEq(vault.totalSupply(), beforeSupply);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(gov.balanceOf(alice), 0);
        assertEq(gov.balanceOf(address(helper)), 0);
        assertEq(gov.balanceOf(address(pool)), beforePoolGov);
        assertClean(helper);

        // Retry while the failing GOV behaviour is still configured.
        vm.prank(alice);
        if (redeem) helper.withdrawAndRedeem(shares, quote, false);
        else helper.withdraw(shares, false);
        assertEq(helper.stakedShares(), 0);
        assertEq(token.balanceOf(alice) - beforeTokens, redeem ? quote : 0);
        assertEq(vault.balanceOf(alice), redeem ? 0 : shares);
        assertEq(helper.earned(), reward);
        assertEq(gov.balanceOf(address(pool)), beforePoolGov);
        gov.setHook(address(0), address(0), "");
        gov.setBlocked(false);
        vm.prank(alice);
        assertEq(helper.claim(), reward);
        assertEq(gov.balanceOf(alice), reward);
    }

    function testFuzz_CombinedWithdrawalRejectsOwnerCallbackReentrancy(bool redeem) public {
        CallbackOwner receiver = new CallbackOwner();
        token.mint(address(receiver), 100e18);
        receiver.enter(token, factory, daoId, 100e18);
        PersonalStakingHelper helper = receiver.helper();
        uint256 shares = helper.stakedShares();
        uint256 quote = vault.previewRedeem(shares);
        vm.warp(vm.getBlockTimestamp() + 100);
        uint256 reward = helper.earned();
        gov.setHook(address(helper), address(receiver), abi.encodeCall(receiver.reenter, ()));
        if (redeem) receiver.withdrawAndRedeem(shares, quote, true);
        else receiver.withdraw(shares, true);
        assertFalse(receiver.success());
        assertEq(receiver.result(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(gov.balanceOf(address(receiver)), reward);
        assertEq(token.balanceOf(address(receiver)), redeem ? quote : 0);
        assertEq(vault.balanceOf(address(receiver)), redeem ? 0 : shares);
        assertEq(helper.stakedShares(), 0);
        assertEq(helper.earned(), 0);
        assertClean(helper);
    }

    function testFuzz_CombinedExitWithNoGovRewardsSucceeds(bool redeem) public {
        (PersonalStakingHelper helper, uint256 shares) = deposit(alice, 100e18);
        assertEq(helper.earned(), 0);
        gov.setBlocked(true);
        uint256 quote = vault.previewRedeem(shares);
        vm.prank(alice);
        if (redeem) helper.withdrawAndRedeem(shares, quote, true);
        else helper.withdraw(shares, true);
        assertEq(helper.stakedShares(), 0);
        assertEq(gov.balanceOf(alice), 0);
        assertClean(helper);
    }

    function testFuzz_OptionalClaimOnlyOwner(bool redeem, bool claimRewards) public {
        (PersonalStakingHelper helper, uint256 shares) = deposit(alice, 100e18);
        vm.warp(vm.getBlockTimestamp() + 100);
        uint256 reward = helper.earned();
        uint256 quote = vault.previewRedeem(shares);
        vm.prank(bob);
        vm.expectRevert(PersonalStakingHelper.OnlyOwner.selector);
        if (redeem) helper.withdrawAndRedeem(shares, quote, claimRewards);
        else helper.withdraw(shares, claimRewards);
        assertEq(helper.stakedShares(), shares);
        assertEq(helper.earned(), reward);
        assertEq(gov.balanceOf(bob), 0);
    }

    function test_FirstDepositSlippageRollsBackCloneTransferAllowanceAndVault() public {
        uint256 beforeBalance = token.balanceOf(alice);
        uint256 allowanceBefore = token.allowance(alice, address(factory));
        uint64 nonceBefore = vm.getNonce(address(factory));
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PersonalStakingHelper.InsufficientShares.selector, 100e18 - MIN_SHARES, 100e18)
        );
        factory.depositAndStake(daoId, 100e18, 100e18);
        assertEq(address(factory.helperOf(daoId, alice)), address(0));
        assertEq(vm.getNonce(address(factory)), nonceBefore);
        assertEq(token.balanceOf(alice), beforeBalance);
        assertEq(token.allowance(alice, address(factory)), allowanceBefore);
        assertEq(vault.totalSupply(), 0);
        assertEq(pool.totalSupply(), 0);
    }

    function test_ExistingHelperDepositSlippageRollsBack() public {
        (PersonalStakingHelper helper, uint256 shares) = deposit(alice, 100e18);
        uint256 beforeBalance = token.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PersonalStakingHelper.InsufficientShares.selector, 1e18, 2e18));
        factory.depositAndStake(daoId, 1e18, 2e18);
        assertEq(token.balanceOf(alice), beforeBalance);
        assertEq(helper.stakedShares(), shares);
        assertClean(helper);
    }

    function testFuzz_RedeemSlippageRollsBackStakeTokensAndRewardCheckpoint(bool claimRewards) public {
        (PersonalStakingHelper helper, uint256 shares) = deposit(alice, 100e18);
        vm.warp(block.timestamp + 100);
        uint256 quoted = vault.previewRedeem(shares);
        uint256 beforeBalance = token.balanceOf(alice);
        uint256 paid = pool.userRewardPerTokenPaid(address(helper));
        gov.setBlocked(true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PersonalStakingHelper.InsufficientAssets.selector, quoted, quoted + 1));
        helper.withdrawAndRedeem(shares, quoted + 1, claimRewards);
        assertEq(helper.stakedShares(), shares);
        assertEq(token.balanceOf(alice), beforeBalance);
        assertEq(pool.userRewardPerTokenPaid(address(helper)), paid);
        assertClean(helper);
    }

    function test_ZeroAmounts() public {
        vm.prank(alice);
        vm.expectRevert(PersonalStakingHelperFactory.ZeroAmount.selector);
        factory.depositAndStake(daoId, 0, 0);
        (PersonalStakingHelper helper,) = deposit(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(PersonalStakingHelper.ZeroAmount.selector);
        helper.withdraw(0, false);
        vm.prank(alice);
        vm.expectRevert(PersonalStakingHelper.ZeroAmount.selector);
        helper.withdrawAndRedeem(0, 0, false);
    }

    function test_FirstDepositExactlyMinimumSharesRevertsWithoutLoss() public {
        uint256 beforeBalance = token.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PersonalStakingHelper.InsufficientShares.selector, 0, 0));
        factory.depositAndStake(daoId, MIN_SHARES, 0);
        assertEq(token.balanceOf(alice), beforeBalance);
        assertEq(address(factory.helperOf(daoId, alice)), address(0));
        assertEq(vault.totalSupply(), 0);
    }

    function test_StakingFailureRollsBackVaultDepositAndHelperCreation() public {
        uint64 nonceBefore = vm.getNonce(address(factory));
        uint256 beforeBalance = token.balanceOf(alice);
        vm.mockCallRevert(
            address(pool),
            abi.encodeWithSelector(pool.stake.selector),
            abi.encodeWithSignature("Error(string)", "STAKE_FAILED")
        );
        vm.prank(alice);
        vm.expectRevert("STAKE_FAILED");
        factory.depositAndStake(daoId, 100e18, 1);
        assertEq(address(factory.helperOf(daoId, alice)), address(0));
        assertEq(vm.getNonce(address(factory)), nonceBefore);
        assertEq(token.balanceOf(alice), beforeBalance);
        assertEq(vault.totalSupply(), 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(pool.totalSupply(), 0);
    }

    function test_FirstDepositBelowMinimumRevertsWithoutLoss() public {
        uint256 beforeBalance = token.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        factory.depositAndStake(daoId, MIN_SHARES - 1, 0);
        assertEq(token.balanceOf(alice), beforeBalance);
        assertEq(vault.totalSupply(), 0);
    }

    function test_LooseTokensCannotBeSweptByAnotherUserOrStakedAccidentally() public {
        (PersonalStakingHelper helper, uint256 firstShares) = deposit(alice, 100e18);
        token.mint(address(helper), 7e18);
        token.mint(address(this), 10e18);
        token.approve(address(vault), 10e18);
        uint256 donatedShares = vault.deposit(10e18, address(helper));
        (PersonalStakingHelper again, uint256 shares) = deposit(alice, 100e18);
        assertEq(address(again), address(helper));
        assertEq(shares, 100e18);
        assertEq(token.balanceOf(address(helper)), 7e18);
        assertEq(vault.balanceOf(address(helper)), donatedShares);
        assertEq(helper.stakedShares(), firstShares + shares);
        vm.prank(bob);
        vm.expectRevert(PersonalStakingHelper.OnlyOwner.selector);
        helper.recoverToken(token);
        uint256 beforeBalance = token.balanceOf(alice);
        vm.prank(alice);
        helper.recoverToken(token);
        assertEq(token.balanceOf(alice) - beforeBalance, 7e18);
        vm.prank(alice);
        helper.recoverToken(IERC20(address(vault)));
        assertEq(vault.balanceOf(alice), donatedShares);
        assertEq(helper.stakedShares(), firstShares + shares);
        assertClean(helper);
    }

    function test_OnlyOwnerCanClaimWithdrawRedeemOrRecover() public {
        (PersonalStakingHelper helper,) = deposit(alice, 100e18);
        vm.startPrank(bob);
        vm.expectRevert(PersonalStakingHelper.OnlyOwner.selector);
        helper.claim();
        vm.expectRevert(PersonalStakingHelper.OnlyOwner.selector);
        helper.withdraw(1, false);
        vm.expectRevert(PersonalStakingHelper.OnlyOwner.selector);
        helper.withdrawAndRedeem(1, 0, false);
        vm.expectRevert(PersonalStakingHelper.OnlyOwner.selector);
        helper.recoverToken(token);
        vm.stopPrank();
        vm.prank(address(factory));
        vm.expectRevert(PersonalStakingHelper.OnlyOwner.selector);
        helper.withdraw(1, false);
    }

    function test_OnlyFactoryCanDepositOrInitializeAndInitializationIsOneTime() public {
        (PersonalStakingHelper helper,) = deposit(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(PersonalStakingHelper.OnlyFactory.selector);
        helper.depositAndStake(1, 0);
        vm.prank(bob);
        vm.expectRevert(PersonalStakingHelper.OnlyFactory.selector);
        helper.initialize(bob, vault, IStakingRewards(address(pool)));
        vm.prank(address(factory));
        vm.expectRevert(PersonalStakingHelper.AlreadyInitialized.selector);
        helper.initialize(bob, vault, IStakingRewards(address(pool)));
        PersonalStakingHelper implementation = factory.implementation();
        vm.prank(address(factory));
        vm.expectRevert(PersonalStakingHelper.AlreadyInitialized.selector);
        implementation.initialize(alice, vault, IStakingRewards(address(pool)));
    }

    function test_InsufficientApprovalOrBalanceRevertsCloneCreation() public {
        vm.prank(alice);
        token.approve(address(factory), 0);
        vm.prank(alice);
        vm.expectRevert();
        factory.depositAndStake(daoId, 1e18, 1);
        assertEq(address(factory.helperOf(daoId, alice)), address(0));
        vm.prank(alice);
        token.approve(address(factory), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert();
        factory.depositAndStake(daoId, 1e30 + 1, 1);
        assertEq(address(factory.helperOf(daoId, alice)), address(0));
    }

    function test_InvalidCoinDAOFactoryRejected() public {
        vm.expectRevert(PersonalStakingHelperFactory.InvalidFactory.selector);
        new PersonalStakingHelperFactory(ICoinDAOFactory(address(0)));
        vm.expectRevert(PersonalStakingHelperFactory.InvalidFactory.selector);
        new PersonalStakingHelperFactory(ICoinDAOFactory(alice));
    }

    function test_FactoryRejectsTokenCallbackReentrancy() public {
        token.setHook(alice, address(factory), abi.encodeCall(factory.depositAndStake, (daoId, 1e18, 0)));
        (PersonalStakingHelper helper,) = deposit(alice, 100e18);
        assertFalse(token.callbackSuccess());
        assertEq(token.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertClean(helper);
    }

    function test_HelperRejectsAuthorizedOwnerCallbackReentrancy() public {
        CallbackOwner receiver = new CallbackOwner();
        token.mint(address(receiver), 100e18);
        receiver.enter(token, factory, daoId, 100e18);
        PersonalStakingHelper helper = receiver.helper();
        vm.warp(block.timestamp + 100);
        gov.setHook(address(helper), address(receiver), abi.encodeCall(receiver.reenter, ()));
        uint256 reward = helper.earned();
        receiver.claim();
        assertFalse(receiver.success());
        assertEq(receiver.result(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(gov.balanceOf(address(receiver)), reward);
        assertEq(helper.earned(), 0);
    }

    function test_DepositAfterVaultYieldUsesActualExchangeRate() public {
        deposit(alice, 100e18);
        lender.addInterest(50e18);
        uint256 quote = vault.previewDeposit(100e18);
        (, uint256 minted) = deposit(bob, 100e18);
        assertEq(minted, quote);
        assertLt(minted, 100e18);
    }

    function test_WithdrawBeyondOwnStakeCannotConsumeOtherUserStake() public {
        (PersonalStakingHelper a, uint256 shares) = deposit(alice, 100e18);
        (PersonalStakingHelper b, uint256 bobShares) = deposit(bob, 200e18);
        vm.prank(alice);
        vm.expectRevert();
        a.withdraw(shares + 1, false);
        assertEq(a.stakedShares(), shares);
        assertEq(b.stakedShares(), bobShares);
        assertClean(a);
        assertClean(b);
    }

    function test_DepositAfterFullExitAndEmptyClaim() public {
        (PersonalStakingHelper helper, uint256 shares) = deposit(alice, 100e18);
        vm.prank(alice);
        assertEq(helper.claim(), 0);
        vm.prank(alice);
        helper.withdrawAndRedeem(shares, 1, false);
        (PersonalStakingHelper again, uint256 newShares) = deposit(alice, 20e18);
        assertEq(address(helper), address(again));
        assertEq(again.stakedShares(), newShares);
        assertClean(helper);
    }

    function test_DirectGovDonationBelongsOnlyToHelperOwner() public {
        (PersonalStakingHelper helper,) = deposit(alice, 100e18);
        gov.mint(address(helper), 7e18);
        vm.prank(alice);
        assertEq(helper.claim(), 7e18);
        assertEq(gov.balanceOf(alice), 7e18);
    }

    function testFuzz_DepositRedeemRoundTrip(uint96 rawAmount, uint96 rawYield) public {
        uint256 amount = bound(uint256(rawAmount), MIN_SHARES + 1, 1e26);
        uint256 yield = bound(uint256(rawYield), 0, amount / 2);
        (PersonalStakingHelper helper, uint256 shares) = deposit(alice, amount);
        lender.addInterest(yield);
        uint256 quote = vault.previewRedeem(shares);
        uint256 beforeBalance = token.balanceOf(alice);
        vm.prank(alice);
        helper.withdrawAndRedeem(shares, quote, false);
        assertEq(token.balanceOf(alice) - beforeBalance, quote);
        assertEq(pool.totalSupply(), 0);
        assertClean(helper);
    }
}
