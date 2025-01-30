// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "lib/solmate/src/tokens/ERC20.sol";

contract TestCollateral is ERC20 { 
    constructor() ERC20("TestCollateral", "TestCollateral", 18) {}

    function getFreeTokens() external {
        sendFreeTokens(msg.sender, 1000000000000000000000);
    }

    function sendFreeTokens(address to, uint amount) public {
        _mint(to, amount);
    }
}
