// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title CollateralManager
/// @notice Manages redeemable and non-redeemable collateral shares for USD2
/// @dev Handles deposits, withdrawals, and redemption switching
contract CollateralManager {
    
    address public immutable usd2;
    IERC20 public immutable asset;
    uint256 public totalRedeemableShares;
    uint256 public totalRedeemable;
    uint256 public totalNonRedeemableShares;
    uint256 public totalNonRedeemable;
    mapping(address => uint256) public redeemableShares;
    mapping(address => uint256) public nonRedeemableShares;
    mapping(address => bool) public isRedeemable;

    uint256 public shareMergeCount;
    mapping(address => uint256) public lastShareMergeCount;

    /// @param _asset The address of the ERC20 token used as collateral
    constructor(address _asset) {
        asset = IERC20(_asset);
        usd2 = msg.sender;
    }

    /// @notice Restricts function access to only USD2 contract
    modifier onlyUSD2() {
        require(msg.sender == usd2, "Not authorized");
        _;
    }

    /// @notice Updates shares for an account in case there's been a share merge
    /// @param account The address whose shares are being updated
    modifier updateShares(address account) {
        redeemableShares[account] = redeemableSharesOf(account);
        lastShareMergeCount[account] = shareMergeCount;
        _;
    }

    /// @notice Calculates the current redeemable shares for an account
    /// @param account The address to check
    /// @return The number of redeemable shares after applying merge adjustments
    function redeemableSharesOf(address account) public view returns (uint256) {
        uint256 rawShares = redeemableShares[account];
        uint256 accountLastMergeCount = lastShareMergeCount[account];
        uint256 mergeDelta = shareMergeCount - accountLastMergeCount;
        if (mergeDelta > 0) {
            return rawShares / (10 ** (18 * mergeDelta));
        }
        return rawShares;
    }

    /// @notice Gets the total collateral amount for an account whether redeemable or not
    /// @param account The address to check
    /// @return The total collateral amount in asset tokens
    function collateralOf(address account) public view returns (uint256) {
        if(isRedeemable[account]) {
            return convertToRedeemableAssets(redeemableSharesOf(account));
        }
        return convertToNonRedeemableAssets(nonRedeemableShares[account]);
    }

    /// @notice Allows USD2 core to seize collateral during redemptions
    /// @param assets The amount of collateral to seize
    /// @param to The recipient address
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

    /// @notice Deposits collateral and mints shares. Collateral is non-redeemable by default
    /// @param receiver The address receiving the shares
    /// @return shares The number of shares minted
    function deposit(address receiver) public updateShares(receiver) returns (uint256 shares) {
        uint256 assets = asset.balanceOf(address(this)) - totalRedeemable - totalNonRedeemable;
        if(isRedeemable[receiver]) {
            shares = totalRedeemableShares == 0 ? assets : (assets * totalRedeemableShares) / totalRedeemable;
            require(shares > 0, "Deposit would result in zero shares");
            totalRedeemable += assets;
            totalRedeemableShares += shares;
            redeemableShares[receiver] += shares;
        } else {
            shares = totalNonRedeemableShares == 0 ? assets : (assets * totalNonRedeemableShares) / totalNonRedeemable;
            require(shares > 0, "Deposit would result in zero shares");
            totalNonRedeemable += assets;
            totalNonRedeemableShares += shares;
            nonRedeemableShares[receiver] += shares;
        }
        emit Deposit(receiver, shares, assets);
    }

    /// @notice Withdraws collateral by burning shares
    /// @param assets The amount of assets to withdraw
    /// @param receiver The address receiving the assets
    /// @param owner The owner of the shares
    /// @return shares The number of shares burned
    /// @dev Only callable by USD2 core. If assets is set to type(uint256).max, it will withdraw all owner's collateral
    function withdraw(uint256 assets, address receiver, address owner) public onlyUSD2 updateShares(owner) returns (uint256 shares) {
        if(isRedeemable[owner]) {
            shares = (assets * totalRedeemableShares) / totalRedeemable;
            require(shares > 0, "Withdraw would result in zero shares");
            redeemableShares[owner] -= shares;
            totalRedeemableShares -= shares;
            totalRedeemable -= assets;
        } else {
            shares = (assets * totalNonRedeemableShares) / totalNonRedeemable;
            require(shares > 0, "Withdraw would result in zero shares");
            nonRedeemableShares[owner] -= shares;
            totalNonRedeemableShares -= shares;
            totalNonRedeemable -= assets;
        }

        require(asset.transfer(receiver, assets), "Asset transfer failed");
        emit Withdraw(owner, receiver, shares, assets);
    }

    /// @notice Toggles an account's redeemable status and converts collateral shares accordingly
    /// @param account The address to modify
    /// @param redeemable The new redeemable status (true for redeemable, false for non-redeemable)
    /// @dev Only callable by USD2 core
    function setRedeemable(address account, bool redeemable) public onlyUSD2 updateShares(account) {
        if(redeemable) { // become redeemable
            uint shares = nonRedeemableShares[account];
            if(shares > 0) {
                uint assets = convertToNonRedeemableAssets(shares);
                nonRedeemableShares[account] = 0;
                totalNonRedeemableShares -= shares;
                totalNonRedeemable -= assets;
                uint _redeemableShares = totalRedeemableShares == 0 ? assets : (assets * totalRedeemableShares) / totalRedeemable;
                require(_redeemableShares > 0, "Zero shares");
                totalRedeemable += assets;
                totalRedeemableShares += _redeemableShares;
                redeemableShares[account] += _redeemableShares;
            }
            isRedeemable[account] = true;
        } else { // become non-redeemable
            uint shares = redeemableShares[account];
            if(shares > 0) {
                uint assets = convertToRedeemableAssets(shares);
                require(assets > 0, "Zero shares");
                redeemableShares[account] = 0;
                totalRedeemableShares -= shares;
                totalRedeemable -= assets;
                uint _nonRedeemableShares = totalNonRedeemableShares == 0 ? assets : (assets * totalNonRedeemableShares) / totalNonRedeemable;
                totalNonRedeemable += assets;
                totalNonRedeemableShares += _nonRedeemableShares;
                nonRedeemableShares[account] += _nonRedeemableShares;
            }
            isRedeemable[account] = false;
        }
        emit RedeemableStatusChanged(account, redeemable);
    }

    /// @notice Converts asset amount to redeemable shares
    /// @param assets The amount of assets to convert
    /// @return shares The equivalent amount of redeemable shares
    function convertToRedeemableShares(uint256 assets) public view returns (uint256 shares) {
        return totalRedeemableShares == 0 ? assets : (assets * totalRedeemableShares) / totalRedeemable;
    }

    /// @notice Converts redeemable shares to asset amount
    /// @param shares The amount of shares to convert
    /// @return assets The equivalent amount of assets
    function convertToRedeemableAssets(uint256 shares) public view returns (uint256 assets) {
        return totalRedeemableShares == 0 ? shares : (shares * totalRedeemable) / totalRedeemableShares;
    }

    /// @notice Converts asset amount to non-redeemable shares
    /// @param assets The amount of assets to convert
    /// @return shares The equivalent amount of non-redeemable shares
    function convertToNonRedeemableShares(uint256 assets) public view returns (uint256 shares) {
        return totalNonRedeemableShares == 0 ? assets : (assets * totalNonRedeemableShares) / totalNonRedeemable;
    }

    /// @notice Converts non-redeemable shares to asset amount
    /// @param shares The amount of shares to convert
    /// @return assets The equivalent amount of assets
    function convertToNonRedeemableAssets(uint256 shares) public view returns (uint256 assets) {
        return totalNonRedeemableShares == 0 ? shares : (shares * totalNonRedeemable) / totalNonRedeemableShares;
    }

    /// @notice Emitted when collateral is seized
    /// @param to The address receiving the seized assets
    /// @param assets The amount of assets seized
    event Seize(address indexed to, uint256 assets);

    /// @notice Emitted when shares are merged/rebased
    /// @param newMergeCount The new merge count after the rebase
    event Rebase(uint newMergeCount);

    /// @notice Emitted when collateral is deposited
    /// @param receiver The address receiving the shares
    /// @param shares The number of shares deposited
    /// @param assets The amount of assets deposited
    event Deposit(address indexed receiver, uint256 shares, uint256 assets);

    /// @notice Emitted when collateral is withdrawn
    /// @param owner The owner of the shares
    /// @param receiver The address receiving the assets
    /// @param shares The number of shares withdrawn
    /// @param assets The amount of assets withdrawn
    event Withdraw(address indexed owner, address indexed receiver, uint256 shares, uint256 assets);

    /// @notice Emitted when redeemable status is changed
    /// @param account The address whose redeemable status is changed
    /// @param redeemable The new redeemable status
    event RedeemableStatusChanged(address indexed account, bool redeemable);
}