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

contract MockToken is ERC20 {
    bool public blocked;
    uint256 public transferFeeBps;
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

    function setFee(uint256 value) external {
        transferFeeBps = value;
    }

    function setHook(address from, address target, bytes calldata data) external {
        hookFrom = from;
        hookTarget = target;
        hookData = data;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            require(!blocked, "TOKEN_BLOCKED");
            uint256 fee = amount * transferFeeBps / 10_000;
            if (fee != 0) super._update(from, address(0), fee);
            super._update(from, to, amount - fee);
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

/// @dev Only the lender is simulated. The vault is the repository's actual Vault contract.
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

abstract contract HelperFixture is Test {
    MockToken internal token;
    MockToken internal gov;
    LenderStub internal lender;
    IERC4626 internal vault;
    StakingRewards internal pool;
    PersonalStakingHelperFactory internal factory;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    uint256 internal constant MIN_SHARES = 1e16;
    uint256 internal constant DURATION = 30 days;

    function setUp() public virtual {
        vm.warp(1_000_000);
        token = new MockToken("Token");
        gov = new MockToken("GOV");
        lender = new LenderStub(token);
        vault = IERC4626(address(new Vault("Token", "TOKEN", address(lender))));
        lender.setVault(address(vault));
        pool = StakingRewards(Clones.clone(address(new StakingRewards())));
        pool.initialize(address(vault), address(gov), address(this), DURATION);
        gov.mint(address(pool), DURATION * 1e18);
        pool.notifyRewardAmount(DURATION * 1e18);
        factory = new PersonalStakingHelperFactory(vault, IStakingRewards(address(pool)));
        token.mint(alice, 1e30);
        token.mint(bob, 1e30);
        vm.prank(alice);
        token.approve(address(factory), type(uint256).max);
        vm.prank(bob);
        token.approve(address(factory), type(uint256).max);
    }

    function deposit(address who, uint256 assets) internal returns (PersonalStakingHelper helper, uint256 shares) {
        uint256 quote = vault.previewDeposit(assets);
        vm.prank(who);
        return factory.depositAndStake(assets, quote, block.timestamp);
    }

    function assertClean(PersonalStakingHelper helper) internal view {
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(vault.balanceOf(address(factory)), 0);
        assertEq(pool.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(address(helper)), 0);
        assertEq(vault.balanceOf(address(helper)), 0);
        assertEq(token.allowance(address(helper), address(vault)), 0);
        assertEq(vault.allowance(address(helper), address(pool)), 0);
    }
}
