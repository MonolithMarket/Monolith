// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract CollateralManager {
    
    address public immutable usd2;
    IERC20 public immutable asset;
    uint256 public totalShares;
    uint256 public totalAssets;
    mapping(address => uint256) private _shares;

    uint256 public shareMergeCount;
    mapping(address => uint256) public lastShareMergeCount;

    constructor(IERC20 _asset) {
        asset = _asset;
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
        return convertToAssets(sharesOf(account));
    }

    function seize(uint256 assets, address to) public onlyUSD2 {
        totalAssets -= assets;

        require(asset.transfer(to, assets), "Asset transfer failed");

        emit Seize(to, assets);

        if (totalShares > 1e18 && convertToShares(1e18) > 1e36) {
            totalShares /= 1e18;
            shareMergeCount++;
            emit Rebase(shareMergeCount);
        }
    }

    function deposit(address receiver) public updateShares(receiver) returns (uint256 shares) {
        uint256 assets = asset.balanceOf(address(this)) - totalAssets;
        shares = totalShares == 0 ? assets : (assets * totalShares) / totalAssets;
        require(shares > 0, "Deposit would result in zero shares");

        require(asset.transferFrom(msg.sender, address(this), assets), "Asset transfer failed");

        totalAssets += assets;
        totalShares += shares;
        _shares[receiver] += shares;

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) public onlyUSD2 updateShares(owner) returns (uint256 shares) {
        shares = (assets * totalShares) / totalAssets;
        require(shares > 0, "Withdraw would result in zero shares");

        _shares[owner] -= shares;
        totalShares -= shares;
        totalAssets -= assets;

        require(asset.transfer(receiver, assets), "Asset transfer failed");

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }


    function convertToShares(uint256 assets) public view returns (uint256 shares) {
        return totalShares == 0 ? assets : (assets * totalShares) / totalAssets;
    }

    function convertToAssets(uint256 shares) public view returns (uint256 assets) {
        return totalShares == 0 ? shares : (shares * totalAssets) / totalShares;
    }

    function maxDeposit(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) public view returns (uint256) {
        return convertToAssets(sharesOf(owner));
    }

    function maxRedeem(address owner) public view returns (uint256) {
        return sharesOf(owner);
    }

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event Seize(address indexed to, uint256 assets);
    event Rebase(uint newMergeCount);
}