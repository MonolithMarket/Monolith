// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import "lib/solmate/src/tokens/ERC20.sol";

contract Coin is ERC20 {

    address public immutable minter;

    constructor(address _minter, string memory name, string memory symbol) ERC20(name, symbol, 18) {
        minter = _minter;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "Only minter can mint");
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}