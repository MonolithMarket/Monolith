// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "lib/solmate/src/utils/CREATE3.sol";
import "src/USD2.sol";
import "src/SUSD2.sol";

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

    function pullFees(address _deployment) external {
        require(msg.sender == feeRecipient, "Only fee recipient can pull fees");
        require(isDeployed[_deployment], "Deployment not found");
        USD2(_deployment).pullGlobalFees(msg.sender);
    }

    function deploy(
        string memory _name,
        string memory _symbol,
        address _collateral,
        address _feed,
        uint256 _collateralFactor,
        address _operator
    ) external returns (address core, address staked) {
        bytes32 coreHash = keccak256(abi.encode(block.chainid, address(this), msg.sender, "core", deployments.length));
        bytes32 stakedHash = keccak256(abi.encode(block.chainid, address(this), msg.sender, "staked", deployments.length));
        
        core = CREATE3.getDeployed(coreHash);
        staked = CREATE3.getDeployed(stakedHash);

        CREATE3.deploy(
            coreHash,
            abi.encodePacked(type(USD2).creationCode, abi.encode(_name, _symbol, staked, _collateral, _feed, address(this), _operator, _collateralFactor)),
            0
        );
        CREATE3.deploy(
            stakedHash,
            abi.encodePacked(type(SUSD2).creationCode, abi.encode(_name, _symbol, core)),
            0
        );

        deployments.push(core);
        isDeployed[core] = true;
    }

}