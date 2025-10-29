// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import "lib/solmate/src/tokens/ERC4626.sol";

interface ILender {
    function accrueInterest() external;
    function coin() external view returns (ERC20);
    function getPendingInterest() external view returns (uint256 pendingVaultInterest);
}

contract Vault is ERC4626 {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;
    
    ILender public immutable lender;
    uint256 constant MIN_SHARES = 1e16; // 1 cent;

    /// @param _name Name of the token. Prepended with "Staked "
    /// @param _symbol Symbol of the token. Prepended with "s"
    /// @param _lender Address of the Lender token
    constructor(
        string memory _name,
        string memory _symbol,
        address _lender
    ) ERC4626(
        ILender(_lender).coin(),
        string.concat("Staked ", _name),
        string.concat("s", _symbol)
    ) {
        lender = ILender(_lender);
    }

    modifier accrueInterest() {
        lender.accrueInterest();
        _;
    }

    function totalAssets() public view override returns (uint256) {
        return asset.balanceOf(address(this)) + lender.getPendingInterest();
    }

    /// @notice Deposits assets into the vault
    /// @param assets Amount of assets to deposit
    /// @param receiver Address to receive the shares
    /// @return shares Amount of shares minted
    function deposit(uint256 assets, address receiver) public accrueInterest override returns (uint256 shares) {
        bool isFirstDeposit = totalSupply == 0;
       
        // Check for rounding error since we round down in previewDeposit.
        require((shares = convertToShares(assets)) != 0, "ZERO_SHARES");

        // Need to transfer before minting or ERC777s could reenter.
        asset.safeTransferFrom(msg.sender, address(this), assets);

        _mint(receiver, shares);
        
        emit Deposit(msg.sender, receiver, assets, shares);

        if(isFirstDeposit) {
                // if this underflows, the first deposit is less than MIN_SHARES which is not allowed
                balanceOf[receiver] -= MIN_SHARES;
                balanceOf[address(0)] += MIN_SHARES;
                shares -= MIN_SHARES;
                emit Transfer(receiver, address(0), MIN_SHARES);
        }
        
    }

    /// @notice Mints shares of the vault
    /// @dev Includes MIN_SHARES deduction on first deposit, meaning it will pull more assets to burn the MIN_SHARES on first deposit
    /// @param shares Amount of shares to mint
    /// @param receiver Address to receive the shares
    /// @return assets Amount of assets deposited
    function mint(uint256 shares, address receiver) public accrueInterest override returns (uint256 assets) {
        // Get the amount of assets required including amount to burn MIN_SHARES if first deposit
        assets = previewMint(shares); 
        // Need to transfer before minting or ERC777s could reenter.
        asset.safeTransferFrom(msg.sender, address(this), assets);

        bool isFirstDeposit = totalSupply == 0;
        
        if(isFirstDeposit) {
            _mint(receiver, shares + MIN_SHARES);
            // if this underflows, the first deposit is less than MIN_SHARES which is not allowed
            balanceOf[receiver] -= MIN_SHARES;
            balanceOf[address(0)] += MIN_SHARES;
            emit Transfer(receiver, address(0), MIN_SHARES);
        } else {
            _mint(receiver, shares);  
        }

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Withdraws assets from the vault
    /// @param assets Amount of assets to withdraw
    /// @param receiver Address to receive the assets
    /// @param owner Owner of the shares
    /// @return shares Amount of shares burned
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public accrueInterest override returns (uint256 shares) {
        shares = super.withdraw(assets, receiver, owner);
    }

    /// @notice Redeems shares for assets
    /// @param shares Amount of shares to redeem
    /// @param receiver Address to receive the assets
    /// @param owner Owner of the shares
    /// @return assets Amount of assets withdrawn
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public accrueInterest override returns (uint256 assets) {
        assets = super.redeem(shares, receiver, owner);
    }

    /// @notice Preview deposit to account for MIN_SHARES deduction on first deposit
    /// @param assets Amount of assets to deposit
    /// @return shares Amount of shares that will be minted to the user
    function previewDeposit(uint256 assets) public view override returns (uint256 shares) {
        shares = convertToShares(assets);
        if (totalSupply == 0) {
            // Avoid reverting to conforme with ERC4626 spec
            if (shares < MIN_SHARES) {
                shares = 0;
            } else shares -= MIN_SHARES;

        }
    }

    /// @notice Preview mint to account for MIN_SHARES deduction on first deposit
    /// @param shares Amount of shares to mint
    /// @return assets Amount of assets that will be deposited (accounting for MIN_SHARES on first deposit)
    function previewMint(uint256 shares) public view override returns (uint256 assets) {
        // If this is the first deposit, we need to mint MIN_SHARES extra
        if (totalSupply == 0) shares += MIN_SHARES;
        
        uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.

        return supply == 0 ? shares : shares.mulDivUp(totalAssets(), supply);
    }
}