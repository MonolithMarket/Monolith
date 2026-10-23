// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStakingRewards} from "./interfaces/IStakingRewards.sol";
import {ICoinDAOFactory} from "./interfaces/ICoinDAOFactory.sol";
import {PersonalStakingHelper} from "./PersonalStakingHelper.sol";

/// @notice Token -> sToken -> GOV rewards, with one helper per owner and CoinDAO.
/// @dev One fixed, trusted CoinDAOFactory registry. No admin or upgrade path.
contract PersonalStakingHelperFactory is ReentrancyGuard {
    using SafeERC20 for IERC20;

    ICoinDAOFactory public immutable coinDAOFactory;
    PersonalStakingHelper public immutable implementation;
    mapping(uint256 daoId => mapping(address owner => PersonalStakingHelper helper)) public helperOf;

    error InvalidFactory();
    error InvalidPair();
    error ZeroAmount();

    event HelperCreated(uint256 indexed daoId, address indexed owner, address indexed helper);
    event DepositedAndStaked(
        uint256 indexed daoId, address indexed owner, address indexed helper, uint256 assets, uint256 shares
    );

    constructor(ICoinDAOFactory coinDAOFactory_) {
        if (address(coinDAOFactory_).code.length == 0) revert InvalidFactory();
        coinDAOFactory = coinDAOFactory_;
        implementation = new PersonalStakingHelper();
    }

    /// @notice Approve this factory for Token, then deposit for your own address.
    /// @dev No arbitrary payer/beneficiary arguments: allowances cannot fund somebody else's position.
    function depositAndStake(uint256 daoId, uint256 assets, uint256 minShares)
        external
        nonReentrant
        returns (PersonalStakingHelper helper, uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();

        helper = helperOf[daoId][msg.sender];
        if (address(helper) == address(0)) {
            ICoinDAOFactory.Deployment memory deployment = coinDAOFactory.deployments(daoId);
            if (deployment.vault == address(0) || deployment.stakingToken != deployment.vault) revert InvalidPair();
            helper = PersonalStakingHelper(Clones.clone(address(implementation)));
            helper.initialize(
                msg.sender, IERC4626(deployment.vault), IStakingRewards(deployment.coinStakingRewards)
            );
            helperOf[daoId][msg.sender] = helper;
            emit HelperCreated(daoId, msg.sender, address(helper));
        }

        helper.asset().safeTransferFrom(msg.sender, address(helper), assets);
        shares = helper.depositAndStake(assets, minShares);
        emit DepositedAndStaked(daoId, msg.sender, address(helper), assets, shares);
    }
}
