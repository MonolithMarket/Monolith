// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Factory} from "src/Factory.sol";
import {UmaEventTriggerOracle} from "src/UmaEventTriggerOracle.sol";

/// @notice Convenience wrapper for deploying Monolith markets with UMA event-trigger adapters.
contract UmaMarketFactory {
    Factory public immutable factory;
    address public immutable optimisticOracleV3;

    address[] public umaMarkets;
    mapping(address => bool) public isUmaMarket;
    mapping(address => address) public eventTriggerOracleOf;

    constructor(address _factory, address _optimisticOracleV3) {
        require(_factory != address(0), "Invalid factory");
        require(_optimisticOracleV3 != address(0), "Invalid oracle");

        factory = Factory(_factory);
        optimisticOracleV3 = _optimisticOracleV3;
    }

    struct DeployParams {
        string name;
        string symbol;
        address collateral;
        address psmAsset;
        address psmVault;
        address feed;
        uint256 collateralFactor;
        uint256 minDebt;
        uint256 timeUntilImmutability;
        address operator;
        address manager;
        uint64 halfLife;
        uint16 targetPsmDebtRatioStartBps;
        uint16 targetPsmDebtRatioEndBps;
        uint32 stalenessThreshold;
        uint16 maxBorrowDeltaBps;
        uint128 psmVaultMinTotalSupply;
        bytes triggerClaim;
    }

    function umaMarketsLength() external view returns (uint256) {
        return umaMarkets.length;
    }

    function deploy(DeployParams memory params)
        external
        returns (address lender, address coin, address vault, address eventTriggerOracle)
    {
        eventTriggerOracle = address(new UmaEventTriggerOracle(optimisticOracleV3, params.triggerClaim));

        Factory.DeployParams memory factoryParams = Factory.DeployParams({
            name: params.name,
            symbol: params.symbol,
            collateral: params.collateral,
            psmAsset: params.psmAsset,
            psmVault: params.psmVault,
            feed: params.feed,
            collateralFactor: params.collateralFactor,
            minDebt: params.minDebt,
            timeUntilImmutability: params.timeUntilImmutability,
            operator: params.operator,
            manager: params.manager,
            eventTriggerOperator: eventTriggerOracle,
            halfLife: params.halfLife,
            targetPsmDebtRatioStartBps: params.targetPsmDebtRatioStartBps,
            targetPsmDebtRatioEndBps: params.targetPsmDebtRatioEndBps,
            stalenessThreshold: params.stalenessThreshold,
            maxBorrowDeltaBps: params.maxBorrowDeltaBps,
            psmVaultMinTotalSupply: params.psmVaultMinTotalSupply
        });

        (lender, coin, vault) = factory.deploy(factoryParams);
        UmaEventTriggerOracle(eventTriggerOracle).bindLender(lender);

        umaMarkets.push(lender);
        isUmaMarket[lender] = true;
        eventTriggerOracleOf[lender] = eventTriggerOracle;

        emit UmaMarketDeployed(msg.sender, lender, coin, vault, eventTriggerOracle);
    }

    event UmaMarketDeployed(
        address indexed deployer,
        address indexed lender,
        address indexed coin,
        address vault,
        address eventTriggerOracle
    );
}
