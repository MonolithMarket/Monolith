// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import {Test, console} from "forge-std/Test.sol";
import  "lib/solmate/src/tokens/ERC20.sol";
import {SUSD2} from "src/SUSD2.sol";

contract MockUSD2 is ERC20 {

    bool public isAccrued;
    uint public mockInterest;

    constructor() ERC20("USD2", "USD2", 18) {}

    // this is to be called by SUSD2 only, not directly by the tests
    function accrueInterest() public {
        isAccrued = true;
        // we assume msg.sender is SUSD2 in this mock, which is not the case in the real implementation
        __mint(msg.sender, mockInterest);
    }

    function __mint(address _to, uint _amount) public {
        _mint(_to, _amount);
    }

    function __setMockInterest(uint _interest) public {
        mockInterest = _interest;
    }
}

contract SUSD2Test is Test {

    MockUSD2 usd2 = new MockUSD2();
    SUSD2 susd2;

    function setUp() public {
        susd2 = new SUSD2("USD2", "USD2", address(usd2));
    }

    function test_constructor() public {
        assertEq(susd2.name(), "Staked USD2");
        assertEq(susd2.symbol(), "sUSD2");
        assertEq(address(susd2.asset()), address(usd2));
    }

    function test_deposit_success() public {
        usd2.__mint(address(this), 100);
        usd2.approve(address(susd2), 100);
        uint shares = susd2.deposit(100, address(this));
        assertEq(shares, 100);
        assertEq(susd2.balanceOf(address(this)), 100);
        assertEq(susd2.totalAssets(), 100);
        assertEq(susd2.totalSupply(), 100);
        assertEq(usd2.balanceOf(address(susd2)), 100);
        assertEq(usd2.isAccrued(), true);
    }

    function test_deposit_afterInterest() public {
        test_deposit_success();
        usd2.__setMockInterest(100);
        usd2.__mint(address(this), 100);
        usd2.approve(address(susd2), 100);
        uint shares = susd2.deposit(100, address(this));
        // there's already 100 shares worth 100 usd2
        // after interest, they're worth 200 usd2
        // depositing 100 extra usd2, we get 1/2 of the existing shares
        // so we get 50 shares
        assertEq(shares, 50);
        assertEq(susd2.balanceOf(address(this)), 150);
        assertEq(susd2.totalAssets(), 300);
        assertEq(susd2.totalSupply(), 150);
        assertEq(usd2.balanceOf(address(susd2)), 300);
        assertEq(usd2.isAccrued(), true);
    }
    
    function test_mint_success() public {
        usd2.__mint(address(this), 100);
        usd2.approve(address(susd2), 100);
        uint shares = susd2.convertToShares(100);
        uint amountOut = susd2.mint(shares, address(this));
        assertEq(amountOut, 100);
        assertEq(susd2.balanceOf(address(this)), 100);
        assertEq(susd2.totalAssets(), 100);
        assertEq(susd2.totalSupply(), 100);
        assertEq(usd2.balanceOf(address(susd2)), 100);
        assertEq(usd2.isAccrued(), true);
    }

    function test_mint_afterInterest() public {
        test_mint_success();
        usd2.__setMockInterest(100);
        usd2.__mint(address(this), 100);
        usd2.approve(address(susd2), 100);
        uint shares = susd2.convertToShares(50);
        uint amountOut = susd2.mint(shares, address(this));
        assertEq(amountOut, 100);
        assertEq(susd2.balanceOf(address(this)), 150);
        assertEq(susd2.totalAssets(), 300);
        assertEq(susd2.totalSupply(), 150);
        assertEq(usd2.balanceOf(address(susd2)), 300);
        assertEq(usd2.isAccrued(), true);
    }

    function test_withdraw_success() public {
        test_deposit_success();
        uint shares = susd2.convertToShares(100);
        uint sharesOut = susd2.withdraw(100, address(this), address(this));
        assertEq(sharesOut, shares);
        assertEq(susd2.balanceOf(address(this)), 0);
        assertEq(susd2.totalAssets(), 0);
        assertEq(susd2.totalSupply(), 0);
        assertEq(usd2.balanceOf(address(susd2)), 0);
        assertEq(usd2.isAccrued(), true);
    }

    function test_withdraw_afterInterest() public {
        test_deposit_afterInterest();
        usd2.__setMockInterest(0); // avoid adding more interest
        uint shares = susd2.convertToShares(100);
        uint sharesOut = susd2.withdraw(100, address(this), address(this));
        assertEq(sharesOut, shares);
        assertEq(susd2.balanceOf(address(this)), 100); // after interest
        assertEq(susd2.totalAssets(), 200);
        assertEq(susd2.totalSupply(), 100);
        assertEq(usd2.balanceOf(address(susd2)), 200);
        assertEq(usd2.isAccrued(), true);
    }

    function test_redeem_success() public {
        test_deposit_success();
        uint shares = susd2.balanceOf(address(this));
        uint amountOut = susd2.redeem(shares, address(this), address(this));
        assertEq(amountOut, 100);
        assertEq(susd2.balanceOf(address(this)), 0);
        assertEq(susd2.totalAssets(), 0);
        assertEq(susd2.totalSupply(), 0);
        assertEq(usd2.balanceOf(address(susd2)), 0);
        assertEq(usd2.isAccrued(), true);
    }

    function test_redeem_afterInterest() public {
        test_deposit_afterInterest();
        usd2.__setMockInterest(0); // avoid adding more interest
        uint shares = susd2.convertToShares(100);
        uint amountOut = susd2.redeem(shares, address(this), address(this));
        assertEq(amountOut, 100);
        assertEq(susd2.balanceOf(address(this)), 100); // after interest
        assertEq(susd2.totalAssets(), 200);
        assertEq(susd2.totalSupply(), 100);
        assertEq(usd2.balanceOf(address(susd2)), 200);
        assertEq(usd2.isAccrued(), true);
    }

}
