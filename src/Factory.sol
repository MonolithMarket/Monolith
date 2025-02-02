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

    // constructor(address _collateral, address _feed, address _operator) {
    //     usd2 = CREATE3.getDeployed(keccak256("USD2"));
    //     susd2 = CREATE3.getDeployed(keccak256("SUSD2"));
    //     CREATE3.deploy(
    //         keccak256("USD2"),
    //         abi.encodePacked(type(USD2).creationCode, abi.encode(susd2, _collateral, _feed, _operator)),
    //         0
    //     );
    //     CREATE3.deploy(
    //         keccak256("SUSD2"),
    //         abi.encodePacked(type(SUSD2).creationCode, abi.encode(_operator, usd2)),
    //         0
    //     );
    // }

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

    function sweep(address _token) external {
        require(msg.sender == feeRecipient || msg.sender == operator, "Only fee recipient or operator can sweep");
        IERC20(_token).transfer(feeRecipient, IERC20(_token).balanceOf(address(this)));
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
            abi.encodePacked(type(USD2).creationCode, abi.encode(_name, _symbol, staked, _collateral, _feed, _operator, _collateralFactor)),
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