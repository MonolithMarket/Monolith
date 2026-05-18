// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import "lib/solmate/src/tokens/ERC20.sol";
import "lib/solmate/src/tokens/ERC4626.sol";
import "lib/solmate/src/utils/SafeTransferLib.sol";
import "lib/solmate/src/utils/FixedPointMathLib.sol";
import "./Coin.sol";
import "./Vault.sol";
import "./InterestModel.sol";

interface IChainlinkFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

interface IFactory {
    function getFeeOf(address _lender) external view returns (uint256);
    function minDebtFloor() external view returns (uint256);
}

contract Lender {

    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    // single 256-bit slot
    uint16 public targetPsmDebtRatioStartBps; // max uint16 is 65535 bps which is outside of the range [0, 10000]
    uint16 public targetPsmDebtRatioEndBps; // max uint16 is 65535 bps which is outside of the range [0, 10000]
    bool public eventTriggerMode;
    uint64 public expRate; // max result is 693147180559945309 which is within uint64 range
    uint40 public lastAccrue; // max uint40 is year 36812
    uint88 public lastBorrowRateMantissa = uint88(2e16); // max uint88 is equivalent to 309485000% APR
    uint16 public feeBps; // max uint16 is 65535 bps which is outside of the range [0, 10000]
    

    // single 256-bit slot
    uint16 public cachedGlobalFeeBps;
    uint120 public accruedLocalReserves;
    uint120 public accruedGlobalReserves;

    // Other state variables
    address public operator;
    address public pendingOperator;
    uint public immutabilityDeadline; // may only be reduced by operator
    uint public totalPaidDebt;
    uint public totalPaidDebtShares;
    uint public freePsmAssets;
    uint16 public maxBorrowDeltaBps; // max acceptable rounding error in bps when borrowing (e.g., 200 = 2%)
    
    // Constants and immutables
    Coin public immutable coin;
    ERC20 public immutable collateral;
    ERC20 public immutable psmAsset;
    ERC4626 public immutable psmVault;
    IChainlinkFeed public immutable feed;
    Vault public immutable vault;
    InterestModel public immutable interestModel;
    IFactory public immutable factory;
    address public immutable eventTriggerOperator;
    uint public immutable collateralFactor;
    uint public immutable minDebt;
    uint public immutable deployTimestamp;
    uint public immutable psmAssetDecimals;
    uint public immutable collateralDecimals;
    uint public immutable stalenessThreshold; 
    uint public immutable psmVaultMinTotalSupply;

    uint public constant STALENESS_UNWIND_DURATION = 24 hours;
    uint public constant MIN_LIQUIDATION_DEBT = 10_000e18; // 10,000 Coin
    uint public constant MAX_DECIMALS = 30; // Maximum allowed token decimals
    
    // For accrueInterest() try-catch
    uint256 private constant INTEREST_CALCULATION_GAS_REQUIREMENT = 40_000;
    // For writeOff() try-catch in liquidate() 
    uint256 private constant WRITEOFF_GAS_REQUIREMENT = 120_000;

    // Mappings
    mapping(address => uint) public collateralBalances; // stored in collateral token native decimals
    mapping(address => uint) public paidDebtShares;
    mapping(address => mapping(address => bool)) public delegations;

    address public manager;

    struct LenderParams {
        ERC20 collateral;
        ERC20 psmAsset; // optional
        ERC4626 psmVault; // optional
        IChainlinkFeed feed;
        Coin coin;
        Vault vault;
        InterestModel interestModel;
        IFactory factory;
        address operator;
        address manager;
        address eventTriggerOperator;
        uint collateralFactor;
        uint minDebt;
        uint timeUntilImmutability;
        uint64 halfLife;
        uint16 targetPsmDebtRatioStartBps;
        uint16 targetPsmDebtRatioEndBps;
        uint32 stalenessThreshold;
        uint16 maxBorrowDeltaBps;
        uint128 psmVaultMinTotalSupply;
    }

    constructor(LenderParams memory params) {
        require(params.collateralFactor <= 8500, "Invalid collateral factor");
        require(params.timeUntilImmutability <= 1460 days, "Max immutability deadline is in 4 years");
        require(params.halfLife >= 12 hours && params.halfLife <= 30 days, "Invalid half life");
        require(params.targetPsmDebtRatioStartBps >= 500 && params.targetPsmDebtRatioStartBps <= params.targetPsmDebtRatioEndBps, "Invalid start bps");
        require(params.targetPsmDebtRatioEndBps <= 9500, "Invalid end bps");
        require(params.maxBorrowDeltaBps <= 200 && params.maxBorrowDeltaBps >= 50, "Invalid max borrow delta bps"); // Max 2%
        uint minDebtFloor = IFactory(params.factory).minDebtFloor();
        require(params.minDebt >= minDebtFloor, "Invalid min debt");
        require(address(params.psmAsset) != address(params.coin), "PSM Asset must be different than Coin");
        require(params.eventTriggerOperator != address(0), "Invalid event trigger operator");
        require(params.eventTriggerOperator != params.operator, "Event trigger operator cannot be operator");
       
        if(params.psmVault != ERC4626(address(0))) {
            require(params.psmVault.asset() == params.psmAsset, "PSM asset mismatch");
            require(params.psmVaultMinTotalSupply > 0, "Invalid PSM vault min total supply");
        }
        
        // Validate collateral decimals
        uint256 _collateralDecimals = params.collateral.decimals();
        require(_collateralDecimals <= MAX_DECIMALS, "Collateral decimals exceed maximum");
        collateralDecimals = _collateralDecimals;
        
        collateral = params.collateral;
        psmAsset = params.psmAsset;
        psmVault = params.psmVault;
        feed = params.feed;
        coin = params.coin;
        vault = params.vault;
        interestModel = params.interestModel;
        factory = params.factory;
        operator = params.operator;
        manager = params.manager;
        eventTriggerOperator = params.eventTriggerOperator;
        collateralFactor = params.collateralFactor;
        minDebt = params.minDebt;
        deployTimestamp = block.timestamp;
        immutabilityDeadline = block.timestamp + params.timeUntilImmutability;
        lastAccrue = uint40(block.timestamp);
        expRate = uint64(uint(wadLn(2*1e18)) / params.halfLife);
        targetPsmDebtRatioStartBps = params.targetPsmDebtRatioStartBps;
        targetPsmDebtRatioEndBps = params.targetPsmDebtRatioEndBps;
        maxBorrowDeltaBps = params.maxBorrowDeltaBps;
        stalenessThreshold = params.stalenessThreshold;
        psmVaultMinTotalSupply = params.psmVaultMinTotalSupply;
        cachedGlobalFeeBps = uint16(factory.getFeeOf(address(this)));
        if(psmVault != ERC4626(address(0)))
            psmAsset.safeApprove(address(psmVault), type(uint).max);
        uint256 _psmAssetDecimals;
        if (psmAsset != ERC20(address(0))) {
            _psmAssetDecimals = psmAsset.decimals();
        } 
        psmAssetDecimals = _psmAssetDecimals;
    }

    // Modifiers

    modifier onlyOperator() {
        require(msg.sender == operator, "Unauthorized");
        _;
    }

    modifier onlyOperatorOrManager() {
        require(msg.sender == operator || msg.sender == manager, "Unauthorized");
        _;
    }

    modifier beforeDeadline() {
        require(block.timestamp < immutabilityDeadline, "Deadline passed");
        _;
    }

    // Public functions

    function accrueInterest() public {
        uint timeElapsed = block.timestamp - lastAccrue;
        if(timeElapsed == 0) return;
        if(eventTriggerMode) {
            lastAccrue = uint40(block.timestamp);
            return;
        }

        uint256 gasBefore = gasleft();

        try interestModel.calculateInterest(
            totalPaidDebt,
            lastBorrowRateMantissa,
            timeElapsed,
            expRate,
            getPsmDebtRatio(),
            targetPsmDebtRatioStartBps,
            targetPsmDebtRatioEndBps
        ) returns (uint currBorrowRate, uint interest) {
            uint120 localReserveFee = uint120(interest * feeBps / 10000);
            uint120 globalReserveFee = uint120(interest * cachedGlobalFeeBps / 10000);
            accruedLocalReserves += localReserveFee;
            accruedGlobalReserves += globalReserveFee;
            // we remove reserve fees from interest before calculating how much to give to stakers
            uint interestAfterFees = interest - localReserveFee - globalReserveFee;
            uint totalStaked = coin.balanceOf(address(vault));
            if(totalStaked < totalPaidDebt) { // this also implies totalPaidDebt > 0 and guards the division below
                // if total staked is less than paid debt, giving all interest to stakers would
                // result in higher supply rate than borrow rate which is undesirable.
                // we cap the supply rate at the borrow rate and give the rest to local reserves.
                uint stakedInterest = interestAfterFees * totalStaked / totalPaidDebt;
                coin.mint(address(vault), stakedInterest);
                uint remainingInterest = interestAfterFees - stakedInterest;
                accruedLocalReserves += uint120(remainingInterest);
            } else {
                // if total staked is greater than paid debt, we give all interest to stakers
                coin.mint(address(vault), interestAfterFees);
            }
            totalPaidDebt += interest; // we add all interest to paid debt (NOT interestAfterFees)
            lastAccrue = uint40(block.timestamp);
            lastBorrowRateMantissa = uint88(currBorrowRate);
            cachedGlobalFeeBps = uint16(factory.getFeeOf(address(this)));
            emit InterestAccrued(interest, currBorrowRate);
        } catch {
            // If the call failed, check if sufficient gas was provided
            // We need to ensure the caller provided enough gas for accrueInterest to execute
            require(gasBefore >= INTEREST_CALCULATION_GAS_REQUIREMENT, "Not enough gas for accrueInterest");
        }
    }

    function adjust(address account, int collateralDelta, int debtDelta) public {
        accrueInterest();
        // Handle collateral changes
        if (collateralDelta > 0) {
            uint256 collateralAmount = uint(collateralDelta);
            collateralBalances[account] += collateralAmount;
            // Transfer actual token amount
            collateral.safeTransferFrom(msg.sender, address(this), collateralAmount);
        } else if (collateralDelta < 0) {
            uint256 collateralAmount = uint(-collateralDelta);
            collateralBalances[account] -= collateralAmount;
            collateral.safeTransfer(msg.sender, collateralAmount);
        }

        // Handle debt changes
        int actualDebtDelta = debtDelta;
        if (debtDelta > 0) {
            require(!eventTriggerMode, "Event trigger mode active");
            // Borrow
            uint amount = uint256(debtDelta);
            increaseDebt(account, amount);
            coin.mint(msg.sender, amount);
        } else if (debtDelta < 0) {
            // Repay
            uint amount = uint256(-debtDelta);
            uint debt = getDebtOf(account);
            if(debt <= amount) {
                amount = debt;
                actualDebtDelta = -int(debt); // Use actual debt repaid for full repayment
                decreaseDebt(account, type(uint).max);
            } else {
                decreaseDebt(account, amount);
            }
            coin.transferFrom(msg.sender, address(this), amount);
            coin.burn(amount);
        }

        // if debtDelta is non-zero, require debt balance to either be 0 or >= minDebt
        uint debtBalance = getDebtOf(account);
        if(debtDelta != 0) require(debtBalance == 0 || debtBalance >= minDebt, "Debt below minimum and larger than 0");

        // Emit event before the first early return
        emit PositionAdjusted(account, collateralDelta, actualDebtDelta);

        // Skip remaining invariants if caller does not reduce collateral AND does not increase debt
        if(collateralDelta >= 0 && debtDelta <= 0) return;

        // The caller is removing collateral and/or increasing debt. Enforce ownership beyond this point
        require(msg.sender == account || delegations[account][msg.sender], "Unauthorized");

        // After the event trigger, borrowers may withdraw collateral without repaying debt.
        if(eventTriggerMode) return;

        // Skip solvency checks if debt is zero
        if(debtBalance == 0) return;

        // Check solvency
        (uint price, bool reduceOnly, ) = getCollateralPrice();
        require(!reduceOnly, "Reduce only");
        uint borrowingPower = price * collateralBalances[account] * collateralFactor / 1e18 / 10000;
        require(debtBalance <= borrowingPower, "Solvency check failed");
    }

    /// @notice Allows an account to delegate control of position management to another address
    /// @dev Delegatees can call adjust().
    /// @param delegatee The address to delegate to
    /// @param isDelegatee True to enable delegation, false to revoke
    function delegate(address delegatee, bool isDelegatee) external {
        delegations[msg.sender][delegatee] = isDelegatee;
        emit DelegationUpdated(msg.sender, delegatee, isDelegatee);
    }

    /// @notice Liquidates an unsafe position
    /// @param borrower The account to be liquidated
    /// @param repayAmount The amount of debt to repay
    /// @param minCollateralOut The minimum amount of collateral to receive (in token decimals)
    /// @return The amount of collateral received (in token decimals)
    function liquidate(address borrower, uint repayAmount, uint minCollateralOut) external returns(uint) {
        accrueInterest();
        require(!eventTriggerMode, "Event trigger mode active");
        require(repayAmount > 0, "Repay amount must be greater than 0");
        (uint price,, bool allowLiquidations) = getCollateralPrice();
        require(allowLiquidations, "liquidations disabled");
        uint debt = getDebtOf(borrower);
        uint collateralBalance = collateralBalances[borrower]; // in collateral token decimals
        // check liquidation condition
        uint liquidatableDebt = getLiquidatableDebt(collateralBalance, price, debt);
        require(liquidatableDebt > 0, "insufficient liquidatable debt");
        if(repayAmount > liquidatableDebt) {
            repayAmount = liquidatableDebt;
        }

        uint liqIncentiveBps = getLiquidationIncentiveBps(collateralBalance, price, debt);
        uint maxRepayByCollateral = getMaxRepayByCollateral(collateralBalance, price, liqIncentiveBps);
        if(repayAmount > maxRepayByCollateral) {
            repayAmount = maxRepayByCollateral;
        }
        require(repayAmount > 0, "insufficient collateral out");

        // apply repayment
        decreaseDebt(borrower, repayAmount);

        // calculate collateral reward (in collateral token decimals)
        uint collateralRewardValue = repayAmount * (10000 + liqIncentiveBps) / 10000;
        uint collateralReward = repayAmount == maxRepayByCollateral ? collateralBalance : collateralRewardValue * 1e18 / price;
        
        require(collateralReward >= minCollateralOut, "insufficient collateral out");

        if(collateralReward > 0) {
            collateralBalances[borrower] = collateralBalance - collateralReward;
            collateral.safeTransfer(msg.sender, collateralReward);
        }
        coin.transferFrom(msg.sender, address(this), repayAmount);
        coin.burn(repayAmount);
        emit Liquidated(borrower, msg.sender, repayAmount, collateralReward);
        
        uint256 gasBefore = gasleft();
        // try to write off remaining debt. Call externally and catch error to prevent liquidation failure
        try this.writeOff(borrower, msg.sender) {} catch {
            // If the call failed, check if sufficient gas was provided
            // We need to ensure the caller provided enough gas for writeOff to execute
            require(gasBefore >= WRITEOFF_GAS_REQUIREMENT, "Not enough gas for writeOff");
        }
        return collateralReward;
    }

    /// @notice Redistributes excess debt of undercollateralized accounts among other borrowers
    /// @param borrower The account in potentiallyundercollateralized state
    /// @return writtenOff True if the borrower was written off, false otherwise
    /// @param to The address to send the collateral to
    /// @dev This function is called by liquidate() when a borrower's position is undercollateralized. It should never revert to avoid liquidation failure.
    function writeOff(address borrower, address to) external returns (bool writtenOff) {
        accrueInterest();
        require(!eventTriggerMode, "Event trigger mode active");
        // check for write off
        uint debt = getDebtOf(borrower);
        if(debt > 0) {
            uint collateralBalance = collateralBalances[borrower]; // in collateral token decimals
            (uint price,, bool allowLiquidations) = getCollateralPrice();
            require(allowLiquidations, "liquidations disabled");
            uint collateralValue = price * collateralBalance / 1e18;
            // if debt is more than 100 times the collateral value, write off
            if(debt > collateralValue * 100) {
                // 1. delete all of the borrower's debt
                decreaseDebt(borrower, type(uint).max);
                // 2. redistribute excess debt among remaining borrowers
                if (totalPaidDebt > 0) totalPaidDebt += debt;

                collateralBalances[borrower] = 0;
                
                emit WrittenOff(borrower, to, debt, collateralBalance);
                writtenOff = true;
                
                collateral.safeTransfer(to, collateralBalance);
            }
        }
    }

    function sell(uint coinIn, uint minAssetOut) external returns (uint assetOut) {
        require(psmAsset != ERC20(address(0)), "PSM asset was not set");
        accrueInterest();
        assetOut = getSellAmountOut(coinIn);
        require(assetOut >= minAssetOut, "insufficient amount out");
        // get and burn coins from caller
        coin.transferFrom(msg.sender, address(this), coinIn);
        coin.burn(coinIn);
        // give assets to caller
        if(psmVault != ERC4626(address(0))) {
            // Convert to shares out without taking into account vault withdrawal losses.
            uint256 sharesOut = psmVault.convertToShares(assetOut);
            uint256 actualAssetOutToSeller = psmVault.redeem(sharesOut, msg.sender, address(this));
            freePsmAssets -= assetOut;
            require(actualAssetOutToSeller >= minAssetOut, "redeem failed");
            assetOut = actualAssetOutToSeller;
        } else {
            freePsmAssets -= assetOut;
            psmAsset.safeTransfer(msg.sender, assetOut);
        }
        emit Sold(msg.sender, coinIn, assetOut);
    }

    function buy(uint assetIn, uint minCoinOut) external returns (uint coinOut) {
        require(psmAsset != ERC20(address(0)), "PSM asset was not set");
        accrueInterest();

        // get assets from caller
        psmAsset.safeTransferFrom(msg.sender, address(this), assetIn);
        if(psmVault != ERC4626(address(0))) {
            require(psmVault.totalSupply() > psmVaultMinTotalSupply, "PSM vault total supply below minimum");
            uint256 shares = psmVault.deposit(assetIn, address(this));
            require(shares > 0, "PSM deposit failed");
            uint256 assetsReceived = previewRedeemOrConvertToAssets(shares);
            freePsmAssets += assetsReceived;
            coinOut = getBuyAmountOut(assetsReceived);
        } else {
            freePsmAssets += assetIn;
            coinOut = getBuyAmountOut(assetIn);
        }
        require(coinOut >= minCoinOut, "insufficient amount out");
        // give coins to caller
        coin.mint(msg.sender, coinOut);
        emit Bought(msg.sender, assetIn, coinOut);
    }

    function reapprovePsmVault() external {
        if(psmVault != ERC4626(address(0))){
            //Zero approve to support USDT. Thank you Tabboz
            psmAsset.safeApprove(address(psmVault), 0);
            psmAsset.safeApprove(address(psmVault), type(uint).max);
        }
    }

    // Internal functions

    function accruePsmProfit() internal {
        if(address(psmVault) != address(0)){
            uint assets = previewRedeemOrConvertToAssets(psmVault.balanceOf(address(this)));
            if(assets <= freePsmAssets) return; // avoids underflow in case of loss
            uint profit = assets - freePsmAssets;
            accruedLocalReserves += uint120(normalizePsmAssets(profit));
            freePsmAssets = assets;
        } else if(psmAsset != ERC20(address(0))) {
            // we do this in case the underlying asset may be a rebasing token that accrues profit
            uint bal = psmAsset.balanceOf(address(this));
            if(bal <= freePsmAssets) return; // avoids underflow in case of loss
            uint profit = bal - freePsmAssets;
            accruedLocalReserves += uint120(normalizePsmAssets(profit));
            freePsmAssets = bal;
        }
    }

    function previewRedeemOrConvertToAssets(uint shares) internal view returns (uint assets) {
        try psmVault.previewRedeem(shares) returns (uint previewAssets) {
            return previewAssets;
        } catch {
            return psmVault.convertToAssets(shares);
        }
    }

    function increaseDebt(address account, uint256 amount) internal {
        uint256 shares = totalPaidDebt == 0 ? amount : amount.mulDivUp(totalPaidDebtShares, totalPaidDebt);
        
        // Update state first
        totalPaidDebt += amount;
        totalPaidDebtShares += shares;
        paidDebtShares[account] += shares;
        
        // Calculate actual debt increase after share conversion (in the new state)
        uint256 actualDebtIncrease = shares.mulDivUp(totalPaidDebt, totalPaidDebtShares);
        // Enforce max-delta guard: actual debt must not exceed requested by more than maxBorrowDeltaBps
        uint256 maxAllowedDebtIncrease = amount * (10000 + maxBorrowDeltaBps) / 10000;
        require(actualDebtIncrease <= maxAllowedDebtIncrease, "Borrow delta exceeds max");
    }

    function decreaseDebt(address account, uint256 amount) internal {
        uint256 shares;
        if(amount == type(uint).max) {
            shares = paidDebtShares[account];
            amount = getDebtOf(account);
        } else {
            shares = amount.mulDivDown(totalPaidDebtShares, totalPaidDebt);
        }
        
        paidDebtShares[account] -= shares;
        totalPaidDebtShares = totalPaidDebtShares <= shares ? 0 : totalPaidDebtShares - shares; // prevent underflow
        totalPaidDebt = totalPaidDebt <= amount ? 0 : totalPaidDebt - amount; // prevent underflow
    }

    function getLiquidatableDebt(uint collateralBalance, uint price, uint debt) internal view returns(uint liquidatableDebt){
        uint borrowingPower = price * collateralBalance * collateralFactor / 1e18 / 10000;
        if(borrowingPower >= debt) return 0;
        // liquidate 25% of the total debt
        liquidatableDebt = debt / 4; // 25% of the debt
        // liquidate at least MIN_LIQUIDATION_DEBT (or the entire debt if it's less than MIN_LIQUIDATION_DEBT)
        if(liquidatableDebt < MIN_LIQUIDATION_DEBT) liquidatableDebt = debt < MIN_LIQUIDATION_DEBT ? debt : MIN_LIQUIDATION_DEBT;
    }

    function getMaxRepayByCollateral(uint collateralBalance, uint price, uint liqIncentiveBps) internal pure returns(uint) {
        uint collateralValue = collateralBalance * price / 1e18;
        return collateralValue * 10000 / (10000 + liqIncentiveBps);
    }

    function getLiquidationIncentiveBps(uint collateralBalance, uint price, uint debt) internal view returns(uint) {
        uint collateralValue = collateralBalance * price / 1e18;
        if (collateralValue == 0) return 0; // avoid division by zero, return 0% incentive
        uint ltvBps = debt * 10000 / collateralValue;
        uint _collateralFactor = collateralFactor; // gas optimization
        uint maxLtvBps = _collateralFactor + 500; // range is [_collateralFactor, _collateralFactor + 5%]

        if (ltvBps <= _collateralFactor) {
            return 0; // 0% incentive
        } else if (ltvBps >= maxLtvBps) {
            return 1000; // 10% incentive
        } else {
            // linear interpolation between 0% and 10% incentive
            return (ltvBps - _collateralFactor) * 1000 / (maxLtvBps - _collateralFactor);
        }
    }

    // Getters

    function getPsmDebtRatio() public view returns (uint) {
        uint psmLiquidity = normalizePsmAssets(freePsmAssets);
        uint totalSupply = totalPaidDebt + psmLiquidity;
        return totalSupply == 0 ? 0 : psmLiquidity * 10000 / totalSupply;
    }

    function getDebtOf(address account) public view returns (uint) {
        return totalPaidDebtShares == 0 ? 0 : paidDebtShares[account].mulDivUp(totalPaidDebt, totalPaidDebtShares);
    }

    /// @notice Gets the current price of the collateral asset
    /// @return price The price in USD normalized to (36 - collateral decimals) decimals
    /// @return reduceOnly A boolean indicating if reduce only mode is enabled
    /// @return allowLiquidations A boolean indicating if liquidations and write-offs are enabled
    function getCollateralPrice() public view returns (uint price, bool reduceOnly, bool allowLiquidations) {
        uint updatedAt;
        allowLiquidations = true; // Default to allowing liquidations
        
        // call our own getFeedPrice() externally to catch all feed reverts e.g. due to inexistent feed contract, function, etc.
        try this.getFeedPrice() returns (uint _price, uint _updatedAt) {
            price = _price;
            updatedAt = _updatedAt;
            if(price == 0) {
                reduceOnly = true;
                allowLiquidations = false; // Disable liquidations if price is invalid
            }
        } catch {
            reduceOnly = true;
            allowLiquidations = false; // Disable liquidations only if the oracle feed is reverting
        }
        
        uint currentTime = block.timestamp;
        uint timeElapsed = currentTime >= updatedAt ? currentTime - updatedAt : 0;

        if (timeElapsed > stalenessThreshold) {
            reduceOnly = true;
            uint stalenessDuration = timeElapsed - stalenessThreshold;
            if (stalenessDuration < STALENESS_UNWIND_DURATION) {
                price = price * (STALENESS_UNWIND_DURATION - stalenessDuration) / STALENESS_UNWIND_DURATION;
            } else {
                price = 0;
            }
        }
        price = price == 0 ? 1 : price; // avoid division by zero in consumer functions
        uint totalCollateralValue = collateral.balanceOf(address(this)) * price / 1e18;
        if(totalPaidDebt > totalCollateralValue) reduceOnly = true;
        if(eventTriggerMode) allowLiquidations = false;
    }

    function getFeedPrice() external view returns (uint price, uint updatedAt) {
        (,int256 feedPrice,,uint feedUpdatedAt,) = feed.latestRoundData();
        updatedAt = feedUpdatedAt;
        if(feedPrice <= 0) return (0, updatedAt); //convert negative price to 0 to signal invalid price
        uint8 feedDecimals = feed.decimals();
        uint8 tokenDecimals = uint8(collateralDecimals); // collateral balances are kept in native token decimals
        if(feedDecimals + tokenDecimals <= 36) {
            uint8 decimals = 36 - tokenDecimals - feedDecimals;
            price = uint(feedPrice) * (10**decimals);
        } else {
            uint8 decimals = feedDecimals + tokenDecimals - 36;
            price = uint(feedPrice) / (10**decimals);
        }
    }

    function getSellAmountOut(uint coinIn) public view returns (uint assetOut) {
        uint8 coinDecimals = 18;
        uint8 assetDecimals = psmAsset.decimals();

        if (coinDecimals > assetDecimals) {
            // e.g., 18 decimals -> 6 decimals: divide by 10^(18-6) = 10^12
            assetOut = coinIn / (10 ** (coinDecimals - assetDecimals));
        } else if (assetDecimals > coinDecimals) {
            // e.g., 6 decimals -> 18 decimals: multiply by 10^(18-6) = 10^12
            assetOut = coinIn * (10 ** (assetDecimals - coinDecimals));
        } else {
            // Same decimals: 1:1 ratio
            assetOut = coinIn;
        }
    }

    /// Provides an upperbound of assets received
    /// @dev the amount will be precise if no vault is attached to the PSM, but may overshoot on assets received if:
    /// 1. There is a rounding loss in the vault. This is almost guaranteed.
    /// 2. There is a withdraw fee or other loss occuring in the vault
    /// To get a more precise estimate, we suggest using the following code in case the contract uses a PSM:
    /// `getBuyAmountOut(vault.previewRedeem(vault.previewDeposit(assetIn)))`
    function getBuyAmountOut(uint assetIn) public view returns (uint coinOut) {
        uint8 coinDecimals = 18;
        uint8 assetDecimals = psmAsset.decimals();

        if (assetDecimals > coinDecimals) {
            // e.g., 6 decimals -> 18 decimals: divide by 10^(6-18) = 10^12
            coinOut = assetIn / (10 ** (assetDecimals - coinDecimals));
        } else if (coinDecimals > assetDecimals) {
            // e.g., 18 decimals -> 6 decimals: multiply by 10^(18-6) = 10^12
            coinOut = assetIn * (10 ** (coinDecimals - assetDecimals));
        } else {
            // Same decimals: 1:1 ratio
            coinOut = assetIn;
        }

    }

    /// @notice Normalizes PSM asset amount to 18 decimals
    /// @param assets The amount of PSM asset to normalize
    /// @return The normalized amount with 18 decimals
    function normalizePsmAssets(uint256 assets) internal view returns (uint256) {
        if (psmAssetDecimals == 18) {
            return assets;
        } else if (psmAssetDecimals > 18) {
            return assets / (10 ** (psmAssetDecimals - 18));
        } else {
            return assets * (10 ** (18 - psmAssetDecimals));
        }
    }

    /// @notice Calculates the pending interest that would be earned by vault stakers if accrueInterest() were called
    /// @dev This is used by the Vault to include pending yield in totalAssets() for ERC-4626 compliance
    /// @return pendingVaultInterest The amount of interest that would be minted to the vault
    function getPendingInterest() external view returns (uint256 pendingVaultInterest) {
        uint timeElapsed = block.timestamp - lastAccrue;
        if(timeElapsed == 0) return 0;
        if(eventTriggerMode) return 0;

        uint256 gasBefore = gasleft();
        
        try interestModel.calculateInterest(
            totalPaidDebt,
            lastBorrowRateMantissa,
            timeElapsed,
            expRate,
            getPsmDebtRatio(),
            targetPsmDebtRatioStartBps,
            targetPsmDebtRatioEndBps
        ) returns (uint, uint interest) {
            uint120 localReserveFee = uint120(interest * feeBps / 10000);
            uint120 globalReserveFee = uint120(interest * cachedGlobalFeeBps / 10000);
            // we remove reserve fees from interest before calculating how much to give to stakers
            uint interestAfterFees = interest - localReserveFee - globalReserveFee;
            uint totalStaked = coin.balanceOf(address(vault));
            if(totalStaked < totalPaidDebt) { // this also implies totalPaidDebt > 0 and guards the division below
                // if total staked is less than paid debt, giving all interest to stakers would
                // result in higher supply rate than borrow rate which is undesirable.
                // we cap the supply rate at the borrow rate and give the rest to local reserves.
                uint stakedInterest = interestAfterFees * totalStaked / totalPaidDebt;
                return stakedInterest;
            } else {
                // if total staked is greater than paid debt, we give all interest to stakers
                return interestAfterFees;
            }
        } catch {
            require(gasBefore >= INTEREST_CALCULATION_GAS_REQUIREMENT, "Not enough gas for accrueInterest");
        }
    }

    // Setters

    function setHalfLife(uint64 halfLife) external onlyOperatorOrManager beforeDeadline {
        accrueInterest();
        require(halfLife >= 12 hours && halfLife <= 30 days, "Invalid half life");
        expRate = uint64(uint(wadLn(2*1e18)) / halfLife);
        emit HalfLifeUpdated(halfLife);
    }

    function setTargetPsmDebtRatio(uint16 startBps, uint16 endBps) external onlyOperatorOrManager beforeDeadline {
        accrueInterest();
        require(startBps >= 500 && startBps <= endBps, "Invalid start bps");
        require(endBps >= startBps && endBps <= 9500, "Invalid end bps");
        targetPsmDebtRatioStartBps = uint16(startBps);
        targetPsmDebtRatioEndBps = uint16(endBps);
        emit TargetPsmDebtRatioUpdated(startBps, endBps);
    }

    function setMaxBorrowDeltaBps(uint16 _maxBorrowDeltaBps) external onlyOperatorOrManager beforeDeadline {
        require(_maxBorrowDeltaBps <= 200 && _maxBorrowDeltaBps >= 50, "Invalid borrow delta bps"); // Max 2%
        maxBorrowDeltaBps = _maxBorrowDeltaBps;
        emit MaxBorrowDeltaBpsUpdated(_maxBorrowDeltaBps);
    }

    function setLocalReserveFeeBps(uint _feeBps) external onlyOperator {
        accrueInterest();
        require(_feeBps <= 1000, "Invalid fee");
        feeBps = uint16(_feeBps);
        emit LocalReserveFeeUpdated(_feeBps);
    }

    function setPendingOperator(address _pendingOperator) external onlyOperator {
        pendingOperator = _pendingOperator;
        emit PendingOperatorUpdated(_pendingOperator);
    }

    function acceptOperator() external {
        require(msg.sender == pendingOperator, "Unauthorized");
        operator = pendingOperator;
        pendingOperator = address(0);
        emit OperatorAccepted(operator);
    }

    function setManager(address _manager) external onlyOperatorOrManager {
        manager = _manager;
        emit ManagerUpdated(_manager);
    }

    function enableImmutabilityNow() external onlyOperator beforeDeadline {
        immutabilityDeadline = block.timestamp;
        emit ImmutabilityEnabled(block.timestamp);
    }

    function enableEventTriggerMode() external {
        require(msg.sender == eventTriggerOperator, "Unauthorized");
        require(!eventTriggerMode, "Event trigger mode active");
        accrueInterest();
        eventTriggerMode = true;
        lastAccrue = uint40(block.timestamp);
        emit EventTriggerModeEnabled(msg.sender);
    }

    function pullLocalReserves() external {
        accrueInterest();
        accruePsmProfit();
        if (accruedLocalReserves == 0) return;
        coin.mint(operator, accruedLocalReserves);
        emit AccruedLocalReserves(accruedLocalReserves);
        accruedLocalReserves = 0;
    }

    function pullGlobalReserves(address _to) external returns (uint256 amount) {
        require(msg.sender == address(factory), "Unauthorized");
        accrueInterest();
        amount = accruedGlobalReserves;
        coin.mint(_to, amount);
        emit AccruedGlobalReserves(amount);
        accruedGlobalReserves = 0;
    }

    // Events

    event PositionAdjusted(address indexed account, int collateralDelta, int debtDelta);
    event HalfLifeUpdated(uint64 halfLife);
    event TargetPsmDebtRatioUpdated(uint16 startBps, uint16 endBps);
    event MaxBorrowDeltaBpsUpdated(uint16 maxBorrowDeltaBps);
    event DelegationUpdated(address indexed delegator, address indexed delegatee, bool isDelegatee);
    event PendingOperatorUpdated(address indexed pendingOperator);
    event OperatorAccepted(address indexed operator);
    event ManagerUpdated(address indexed manager);
    event LocalReserveFeeUpdated(uint256 feeBps);
    event Liquidated(address indexed borrower, address indexed liquidator, uint repayAmount, uint collateralOut);
    event WrittenOff(address indexed borrower, address indexed to, uint debt, uint collateral);
    event Sold(address indexed account, uint coinIn, uint assetOut);
    event Bought(address indexed account, uint assetIn, uint coinOut);
    event ImmutabilityEnabled(uint256 timestamp);
    event EventTriggerModeEnabled(address indexed eventTriggerOperator);
    event AccruedLocalReserves(uint256 amount);
    event AccruedGlobalReserves(uint256 amount);
    event InterestAccrued(uint256 interestAccrued, uint256 newBorrowRateMantissa);
}
