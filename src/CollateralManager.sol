// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract CollateralManager {
    
    address public immutable usd2;
    IERC20 public immutable asset;
    uint256 public totalRedeemableShares;
    uint256 public totalRedeemable;
    uint256 public totalNonRedeemableShares;
    uint256 public totalNonRedeemable;
    mapping(address => uint256) private _redeemableShares;
    mapping(address => uint256) public nonRedeemableShares;
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
        _redeemableShares[account] = redeemableSharesOf(account);
        lastShareMergeCount[account] = shareMergeCount;
        _;
    }

    function redeemableSharesOf(address account) public view returns (uint256) {
        uint256 rawShares = _redeemableShares[account];
        uint256 accountLastMergeCount = lastShareMergeCount[account];
        uint256 mergeDelta = shareMergeCount - accountLastMergeCount;
        if (mergeDelta > 0) {
            return rawShares / (10 ** (18 * mergeDelta));
        }
        return rawShares;
    }

    function collateralOf(address account) public view returns (uint256) {
        if(isRedeemable[account]) {
            return convertToRedeemableAssets(redeemableSharesOf(account));
        }
        return convertToNonRedeemableAssets(nonRedeemableShares[account]);
    }

    function seize(uint256 assets, address to) public onlyUSD2 {
        require(totalRedeemable > assets, "Remaining redeemable collateral cannot be zero");
        totalRedeemable -= assets;

        require(asset.transfer(to, assets), "Asset transfer failed");

        emit Seize(to, assets);

        if (totalRedeemableShares > 1e18 && convertToRedeemableShares(1e18) > 1e36) {
            totalRedeemableShares /= 1e18;
            shareMergeCount++;
            emit Rebase(shareMergeCount);
        }
    }

    function deposit(address receiver) public updateShares(receiver) returns (uint256 shares) {
        uint256 assets = asset.balanceOf(address(this)) - totalRedeemable - totalNonRedeemable;
        if(isRedeemable[receiver]) {
            shares = totalRedeemableShares == 0 ? assets : (assets * totalRedeemableShares) / totalRedeemable;
            require(shares > 0, "Deposit would result in zero shares");
            totalRedeemable += assets;
            totalRedeemableShares += shares;
            _redeemableShares[receiver] += shares;
        } else {
            shares = totalNonRedeemableShares == 0 ? assets : (assets * totalNonRedeemableShares) / totalNonRedeemable;
            require(shares > 0, "Deposit would result in zero shares");
            totalNonRedeemable += assets;
            totalNonRedeemableShares += shares;
            nonRedeemableShares[receiver] += shares;
        }
    }

    function withdraw(uint256 assets, address receiver, address owner) public onlyUSD2 updateShares(owner) returns (uint256 shares) {
        if(isRedeemable[owner]) {
            if(assets == type(uint256).max) {
                assets = collateralOf(owner);
                shares = _redeemableShares[owner];
            } else {
                shares = (assets * totalRedeemableShares) / totalRedeemable;
            }
            require(shares > 0, "Withdraw would result in zero shares");
            _redeemableShares[owner] -= shares;
            totalRedeemableShares -= shares;
            totalRedeemable -= assets;
        } else {
            if(assets == type(uint256).max) {
                assets = collateralOf(owner);
                shares = nonRedeemableShares[owner];
            } else {
                shares = (assets * totalNonRedeemableShares) / totalNonRedeemable;
            }
            require(shares > 0, "Withdraw would result in zero shares");
            nonRedeemableShares[owner] -= shares;
            totalNonRedeemableShares -= shares;
            totalNonRedeemable -= assets;
        }

        require(asset.transfer(receiver, assets), "Asset transfer failed");
    }

    function setRedeemable(address account, bool redeemable) public onlyUSD2 updateShares(account) {
        if(redeemable) { // become redeemable
            uint shares = nonRedeemableShares[account];
            if(shares > 0) {
                uint assets = convertToNonRedeemableAssets(shares);
                nonRedeemableShares[account] = 0;
                totalNonRedeemableShares -= shares;
                totalNonRedeemable -= assets;
                uint redeemableShares = totalRedeemableShares == 0 ? assets : (assets * totalRedeemableShares) / totalRedeemable;
                require(redeemableShares > 0, "Zero shares");
                totalRedeemable += assets;
                totalRedeemableShares += redeemableShares;
                _redeemableShares[account] += redeemableShares;
            }
            isRedeemable[account] = true;
        } else { // become non-redeemable
            uint shares = _redeemableShares[account];
            if(shares > 0) {
                uint assets = convertToRedeemableAssets(shares);
                require(assets > 0, "Zero shares");
                _redeemableShares[account] = 0;
                totalRedeemableShares -= shares;
                totalRedeemable -= assets;
                uint _nonRedeemableShares = totalNonRedeemableShares == 0 ? assets : (assets * totalNonRedeemableShares) / totalNonRedeemable;
                totalNonRedeemable += assets;
                totalNonRedeemableShares += _nonRedeemableShares;
                nonRedeemableShares[account] += _nonRedeemableShares;
            }
            isRedeemable[account] = false;
        }
    }

    function convertToRedeemableShares(uint256 assets) public view returns (uint256 shares) {
        return totalRedeemableShares == 0 ? assets : (assets * totalRedeemableShares) / totalRedeemable;
    }

    function convertToRedeemableAssets(uint256 shares) public view returns (uint256 assets) {
        return totalRedeemableShares == 0 ? shares : (shares * totalRedeemable) / totalRedeemableShares;
    }

    function convertToNonRedeemableShares(uint256 assets) public view returns (uint256 shares) {
        return totalNonRedeemableShares == 0 ? assets : (assets * totalNonRedeemableShares) / totalNonRedeemable;
    }

    function convertToNonRedeemableAssets(uint256 shares) public view returns (uint256 assets) {
        return totalNonRedeemableShares == 0 ? shares : (shares * totalNonRedeemable) / totalNonRedeemableShares;
    }

    function sync() public {
        uint256 currentBalance = asset.balanceOf(address(this));
        uint256 lastBalance = totalNonRedeemable + totalRedeemable;

        if (currentBalance > lastBalance) {
            uint256 excessBalance = currentBalance - lastBalance;

            // Calculate the proportional increase
            uint256 nonRedeemableShare = (totalNonRedeemable * excessBalance) / lastBalance;
            uint256 redeemableShare = excessBalance - nonRedeemableShare;

            totalNonRedeemable += nonRedeemableShare;
            totalRedeemable += redeemableShare;
        }
    }

    event Seize(address indexed to, uint256 assets);
    event Rebase(uint newMergeCount);
}