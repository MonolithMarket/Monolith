// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Independent copy of CoinDAOFactory's Deployment layout and public array
/// getter at be1b426577d17edba960ce28363d39dde3acbcb4. The generated getter returns
/// fourteen addresses, unlike ICoinDAOFactory's struct-returning declaration.
contract CoinDAOFactoryRegistry {
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

    Deployment[] public deployments;

    function addDeployment(Deployment memory deployment) external returns (uint256 daoId) {
        daoId = deployments.length;
        deployments.push(deployment);
    }
}
