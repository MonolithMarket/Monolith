// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice CoinDAOFactory v2 deployment registry.
/// @dev This static struct has the same ABI encoding as the fourteen address
///      return values of the factory's public deployments(uint256) getter.
interface ICoinDAOFactory {
    struct Deployment {
        address govToken;
        address staker;
        address governor;
        address timelock;
        address lender;
        address coin;
        address vault;
        address stakingToken;
        address revenueRouter;
        address coinStakingRewards;
        address coinStakingRewardsFunder;
        address treasuryVesting;
        address monolithVesting;
        address deployerVesting;
    }

    function deployments(uint256 daoId) external view returns (Deployment memory);
}
