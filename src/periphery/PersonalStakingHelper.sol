// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStakingRewards} from "./interfaces/IStakingRewards.sol";

/// @notice One owner's position in a fixed Monolith vault and existing rewards pool.
/// @dev The factory uses immutable EIP-1167 clones. The implementation's immutable
///      addresses are shared by every clone; each clone has its own owner/storage.
contract PersonalStakingHelper is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable factory;
    IERC4626 public immutable vault;
    IStakingRewards public immutable stakingRewards;
    IERC20 public immutable asset;
    IERC20 public immutable rewardToken;
    address public owner;

    error OnlyFactory();
    error OnlyOwner();
    error AlreadyInitialized();
    error ZeroAddress();
    error ZeroAmount();
    error DeadlineExpired();
    error InsufficientShares(uint256 received, uint256 minimum);
    error InsufficientAssets(uint256 received, uint256 minimum);
    error UnexpectedBalanceChange();

    event DepositedAndStaked(uint256 assets, uint256 shares);
    event Withdrawn(uint256 shares);
    event WithdrawnAndRedeemed(uint256 shares, uint256 assets);
    event RewardClaimed(uint256 amount);
    event TokenRecovered(address indexed token, uint256 amount);

    /// @dev Called only by the factory's constructor. Locks the implementation.
    constructor(IERC4626 vault_, IStakingRewards stakingRewards_) {
        factory = msg.sender;
        vault = vault_;
        stakingRewards = stakingRewards_;
        asset = IERC20(vault_.asset());
        rewardToken = IERC20(stakingRewards_.rewardsToken());
        owner = address(this);
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    /// @dev The factory creates and initializes each clone in the same call.
    function initialize(address owner_) external onlyFactory {
        if (owner != address(0)) revert AlreadyInitialized();
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
    }

    /// @notice Deposits exactly the assets just supplied by the factory.
    /// @dev Existing/donated balances are excluded. There is no shared accounting.
    function depositAndStake(uint256 assets, uint256 minShares)
        external
        onlyFactory
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();
        uint256 assetsBefore = asset.balanceOf(address(this));
        uint256 sharesBefore = vault.balanceOf(address(this));
        uint256 stakedBefore = stakingRewards.balanceOf(address(this));

        asset.forceApprove(address(vault), assets);
        shares = vault.deposit(assets, address(this));
        asset.forceApprove(address(vault), 0);

        // Includes Monolith's first-deposit MIN_SHARES deduction.
        if (shares == 0 || shares < minShares) revert InsufficientShares(shares, minShares);
        if (
            asset.balanceOf(address(this)) != assetsBefore - assets
                || vault.balanceOf(address(this)) != sharesBefore + shares
        ) revert UnexpectedBalanceChange();

        IERC20(address(vault)).forceApprove(address(stakingRewards), shares);
        stakingRewards.stake(shares);
        IERC20(address(vault)).forceApprove(address(stakingRewards), 0);

        if (
            vault.balanceOf(address(this)) != sharesBefore
                || stakingRewards.balanceOf(address(this)) != stakedBefore + shares
        ) revert UnexpectedBalanceChange();
        emit DepositedAndStaked(assets, shares);
    }

    /// @notice Claims GOV to the fixed owner, including any GOV sent here directly.
    function claim() external onlyOwner nonReentrant returns (uint256 amount) {
        stakingRewards.getReward();
        amount = rewardToken.balanceOf(address(this));
        if (amount != 0) rewardToken.safeTransfer(owner, amount);
        emit RewardClaimed(amount);
    }

    /// @notice Unstakes sToken to the owner without requiring a successful GOV claim.
    function withdraw(uint256 shares) external onlyOwner nonReentrant {
        if (shares == 0) revert ZeroAmount();
        stakingRewards.withdraw(shares);
        IERC20(address(vault)).safeTransfer(owner, shares);
        emit Withdrawn(shares);
    }

    /// @notice Unstakes and redeems to Token for the owner; GOV stays claimable.
    function withdrawAndRedeem(uint256 shares, uint256 minAssets, uint256 deadline)
        external
        onlyOwner
        nonReentrant
        returns (uint256 assets)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (shares == 0) revert ZeroAmount();
        stakingRewards.withdraw(shares);
        assets = vault.redeem(shares, owner, address(this));
        if (assets < minAssets) revert InsufficientAssets(assets, minAssets);
        emit WithdrawnAndRedeemed(shares, assets);
    }

    /// @notice Recovers loose tokens to the owner. Cannot withdraw the staked position.
    function recoverToken(IERC20 token) external onlyOwner nonReentrant returns (uint256 amount) {
        amount = token.balanceOf(address(this));
        if (amount != 0) token.safeTransfer(owner, amount);
        emit TokenRecovered(address(token), amount);
    }

    function stakedShares() external view returns (uint256) {
        return stakingRewards.balanceOf(address(this));
    }

    function earned() external view returns (uint256) {
        return stakingRewards.earned(address(this));
    }
}
