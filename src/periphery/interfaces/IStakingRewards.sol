// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Interface of the existing, caller-accounted Monolith rewards pool.
interface IStakingRewards {
    function stakingToken() external view returns (address);
    function rewardsToken() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function earned(address account) external view returns (uint256);
    function stake(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function getReward() external;
}
