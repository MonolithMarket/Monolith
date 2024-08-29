// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract CollateralManager {
    
    address public immutable usd2;
    IERC20 public immutable asset;
    uint256 public totalShares;
    uint256 public totalRedeemable;
    uint256 public totalNonRedeemable;
    mapping(address => uint256) private _shares;
    mapping(address => uint256) private _collateral; // non-redeemable collateral
    mapping(address => bool) public isRedeemable;

    uint256 public shareMergeCount;
    mapping(address => uint256) public lastShareMergeCount;

    constructor(address _asset) {
        asset = IERC20(_asset);
        usd2 = msg.sender;
    }

    modifier onlyUSD2() {
        require(msg.sender == usd2, "Not authorized");
        _;
    }

    modifier updateShares(address account) {
        _shares[account] = sharesOf(account);
        lastShareMergeCount[account] = shareMergeCount;
        _;
    }

    function sharesOf(address account) public view returns (uint256) {
        uint256 rawShares = _shares[account];
        uint256 accountLastMergeCount = lastShareMergeCount[account];
        uint256 mergeDelta = shareMergeCount - accountLastMergeCount;
        if (mergeDelta > 0) {
            return rawShares / (10 ** (18 * mergeDelta));
        }
        return rawShares;
    }

    function collateralOf(address account) public view returns (uint256) {
        if(isRedeemable[account]) {
            return convertToAssets(sharesOf(account));
        }
        return _collateral[account];
    }

    function seize(uint256 assets, address to) public onlyUSD2 {
        totalRedeemable -= assets;

        require(asset.transfer(to, assets), "Asset transfer failed");

        emit Seize(to, assets);

        if (totalShares > 1e18 && convertToShares(1e18) > 1e36) {
            totalShares /= 1e18;
            shareMergeCount++;
            emit Rebase(shareMergeCount);
        }
    }

    function deposit(address receiver) public updateShares(receiver) returns (uint256 shares) {
        uint256 assets = asset.balanceOf(address(this)) - totalRedeemable - totalNonRedeemable;
        if(isRedeemable[receiver]) {
            shares = totalShares == 0 ? assets : (assets * totalShares) / totalRedeemable;
            require(shares > 0, "Deposit would result in zero shares");
            totalRedeemable += assets;
            totalShares += shares;
            _shares[receiver] += shares;
        } else {
            _collateral[receiver] += assets;
            totalNonRedeemable += assets;
        }
    }

    function withdraw(uint256 assets, address receiver, address owner) public onlyUSD2 updateShares(owner) returns (uint256 shares) {
        if(isRedeemable[owner]) {
            if(assets == type(uint256).max) {
                assets = collateralOf(owner);
                shares = _shares[owner];
            } else {
                shares = (assets * totalShares) / totalRedeemable;
            }
            require(shares > 0, "Withdraw would result in zero shares");
            _shares[owner] -= shares;
            totalShares -= shares;
            totalRedeemable -= assets;
        } else {
            if(assets == type(uint256).max) {
                assets = _collateral[owner];
            }
            _collateral[receiver] -= assets;
            totalNonRedeemable -= assets;
        }

        require(asset.transfer(receiver, assets), "Asset transfer failed");
    }

    function setRedeemable(address account, bool redeemable) public onlyUSD2 updateShares(account) {
        if(redeemable) { // become redeemable
            uint assets = _collateral[account];
            if(assets > 0) {
                _collateral[account] = 0;
                totalNonRedeemable -= assets;
                totalRedeemable += assets;
                uint shares = totalShares == 0 ? assets : (assets * totalShares) / totalRedeemable;
                require(shares > 0, "Zero shares");
                totalRedeemable += assets;
                totalShares += shares;
                _shares[account] += shares;
            }
            isRedeemable[account] = true;
        } else { // become non-redeemable
            uint shares = _shares[account];
            if(shares > 0) {
                uint assets = convertToAssets(shares);
                require(assets > 0, "Zero shares");
                _shares[account] = 0;
                totalShares -= shares;
                totalRedeemable -= assets;
                totalNonRedeemable += assets;
                _collateral[account] += assets;
            }
            isRedeemable[account] = false;
        }
    }

    function convertToShares(uint256 assets) public view returns (uint256 shares) {
        return totalShares == 0 ? assets : (assets * totalShares) / totalRedeemable;
    }

    function convertToAssets(uint256 shares) public view returns (uint256 assets) {
        return totalShares == 0 ? shares : (shares * totalRedeemable) / totalShares;
    }

    event Seize(address indexed to, uint256 assets);
    event Rebase(uint newMergeCount);
}