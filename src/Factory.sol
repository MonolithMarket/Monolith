// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "src/USD2.sol";
import "src/SUSD2.sol";

contract Factory {

    address public immutable usd2;
    address public immutable susd2;

    constructor(address _collateral, address _feed, address _operator) {
        usd2 = address(new USD2(_collateral, _feed, _operator));
        susd2 = address(new SUSD2(_operator, usd2));
        USD2(usd2).initialize(susd2);
    }

}