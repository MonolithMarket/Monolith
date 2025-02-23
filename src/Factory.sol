// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "lib/solmate/src/utils/CREATE3.sol";
import "src/USD2.sol";
import "src/SUSD2.sol";

library USD2Deployer {
    function getHash(address caller, uint nonce) internal view returns (bytes32) {
        return keccak256(abi.encode("core", block.chainid, address(this), caller, nonce));
    }

    function getAddress(address caller, uint nonce) external view returns (address) {
        return CREATE3.getDeployed(getHash(caller, nonce));
    }

    function deployUSD2(address caller, uint nonce, bytes memory data) external {
        CREATE3.deploy(getHash(caller, nonce), abi.encodePacked(type(USD2).creationCode, data), 0);
    }
}

library SUSD2Deployer {
    function getHash(address caller, uint nonce) internal view returns (bytes32) {
        return keccak256(abi.encode("staked", block.chainid, address(this), caller, nonce));
    }

    function getAddress(address caller, uint nonce) external view returns (address) {
        return CREATE3.getDeployed(getHash(caller, nonce));
    }

    function deploySUSD2(address caller, uint nonce, bytes memory data) external {
        CREATE3.deploy(getHash(caller, nonce), abi.encodePacked(type(SUSD2).creationCode, data), 0);
    }
}

contract Factory {

    address public pendingOperator;
    address public operator;
    address public feeRecipient;
    uint256 public feeBps;
    uint256 public constant MAX_FEE_BPS = 1000; // 10%

    address[] public deployments;
    mapping(address => bool) public isDeployed;

    constructor(address _operator) {
        operator = _operator;
    }

    modifier onlyOperator() {
        require(msg.sender == operator, "Only operator can call this function");
        _;
    }

    function deploymentsLength() external view returns (uint256) {
        return deployments.length;
    }

    function setPendingOperator(address _pendingOperator) external onlyOperator {
        pendingOperator = _pendingOperator;
    }

    function acceptOperator() external {
        require(msg.sender == pendingOperator, "Only pending operator can accept");
        operator = pendingOperator;
        pendingOperator = address(0);
    }

    function setFeeRecipient(address _feeRecipient) external onlyOperator {
        feeRecipient = _feeRecipient;
    }

    function setFeeBps(uint256 _feeBps) external onlyOperator {
        require(_feeBps <= MAX_FEE_BPS, "Feebps must be less than or equal to 1000");
        feeBps = _feeBps;
    }

    function pullReserves(address _deployment) external {
        require(msg.sender == feeRecipient, "Only fee recipient can pull reserves");
        require(isDeployed[_deployment], "Deployment not found");
        USD2(_deployment).pullGlobalReserves(msg.sender);
    }

    function deploy(
        string memory _name,
        string memory _symbol,
        address _collateral,
        address _feed,
        uint256 _collateralFactor,
        uint256 _minDebt,
        address _operator
    ) external returns (address core, address staked) {
        core = USD2Deployer.getAddress(msg.sender, deployments.length);
        staked = SUSD2Deployer.getAddress(msg.sender, deployments.length);
        USD2Deployer.deployUSD2(msg.sender, deployments.length, abi.encode(_name, _symbol, staked, _collateral, _feed, address(this), _operator, _collateralFactor, _minDebt));
        SUSD2Deployer.deploySUSD2(msg.sender, deployments.length, abi.encode(_name, _symbol, core));

        deployments.push(core);
        isDeployed[core] = true;
    }

}