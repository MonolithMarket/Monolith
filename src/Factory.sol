// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "lib/solmate/src/utils/CREATE3.sol";
import "src/USD2.sol";
import "src/SUSD2.sol";

contract Factory {

    address public immutable usd2;
    address public immutable susd2;

    constructor(address _collateral, address _feed, address _operator) {
        usd2 = CREATE3.getDeployed(keccak256("USD2"));
        susd2 = CREATE3.getDeployed(keccak256("SUSD2"));
        CREATE3.deploy(
            keccak256("USD2"),
            abi.encodePacked(type(USD2).creationCode, abi.encode(susd2, _collateral, _feed, _operator)),
            0
        );
        CREATE3.deploy(
            keccak256("SUSD2"),
            abi.encodePacked(type(SUSD2).creationCode, abi.encode(_operator, usd2)),
            0
        );
    }

}