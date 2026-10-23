// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CoinDAOFactory} from "coin-dao/CoinDAOFactory.sol";
import {IMonolithFactory, IMonolithLender} from "coin-dao/interfaces/IMonolith.sol";

/// @dev Test-only bridge between Monolith's exact 0.8.24 and CoinDAO's 0.8.26 sources.
/// All factories, implementations and pools are compiled from their unchanged sources.
contract CoinDAOTestDeployer {
    function launch(address registry, address collateral, address feed, bool stakeVault) external returns (uint256 id) {
        CoinDAOFactory factory = CoinDAOFactory(registry);
        id = factory.deploymentsLength();
        factory.deploy(bytes32(id + 1), _govParams(stakeVault), _marketParams(collateral, feed), address(this));
    }

    function createExistingMarket(address registry, address collateral, address feed)
        external
        returns (address lender)
    {
        (lender,,) = CoinDAOFactory(registry).monolithFactory().deploy(_marketParams(collateral, feed));
    }

    function attach(address registry, address lender) external returns (uint256 id) {
        CoinDAOFactory factory = CoinDAOFactory(registry);
        id = factory.deploymentsLength();
        IMonolithLender(lender).setPendingOperator(registry);
        factory.deployForExistingCoin(bytes32(id + 1), _govParams(true), lender);
    }

    function _govParams(bool stakeVault) private view returns (CoinDAOFactory.GovLaunchParams memory) {
        return CoinDAOFactory.GovLaunchParams({
            govTokenName: "Test Governance",
            govTokenSymbol: "GOV",
            deployerStakeBps: 0,
            deployerRecipient: address(this),
            stakingTokenChoice: stakeVault
                ? CoinDAOFactory.StakingTokenChoice.SCoin
                : CoinDAOFactory.StakingTokenChoice.Coin
        });
    }

    function _marketParams(address collateral, address feed)
        private
        view
        returns (IMonolithFactory.DeployParams memory)
    {
        return IMonolithFactory.DeployParams({
            name: "Test USD",
            symbol: "tUSD",
            collateral: collateral,
            psmAsset: address(0),
            psmVault: address(0),
            feed: feed,
            collateralFactor: 5000,
            minDebt: 1000e18,
            timeUntilImmutability: 365 days,
            operator: address(this),
            manager: address(this),
            halfLife: 7 days,
            targetFreeDebtRatioStartBps: 2000,
            targetFreeDebtRatioEndBps: 4000,
            redeemFeeBps: 30,
            stalenessThreshold: 48 hours,
            maxBorrowDeltaBps: 50,
            psmVaultMinTotalSupply: 1
        });
    }
}
