// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Synthetix-style staking rewards.
/// @dev Reward accounting adapted from Synthetix StakingRewards:
/// GitHub: https://github.com/Synthetixio/synthetix/blob/develop/contracts/StakingRewards.sol
/// Verified deployment: https://etherscan.io/address/0x8302fe9f0c509a996573d3cc5b0d5d51e4fdd5ec
/// Original Synthetix snippets are included next to adapted methods; identical methods are marked.
/// @dev Staking and reward tokens must transfer exact amounts and maintain stable account balances.
/// Fee-on-transfer and rebasing tokens are unsupported.
contract StakingRewards is OwnableUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant REWARD_PRECISION = 1e18;

    IERC20 public stakingToken;
    IERC20 public rewardsToken;

    address public rewardsDistribution;

    uint256 private _totalSupply;
    mapping(address account => uint256) private _balances;

    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public rewardsDuration;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    mapping(address account => uint256) public userRewardPerTokenPaid;
    mapping(address account => uint256) public rewards;

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);

    constructor() {
        _disableInitializers();
    }

    function initialize(address stakingToken_, address rewardsToken_, address initialOwner, uint256 rewardsDuration_)
        external
        initializer
    {
        require(stakingToken_ != address(0), "Staking token cannot be 0");
        require(rewardsToken_ != address(0), "Rewards token cannot be 0");
        require(initialOwner != address(0), "Owner cannot be 0");
        require(rewardsDuration_ > 0, "Rewards duration cannot be 0");

        __Ownable_init(initialOwner);
        stakingToken = IERC20(stakingToken_);
        rewardsToken = IERC20(rewardsToken_);
        rewardsDistribution = initialOwner;
        rewardsDuration = rewardsDuration_;
    }

    modifier onlyRewardsDistribution() {
        require(msg.sender == rewardsDistribution, "Caller is not RewardsDistribution contract");
        _;
    }

    // Identical to Synthetix original.
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    // Identical to Synthetix original.
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    // Identical to Synthetix original.
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    // Identical to Synthetix original.
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    // Functionally identical to Synthetix original, using Solidity built-in safe math.
    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * REWARD_PRECISION)
            / _totalSupply;
    }

    // Functionally identical to Synthetix original, using Solidity built-in safe math.
    function earned(address account) public view returns (uint256) {
        return (_balances[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / REWARD_PRECISION
            + rewards[account];
    }

    // Functionally identical to Synthetix original, using Solidity built-in safe math.
    function getRewardForDuration() external view returns (uint256) {
        return rewardRate * rewardsDuration;
    }

    // Diff: No pause modifier. Otherwise functionally identical using solidity built-in safe math
    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        _totalSupply += amount;
        _balances[msg.sender] += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    // Functionally identical to Synthetix original, using Solidity built-in safe math.
    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot withdraw 0");
        _totalSupply -= amount;
        _balances[msg.sender] -= amount;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // Identical to Synthetix original.
    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    // Identical to Synthetix original.
    function exit() external {
        withdraw(_balances[msg.sender]);
        getReward();
    }

    // Functionally identical to Synthetix original, using Solidity built-in safe math.
    //
    // Rewards notified while `_totalSupply == 0` stream to nobody and are permanently locked, because `rewardPerToken()` does not accrue without stakers
    // This is accepted by design — the window between tranche funding and the first staker is expected to be short
    // Do not add queueing here without also gating StakingRewardsFunder as its tranche schedule relies on `periodFinish` advancing on notify
    function notifyRewardAmount(uint256 reward) external onlyRewardsDistribution updateReward(address(0)) {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward / rewardsDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / rewardsDuration;
        }

        uint256 balance = rewardsToken.balanceOf(address(this));
        require(rewardRate <= balance / rewardsDuration, "Provided reward too high");

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
        emit RewardAdded(reward);
    }

    // Identical to Synthetix RewardsDistributionRecipient original.
    function setRewardsDistribution(address _rewardsDistribution) external onlyOwner {
        rewardsDistribution = _rewardsDistribution;
    }

    // Synthetix's pause, recoverERC20, and mutable setRewardsDuration hooks are intentionally
    // omitted because the launch flow does not depend on them.
}
