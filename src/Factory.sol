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
    mapping(address => uint256) public customFeeBps;

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
        emit PendingOperatorUpdated(_pendingOperator);
    }

    function acceptOperator() external {
        require(msg.sender == pendingOperator, "Only pending operator can accept");
        operator = pendingOperator;
        pendingOperator = address(0);
        emit OperatorUpdated(operator);
    }

    function setFeeRecipient(address _feeRecipient) external onlyOperator {
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(_feeRecipient);
    }

    function setFeeBps(uint256 _feeBps) external onlyOperator {
        require(_feeBps <= MAX_FEE_BPS, "Feebps must be less than or equal to 1000");
        feeBps = _feeBps;
        emit FeeBpsUpdated(_feeBps);
    }

    function setCustomFeeBps(address _address, uint256 _feeBps) external onlyOperator {
        require(_feeBps <= MAX_FEE_BPS, "Feebps must be less than or equal to 1000");
        customFeeBps[_address] = _feeBps;
        emit CustomFeeBpsSet(_address, _feeBps);
    }

    function getFeeOf(address _lender) external view returns (uint256) {
        uint customFee = customFeeBps[_lender];
        if (customFee > 0) return customFee;
        return feeBps;
    }

    function pullReserves(address _deployment) external {
        require(msg.sender == feeRecipient, "Only fee recipient can pull reserves");
        require(isDeployed[_deployment], "Deployment not found");
        Lender(_deployment).pullGlobalReserves(msg.sender);
    }

    struct DeployParams {
        string name;
        string symbol;
        address collateral;
        address psmAsset;
        address psmVault;
        address feed;
        uint256 collateralFactor;
        uint256 minDebt;
        uint256 timeUntilImmutability;
        address operator;
        address manager;
        uint64 halfLife;
        uint16 targetFreeDebtRatioStartBps;
        uint16 targetFreeDebtRatioEndBps;
        uint16 redeemFeeBps;
        uint32 stalenessThreshold;
        uint16 maxBorrowDeltaBps;
    }

    function deploy(DeployParams memory params) external returns (address lender, address coin, address vault) {
        uint id = deployments.length;
        lender = LenderDeployer.getAddress(msg.sender, id);
        vault = VaultDeployer.getAddress(msg.sender, id);
        coin = CoinDeployer.getAddress(msg.sender, id);
        // these vars avoid stack too deep
        Lender.LenderParams memory lenderParams = Lender.LenderParams({
            collateral: ERC20(params.collateral),
            psmAsset: ERC20(params.psmAsset),
            psmVault: ERC4626(params.psmVault),
            feed: IChainlinkFeed(params.feed),
            coin: Coin(coin),
            vault: Vault(vault),
            interestModel: InterestModel(interestModel),
            factory: IFactory(address(this)),
            operator: params.operator,
            manager: params.manager,
            collateralFactor: params.collateralFactor,
            minDebt: params.minDebt,
            timeUntilImmutability: params.timeUntilImmutability,
            halfLife: params.halfLife,
            targetFreeDebtRatioStartBps: params.targetFreeDebtRatioStartBps,
            targetFreeDebtRatioEndBps: params.targetFreeDebtRatioEndBps,
            redeemFeeBps: params.redeemFeeBps,
            stalenessThreshold: params.stalenessThreshold,
            maxBorrowDeltaBps: params.maxBorrowDeltaBps
        });
        bytes memory lenderData = abi.encode(lenderParams);
        bytes memory vaultData = abi.encode(params.name, params.symbol, lender);
        bytes memory coinData = abi.encode(lender, params.name, params.symbol);
        LenderDeployer.deployLender(msg.sender, id, lenderData);
        CoinDeployer.deployCoin(msg.sender, id, coinData);
        VaultDeployer.deployVault(msg.sender, id, vaultData);
        deployments.push(lender);
        isDeployed[lender] = true;
        emit Deployed(lender, coin, vault);
    }

    event CustomFeeBpsSet(address indexed lender, uint256 feeBps);
    event Deployed(address indexed lender, address indexed coin, address indexed vault);
    event OperatorUpdated(address indexed operator);
    event PendingOperatorUpdated(address indexed pendingOperator);
    event FeeRecipientUpdated(address indexed feeRecipient);
    event FeeBpsUpdated(uint256 feeBps);
}