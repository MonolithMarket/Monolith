// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStakingRewards} from "./interfaces/IStakingRewards.sol";
import {PersonalStakingHelper} from "./PersonalStakingHelper.sol";

/// @notice Token -> sToken -> existing GOV rewards, with one isolated helper per user.
/// @dev Deploy one factory per trusted vault/rewards pair. No admin or upgrade path.
contract PersonalStakingHelperFactory is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC4626 public immutable vault;
    IStakingRewards public immutable stakingRewards;
    IERC20 public immutable asset;
    PersonalStakingHelper public immutable implementation;
    mapping(address owner => PersonalStakingHelper helper) public helperOf;

    error InvalidPair();
    error ZeroAmount();
    error DeadlineExpired();
    error UnsupportedAssetTransfer();

    event HelperCreated(address indexed owner, address indexed helper);
    event DepositedAndStaked(address indexed owner, address indexed helper, uint256 assets, uint256 shares);

    constructor(IERC4626 vault_, IStakingRewards stakingRewards_) {
        if (address(vault_).code.length == 0 || address(stakingRewards_).code.length == 0) revert InvalidPair();
        if (stakingRewards_.stakingToken() != address(vault_)) revert InvalidPair();
        address underlying = vault_.asset();
        address gov = stakingRewards_.rewardsToken();
        if (
            underlying.code.length == 0 || gov.code.length == 0 || underlying == address(vault_) || gov == underlying
                || gov == address(vault_)
        ) revert InvalidPair();
        vault = vault_;
        stakingRewards = stakingRewards_;
        asset = IERC20(underlying);
        implementation = new PersonalStakingHelper(vault_, stakingRewards_);
    }

    /// @notice Approve this factory for Token, then deposit for your own address.
    /// @dev No arbitrary payer/beneficiary arguments: allowances cannot fund somebody else's position.
    function depositAndStake(uint256 assets, uint256 minShares, uint256 deadline)
        external
        nonReentrant
        returns (PersonalStakingHelper helper, uint256 shares)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (assets == 0) revert ZeroAmount();

        helper = helperOf[msg.sender];
        if (address(helper) == address(0)) {
            helper = PersonalStakingHelper(
                Clones.cloneDeterministic(address(implementation), bytes32(uint256(uint160(msg.sender))))
            );
            helper.initialize(msg.sender);
            helperOf[msg.sender] = helper;
            emit HelperCreated(msg.sender, address(helper));
        }

        uint256 beforeBalance = asset.balanceOf(address(helper));
        asset.safeTransferFrom(msg.sender, address(helper), assets);
        if (asset.balanceOf(address(helper)) != beforeBalance + assets) revert UnsupportedAssetTransfer();
        shares = helper.depositAndStake(assets, minShares);
        emit DepositedAndStaked(msg.sender, address(helper), assets, shares);
    }

    function predictHelper(address owner) external view returns (address) {
        return
            Clones.predictDeterministicAddress(address(implementation), bytes32(uint256(uint160(owner))), address(this));
    }
}
