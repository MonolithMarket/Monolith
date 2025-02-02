// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "lib/solmate/src/tokens/ERC4626.sol";
import "lib/solmate/src/utils/FixedPointMathLib.sol";

/// @title USD2 Interface
/// @notice Interface for USD2 token's interest accrual functionality
interface IUSD2 {
    function accrueInterest() external;
}

/// @title Staked USD2 (sUSD2)
/// @notice A tokenized vault for USD2, implementing the ERC4626 standard
/// @dev Allows staking of USD2 tokens with fee collection mechanism
contract SUSD2 is ERC4626 {
    using FixedPointMathLib for uint256;
    
    /// @notice Total assets held by the vault
    uint240 internal _totalAssets;

    /// @param _name Name of the token. Prepended with "Staked "
    /// @param _symbol Symbol of the token. Prepended with "s"
    /// @param _usd2 Address of the USD2 token
    constructor(
        string memory _name,
        string memory _symbol,
        address _usd2
    ) ERC4626(
        ERC20(_usd2),
        string.concat("Staked ", _name),
        string.concat("s", _symbol)
    ) {}

    /// @notice Hook called before assets are withdrawn
    /// @param assets Amount of assets being withdrawn
    function beforeWithdraw(uint256 assets, uint256) internal override {
        _totalAssets -= uint240(assets);
    }

    /// @notice Hook called after assets are deposited
    /// @param assets Amount of assets being deposited
    function afterDeposit(uint256 assets, uint256) internal override {
        _totalAssets += uint240(assets);
    }

    /// @notice Accrues interest and collects fees
    /// @dev Mints shares to fee recipient if there are fees to collect
    function accrueInterest() public {
        IUSD2(address(asset)).accrueInterest();
    }

    /// @notice Returns the total amount of assets in the vault
    /// @return Total assets
    function totalAssets() public view override returns (uint256) {
        return _totalAssets;
    }

    /// @notice Deposits assets into the vault
    /// @param assets Amount of assets to deposit
    /// @param receiver Address to receive the shares
    /// @return shares Amount of shares minted
    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        accrueInterest();
        shares = super.deposit(assets, receiver);
    }

    /// @notice Mints shares of the vault
    /// @param shares Amount of shares to mint
    /// @param receiver Address to receive the shares
    /// @return assets Amount of assets deposited
    function mint(uint256 shares, address receiver) public override returns (uint256 assets) {
        accrueInterest();
        assets = super.mint(shares, receiver);
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
    ) public override returns (uint256 shares) {
        accrueInterest();
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
    ) public override returns (uint256 assets) {
        accrueInterest();
        assets = super.redeem(shares, receiver, owner);
    }
}