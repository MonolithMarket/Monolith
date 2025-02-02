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
    /// @notice Maximum fee that can be set (25%)
    uint public constant MAX_FEE_BPS = 2500;
    
    /// @notice Address authorized to modify contract parameters
    address public operator;
    
    /// @notice Address proposed to be the next operator
    address public pendingOperator;
    
    /// @notice Address that receives the collected fees
    address public feeRecipient;
    
    /// @notice Total assets held by the vault
    uint240 internal _totalAssets;
    
    /// @notice Current fee rate in basis points (1/10000)
    uint16 public feeBps;

    /// @param _name Name of the token. Prepended with "Staked "
    /// @param _symbol Symbol of the token. Prepended with "s"
    /// @param _operator Address of the initial operator
    /// @param _usd2 Address of the USD2 token
    constructor(
        string memory _name,
        string memory _symbol,
        address _operator,
        address _usd2
    ) ERC4626(
        ERC20(_usd2),
        string.concat("Staked ", _name),
        string.concat("s", _symbol)
    ) {
        operator = _operator;
    }

    /// @notice Sets the pending operator
    /// @param _pendingOperator Address of the proposed new operator
    /// @dev Only callable by current operator
    function setPendingOperator(address _pendingOperator) external {
        require(msg.sender == operator, "SUSD2: FORBIDDEN");
        pendingOperator = _pendingOperator;
    }

    /// @notice Allows pending operator to claim operatorship
    /// @dev Only callable by pending operator
    function claimOperator() external {
        require(msg.sender == pendingOperator, "SUSD2: FORBIDDEN");
        operator = pendingOperator;
        pendingOperator = address(0);
    }

    /// @notice Sets the fee recipient address
    /// @param _feeRecipient Address to receive fees
    /// @dev Only callable by operator
    function setFeeRecipient(address _feeRecipient) external {
        require(msg.sender == operator, "SUSD2: FORBIDDEN");
        feeRecipient = _feeRecipient;
    }

    /// @notice Updates the fee rate
    /// @param _feeBps New fee rate in basis points
    /// @dev Only callable by operator, accrues interest before changing fee
    function setFeeBps(uint _feeBps) external {
        accrueInterest(); // apply old fee before changing fee
        require(msg.sender == operator, "SUSD2: FORBIDDEN");
        require(_feeBps <= MAX_FEE_BPS, "SUSD2: INVALID_FEE");
        feeBps = uint16(_feeBps);
    }

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
        uint240 bal = uint240(asset.balanceOf(address(this)));
        if (bal > _totalAssets) {
            uint fee = (bal - _totalAssets) * feeBps / 10000;
            _totalAssets = bal;
            if(fee > 0 && feeRecipient != address(0)) {
                uint supply = totalSupply;
                uint shares = supply == 0 ? fee : fee.mulDivDown(supply, _totalAssets - fee);
                _mint(feeRecipient, shares);
            }
        }
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