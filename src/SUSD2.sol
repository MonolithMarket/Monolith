// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "lib/solmate/src/tokens/ERC4626.sol";

interface IUSD2 {
    function accrueInterest() external;
}

contract SUSD2 is ERC4626 {

    uint public constant MAX_FEE_BPS = 2500;
    address public operator;
    address public pendingOperator;
    address public feeRecipient;
    uint internal _totalAssets;
    uint public feeBps;

    constructor(address _operator, address _usd2) ERC4626(ERC20(_usd2), "Staked USD2", "sUSD2") {
        operator = _operator;
    }

    function setPendingOperator(address _pendingOperator) external {
        require(msg.sender == operator, "SUSD2: FORBIDDEN");
        pendingOperator = _pendingOperator;
    }

    function claimOperator() external {
        require(msg.sender == pendingOperator, "SUSD2: FORBIDDEN");
        operator = pendingOperator;
        pendingOperator = address(0);
    }

    function setFeeRecipient(address _feeRecipient) external {
        require(msg.sender == operator, "SUSD2: FORBIDDEN");
        feeRecipient = _feeRecipient;
    }

    function setFeeBps(uint _feeBps) external {
        accrueInterest(); // apply old fee before changing fee
        require(msg.sender == operator, "SUSD2: FORBIDDEN");
        require(_feeBps <= MAX_FEE_BPS, "SUSD2: INVALID_FEE");
        feeBps = _feeBps;
    }

    function beforeWithdraw(uint256 assets, uint256) internal override {
        _totalAssets -= assets;
    }

    function afterDeposit(uint256 assets, uint256) internal override {
        _totalAssets += assets;
    }

    function accrueInterest() public {
        IUSD2(address(asset)).accrueInterest();
        uint bal = asset.balanceOf(address(this));
        if (bal > _totalAssets) {
            uint fee = (bal - _totalAssets) * feeBps / 10000;
            _totalAssets = bal;
            if(fee > 0 && feeRecipient != address(0)) _mint(feeRecipient, convertToShares(fee));
        }
    }

    function totalAssets() public view override returns (uint256) {
        return _totalAssets;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        accrueInterest();
        shares = super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override returns (uint256 assets) {
        accrueInterest();
        assets = super.mint(shares, receiver);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override returns (uint256 shares) {
        accrueInterest();
        shares = super.withdraw(assets, receiver, owner);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override returns (uint256 assets) {
        accrueInterest();
        assets = super.redeem(shares, receiver, owner);
    }

}