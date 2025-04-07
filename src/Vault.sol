// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "lib/solmate/src/tokens/ERC4626.sol";

interface ILender {
    function accrueInterest() external;
    function coin() external view returns (ERC20);
}

contract Vault is ERC4626 {

    ILender public immutable lender;

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
        return asset.balanceOf(address(this));
    }

    /// @notice Deposits assets into the vault
    /// @param assets Amount of assets to deposit
    /// @param receiver Address to receive the shares
    /// @return shares Amount of shares minted
    function deposit(uint256 assets, address receiver) public accrueInterest override returns (uint256 shares) {
        shares = super.deposit(assets, receiver);
    }

    /// @notice Mints shares of the vault
    /// @param shares Amount of shares to mint
    /// @param receiver Address to receive the shares
    /// @return assets Amount of assets deposited
    function mint(uint256 shares, address receiver) public accrueInterest override returns (uint256 assets) {
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

}