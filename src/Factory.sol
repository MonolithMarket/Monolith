// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "lib/solmate/src/utils/CREATE3.sol";
import "src/Lender.sol";
import "src/Vault.sol";
import "src/Coin.sol";
import "src/InterestModel.sol";

library InterestModelDeployer {
    function deploy() external returns (address) {
        return address(new InterestModel());
    }
}

library LenderDeployer {
    function getHash(address caller, uint nonce) internal view returns (bytes32) {
        return keccak256(abi.encode("lender", block.chainid, address(this), caller, nonce));
    }

    function getAddress(address caller, uint nonce) external view returns (address) {
        return CREATE3.getDeployed(getHash(caller, nonce));
    }

    function deployLender(address caller, uint nonce, bytes memory data) external {
        CREATE3.deploy(getHash(caller, nonce), abi.encodePacked(type(Lender).creationCode, data), 0);
    }
}

library VaultDeployer {
    function getHash(address caller, uint nonce) internal view returns (bytes32) {
        return keccak256(abi.encode("vault", block.chainid, address(this), caller, nonce));
    }

    function getAddress(address caller, uint nonce) external view returns (address) {
        return CREATE3.getDeployed(getHash(caller, nonce));
    }

    function deployVault(address caller, uint nonce, bytes memory data) external {
        CREATE3.deploy(getHash(caller, nonce), abi.encodePacked(type(Vault).creationCode, data), 0);
    }
}

library CoinDeployer {
    function getHash(address caller, uint nonce) internal view returns (bytes32) {
        return keccak256(abi.encode("coin", block.chainid, address(this), caller, nonce));
    }

    function getAddress(address caller, uint nonce) external view returns (address) {
        return CREATE3.getDeployed(getHash(caller, nonce));
    }

    function deployCoin(address caller, uint nonce, bytes memory data) external {
        CREATE3.deploy(getHash(caller, nonce), abi.encodePacked(type(Coin).creationCode, data), 0);
    }
}

contract Factory {

    address public pendingOperator;
    address public operator;
    address public feeRecipient;
    uint256 public feeBps;
    address public immutable interestModel;
    uint256 public constant MAX_FEE_BPS = 1000; // 10%

    address[] public deployments;
    mapping(address => bool) public isDeployed;

    constructor(address _operator) {
        operator = _operator;
        interestModel = InterestModelDeployer.deploy();
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
        Lender(_deployment).pullGlobalReserves(msg.sender);
    }

    function deploy(
        string memory _name,
        string memory _symbol,
        address _collateral,
        address _feed,
        uint256 _collateralFactor,
        uint256 _minDebt,
        uint256 _timeUntilImmutability,
        address _operator
    ) external returns (address lender, address coin, address vault) {
        uint id = deployments.length;
        lender = LenderDeployer.getAddress(msg.sender, id);
        vault = VaultDeployer.getAddress(msg.sender, id);
        coin = CoinDeployer.getAddress(msg.sender, id);
        // these vars avoid stack too deep
        bytes memory lenderData = abi.encode(
            _collateral,
            _feed,
            coin,
            vault,
            interestModel,
            address(this),
            _operator,
            _collateralFactor,
            _minDebt,
            _timeUntilImmutability
        );
        bytes memory vaultData = abi.encode(_name, _symbol, lender);    
        bytes memory coinData = abi.encode(lender, _name, _symbol);
        LenderDeployer.deployLender(msg.sender, id, lenderData);
        CoinDeployer.deployCoin(msg.sender, id, coinData);
        VaultDeployer.deployVault(msg.sender, id, vaultData);
        deployments.push(lender);
        isDeployed[lender] = true;
    }

}