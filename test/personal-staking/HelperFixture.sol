// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Vault} from "../../src/Vault.sol";
import {StakingRewards} from "./fixtures/StakingRewards.sol";
import {PersonalStakingHelper} from "../../src/periphery/PersonalStakingHelper.sol";
import {PersonalStakingHelperFactory} from "../../src/periphery/PersonalStakingHelperFactory.sol";
import {IStakingRewards} from "../../src/periphery/interfaces/IStakingRewards.sol";
import {ICoinDAOFactory} from "../../src/periphery/interfaces/ICoinDAOFactory.sol";
import {CoinDAOFactoryRegistry} from "./fixtures/CoinDAOFactoryRegistry.sol";

contract MockToken is ERC20 {
    bool public blocked;
    address public hookTarget;
    address public hookFrom;
    bytes public hookData;
    bool public callbackSuccess;
    bytes public callbackResult;
    bool private inHook;

    constructor(string memory name_) ERC20(name_, name_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(bool value) external {
        blocked = value;
    }

    function setHook(address from, address target, bytes calldata data) external {
        hookFrom = from;
        hookTarget = target;
        hookData = data;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            require(!blocked, "TOKEN_BLOCKED");
            super._update(from, to, amount);
            if (!inHook && hookTarget != address(0) && from == hookFrom) {
                inHook = true;
                (callbackSuccess, callbackResult) = hookTarget.call(hookData);
                inHook = false;
            }
        } else {
            super._update(from, to, amount);
        }
    }
}

/// @dev Simulates lender interest; the vault is the repository's actual Vault contract.
contract LenderStub {
    MockToken public immutable coin;
    address public vault;
    uint256 public pending;

    constructor(MockToken coin_) {
        coin = coin_;
    }

    function setVault(address vault_) external {
        require(vault == address(0));
        vault = vault_;
    }

    function addInterest(uint256 amount) external {
        pending += amount;
    }

    function getPendingInterest() external view returns (uint256) {
        return pending;
    }

    function accrueInterest() external {
        uint256 amount = pending;
        pending = 0;
        if (amount != 0) coin.mint(vault, amount);
    }
}

struct TestMarket {
    MockToken token;
    MockToken gov;
    LenderStub lender;
    IERC4626 vault;
    StakingRewards pool;
}

abstract contract HelperFixture is Test {
    MockToken internal token;
    MockToken internal gov;
    LenderStub internal lender;
    IERC4626 internal vault;
    StakingRewards internal pool;
    PersonalStakingHelperFactory internal factory;
    CoinDAOFactoryRegistry internal coinDAOFactory;
    uint256 internal daoId;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    uint256 internal constant MIN_SHARES = 1e16;
    uint256 internal constant DURATION = 30 days;

    function setUp() public virtual {
        vm.warp(1_000_000);
        coinDAOFactory = new CoinDAOFactoryRegistry();
        TestMarket memory market;
        (daoId, market) = createDAO("Token", true);
        token = market.token;
        gov = market.gov;
        lender = market.lender;
        vault = market.vault;
        pool = market.pool;
        factory = new PersonalStakingHelperFactory(ICoinDAOFactory(address(coinDAOFactory)));
        fundAndApprove(market, alice, 1e30);
        fundAndApprove(market, bob, 1e30);
    }

    function createDAO(string memory name, bool stakeVault) internal returns (uint256 id, TestMarket memory market) {
        market.token = new MockToken(name);
        market.gov = new MockToken(string.concat(name, " GOV"));
        market.lender = new LenderStub(market.token);
        market.vault = IERC4626(address(new Vault(name, name, address(market.lender))));
        market.lender.setVault(address(market.vault));
        market.pool = StakingRewards(Clones.clone(address(new StakingRewards())));
        address stakingToken = stakeVault ? address(market.vault) : address(market.token);
        market.pool.initialize(stakingToken, address(market.gov), address(this), DURATION);
        market.gov.mint(address(market.pool), DURATION * 1e18);
        market.pool.notifyRewardAmount(DURATION * 1e18);
        CoinDAOFactoryRegistry.Deployment memory deployment;
        deployment.govToken = address(market.gov);
        deployment.lender = address(market.lender);
        deployment.coin = address(market.token);
        deployment.vault = address(market.vault);
        deployment.stakingToken = stakingToken;
        deployment.coinStakingRewards = address(market.pool);
        id = coinDAOFactory.addDeployment(deployment);
    }

    function fundAndApprove(TestMarket memory market, address who, uint256 amount) internal {
        market.token.mint(who, amount);
        vm.prank(who);
        market.token.approve(address(factory), type(uint256).max);
    }

    function deposit(address who, uint256 assets) internal returns (PersonalStakingHelper helper, uint256 shares) {
        uint256 quote = vault.previewDeposit(assets);
        vm.prank(who);
        return factory.depositAndStake(daoId, assets, quote);
    }

    function depositIn(uint256 id, TestMarket memory market, address who, uint256 assets)
        internal
        returns (PersonalStakingHelper helper, uint256 shares)
    {
        uint256 quote = market.vault.previewDeposit(assets);
        vm.prank(who);
        return factory.depositAndStake(id, assets, quote);
    }

    function assertClean(PersonalStakingHelper helper) internal view {
        IERC20 marketToken = helper.asset();
        IERC4626 marketVault = helper.vault();
        IStakingRewards marketPool = helper.stakingRewards();
        assertEq(marketToken.balanceOf(address(factory)), 0);
        assertEq(marketVault.balanceOf(address(factory)), 0);
        assertEq(marketPool.balanceOf(address(factory)), 0);
        assertEq(marketToken.balanceOf(address(helper)), 0);
        assertEq(marketVault.balanceOf(address(helper)), 0);
        assertEq(marketToken.allowance(address(helper), address(marketVault)), 0);
        assertEq(marketVault.allowance(address(helper), address(marketPool)), 0);
    }
}
