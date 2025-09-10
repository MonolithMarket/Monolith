// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

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
}

contract Lender {

    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    // single 256-bit slot
    uint16 public targetFreeDebtRatioStartBps = 2000; // max uint16 is 65535 bps which is outside of the range [0, 10000]
    uint16 public targetFreeDebtRatioEndBps = 4000; // max uint16 is 65535 bps which is outside of the range [0, 10000]
    uint16 public redeemFeeBps = 30; // max uint16 is 65535 bps fee which is outside of the range [0, 10000]
    uint64 public expRate = uint64(uint(wadLn(2*1e18)) / 7 days); // max result is 693147180559945309 which is within uint64 range
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
    uint public totalFreeDebt;
    uint public totalFreeDebtShares;
    uint public totalPaidDebt;
    uint public totalPaidDebtShares;
    uint public epoch;
    uint public lastPsmAssets;

    // Constants and immutables
    Coin public immutable coin;
    ERC20 public immutable collateral;
    ERC20 public immutable psmAsset;
    ERC4626 public immutable psmVault;
    IChainlinkFeed public immutable feed;
    Vault public immutable vault;
    InterestModel public immutable interestModel;
    IFactory public immutable factory;
    uint public immutable collateralFactor;
    uint public immutable minDebt;
    uint public immutable deployTimestamp;
    uint public constant STALENESS_THRESHOLD = 25 hours; // standard 24 hours staleness + 1 hour buffer
    uint public constant STALENESS_UNWIND_DURATION = 24 hours;
    uint public constant MIN_LIQUIDATION_DEBT = 10_000e18; // 10,000 Coin

    // Mappings
    mapping(address => uint) public _cachedCollateralBalances; // should not be read externally in most cases
    mapping(address => uint) public freeDebtShares;
    mapping(address => uint) public paidDebtShares;
    mapping(address => bool) public isRedeemable;
    mapping(address => mapping(address => bool)) public delegations;

    mapping(address => uint) public borrowerLastRedeemedIndex;
    mapping(address => uint) public borrowerEpoch;
    mapping(uint => uint) public epochRedeemedCollateral;
    uint256 public nonRedeemableCollateral;

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
        uint collateralFactor;
        uint minDebt;
        uint timeUntilImmutability;
    }

    constructor(LenderParams memory params) {
        require(params.collateralFactor <= 10000, "Invalid collateral factor");
        require(params.timeUntilImmutability < 1460 days, "Max immutability deadline is in 4 years");
        if(params.psmVault != ERC4626(address(0))) require(params.psmVault.asset() == params.psmAsset, "PSM asset mismatch");
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
        collateralFactor = params.collateralFactor;
        minDebt = params.minDebt;
        deployTimestamp = block.timestamp;
        immutabilityDeadline = block.timestamp + params.timeUntilImmutability;
        lastAccrue = uint40(block.timestamp);
        cachedGlobalFeeBps = uint16(factory.getFeeOf(address(this)));
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

        try interestModel.calculateInterest(
            totalPaidDebt,
            lastBorrowRateMantissa,
            timeElapsed,
            expRate,
            getFreeDebtRatio(),
            targetFreeDebtRatioStartBps,
            targetFreeDebtRatioEndBps
        ) returns (uint currBorrowRate, uint interest) {
            uint120 localReserveFee = uint120(interest * feeBps / 10000);
            uint120 globalReserveFee = uint120(interest * cachedGlobalFeeBps / 10000);
            accruedLocalReserves += localReserveFee;
            accruedGlobalReserves += globalReserveFee;
            // we remove reserve fees from interest before calculating how much to give to stakers
            uint interestAfterFees = interest - localReserveFee - globalReserveFee;
            uint totalStaked = vault.totalAssets();
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
        } catch {
            // If the call reverts, do nothing.
        }
    }

    function adjust(address account, int collateralDelta, int debtDelta) public {
        accrueInterest();
        updateBorrower(account);
        // Handle collateral changes
        if (collateralDelta > 0) {
            if(!isRedeemable[account]) nonRedeemableCollateral += uint(collateralDelta);
            
            // Deposit collateral
            _cachedCollateralBalances[account] += uint(collateralDelta);
            collateral.safeTransferFrom(msg.sender, address(this), uint(collateralDelta));
        } else if (collateralDelta < 0) {
            // Ensure sufficient collateral for non-redeemable accounts
            if (isRedeemable[account]) {
                require(
                    collateral.balanceOf(address(this)) - uint256(-collateralDelta) >= nonRedeemableCollateral,
                    "Insufficient redeemable collateral"
                );
            } else {
                nonRedeemableCollateral -= uint256(-collateralDelta);
            }
 
            // Withdraw collateral
            _cachedCollateralBalances[account] -= uint(-collateralDelta);
            collateral.safeTransfer(msg.sender, uint(-collateralDelta));
        }

        // Handle debt changes
        int actualDebtDelta = debtDelta;
        if (debtDelta > 0) {
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

        // Skip solvency checks if debt is zero
        if(debtBalance == 0) return;

        // Check solvency
        (uint price, bool reduceOnly, ) = getCollateralPrice();
        require(!reduceOnly, "Reduce only");
        uint borrowingPower = price * _cachedCollateralBalances[account] * collateralFactor / 1e18 / 10000;
        require(debtBalance <= borrowingPower, "Solvency check failed");
    }

    function adjust(address account, int collateralDelta, int debtDelta, bool chooseRedeemable) external {
        setRedemptionStatus(account, chooseRedeemable);
        adjust(account, collateralDelta, debtDelta);
    }

    /// @notice Allows an account to delegate control of their position to another address (adjustPosition, optInRedemptions, optOutRedemptions functions)
    /// @param delegatee The address to delegate to
    /// @param isDelegatee True to enable delegation, false to revoke
    function delegate(address delegatee, bool isDelegatee) external {
        delegations[msg.sender][delegatee] = isDelegatee;
        emit DelegationUpdated(msg.sender, delegatee, isDelegatee);
    }

    function setRedemptionStatus(address account, bool chooseRedeemable) public {
        accrueInterest();
        updateBorrower(account);
        require(msg.sender == account || delegations[account][msg.sender], "Unauthorized");
        if(chooseRedeemable == isRedeemable[account]) return; // no change
        if(chooseRedeemable){
            borrowerEpoch[account] = epoch;
            borrowerLastRedeemedIndex[account] = epochRedeemedCollateral[epoch];
            nonRedeemableCollateral -= _cachedCollateralBalances[account];
        } else {
            nonRedeemableCollateral += _cachedCollateralBalances[account];
        }
        uint prevDebt = getDebtOf(account);
        if(prevDebt > 0) {
            decreaseDebt(account, type(uint).max);
            isRedeemable[account] = chooseRedeemable;
            increaseDebt(account, prevDebt);
            uint currDebt = getDebtOf(account);
            require(currDebt >= prevDebt, "Debt decreased unexpectedly");
        } else {
            isRedeemable[account] = chooseRedeemable;
        }
        emit RedemptionStatusUpdated(account, chooseRedeemable);
    }

        /// @notice Liquidates an unsafe position
    /// @param borrower The account to be liquidated
    /// @param repayAmount The amount of debt to repay
    /// @param minCollateralOut The minimum amount of collateral to receive
    /// @return The amount of collateral received
    function liquidate(address borrower, uint repayAmount, uint minCollateralOut) external returns(uint) {
        accrueInterest();
        updateBorrower(borrower);
        require(repayAmount > 0, "Repay amount must be greater than 0");
        (uint price,, bool allowLiquidations) = getCollateralPrice();
        require(allowLiquidations, "liquidations disabled");
        uint debt = getDebtOf(borrower);
        uint collateralBalance = _cachedCollateralBalances[borrower];
        // check liquidation condition
        uint liquidatableDebt = getLiquidatableDebt(collateralBalance, price, debt);
        require(liquidatableDebt > 0, "insufficient liquidatable debt");
        if(repayAmount > liquidatableDebt) {
            repayAmount = liquidatableDebt;
        }

        // apply repayment
        decreaseDebt(borrower, repayAmount);

        // calculate collateral reward
        uint liqIncentiveBps = getLiquidationIncentiveBps(collateralBalance, price, debt);
        uint collateralRewardValue = repayAmount * (10000 + liqIncentiveBps) / 10000;
        uint collateralReward = collateralRewardValue * 1e18 / price;
        collateralReward = collateralReward > collateralBalance ? collateralBalance : collateralReward;
        require(collateralReward >= minCollateralOut, "insufficient collateral out");

        if(collateralReward > 0) {
            collateral.safeTransfer(msg.sender, collateralReward);
            _cachedCollateralBalances[borrower] = collateralBalance - collateralReward;
            if(!isRedeemable[borrower]) nonRedeemableCollateral -= collateralReward;
        }
        coin.transferFrom(msg.sender, address(this), repayAmount);
        coin.burn(repayAmount);
        emit Liquidated(borrower, msg.sender, repayAmount, collateralReward);
        // try to write off remaining debt. Call externally and catch error to prevent liquidation failure
        try this.writeOff(borrower, msg.sender) {} catch {}
        return collateralReward;
    }

    /// @notice Redistributes excess debt of undercollateralized accounts among other borrowers
    /// @param borrower The account in potentiallyundercollateralized state
    /// @return writtenOff True if the borrower was written off, false otherwise
    /// @param to The address to send the collateral to
    /// @dev This function is called by liquidate() when a borrower's position is undercollateralized. It should never revert to avoid liquidation failure.
    function writeOff(address borrower, address to) external returns (bool writtenOff) {
        accrueInterest();
        updateBorrower(borrower);
        // check for write off
        uint debt = getDebtOf(borrower);
        if(debt > 0) {
            uint collateralBalance = _cachedCollateralBalances[borrower];
            (uint price,, bool allowLiquidations) = getCollateralPrice();
            require(allowLiquidations, "liquidations disabled");
            uint collateralValue = price * collateralBalance / 1e18;
            // if debt is more than 100 times the collateral value, write off
            if(debt > collateralValue * 100) {
                // 1. delete all of the borrower's debt
                decreaseDebt(borrower, type(uint).max);
                // 2. redistribute excess debt among remaining borrowers
                uint256 totalDebt = totalFreeDebt + totalPaidDebt;
                if (totalDebt > 0) {
                    uint256 freeDebtIncrease = debt * totalFreeDebt / totalDebt;
                    uint256 paidDebtIncrease = debt - freeDebtIncrease;

                    totalFreeDebt += freeDebtIncrease;
                    totalPaidDebt += paidDebtIncrease;
                }
                // 3. send collateral to caller
                collateral.safeTransfer(to, collateralBalance);
                if(!isRedeemable[borrower]) nonRedeemableCollateral -= collateralBalance;
                
                _cachedCollateralBalances[borrower] = 0;
                emit WrittenOff(borrower, to, debt, collateralBalance);
                writtenOff = true;
            }
        }
    }

    /// @notice Redeems Coin for collateral at current market price minus a fee
    /// @param amountIn The amount of Coin to redeem
    /// @param minAmountOut The minimum amount of collateral to receive
    /// @return amountOut The amount of collateral received
    /// @dev Redemptions requires sufficient redeemable collateral to seize and free debt to repay
    function redeem(uint amountIn, uint minAmountOut) external returns (uint amountOut) {
        accrueInterest();
        // calculate amountOut
        amountOut = getRedeemAmountOut(amountIn);
        require(amountOut >= minAmountOut, "insufficient amount out");
        require(collateral.balanceOf(address(this)) - amountOut >= nonRedeemableCollateral, "Insufficient redeemable collateral");
        // repay on behalf of free debtors
        totalFreeDebt -= amountIn;
        coin.transferFrom(msg.sender, address(this), amountIn);
        coin.burn(amountIn);

        // distribute collateral redemption per free debt share
        epochRedeemedCollateral[epoch] += amountOut.mulDivUp(1e36, totalFreeDebtShares);

        collateral.safeTransfer(msg.sender, amountOut);

        // Intentional division by zero and revert if totalFreeDebt is 0
        if( totalFreeDebtShares / totalFreeDebt > 1e9) {
            epoch++;
            totalFreeDebtShares = totalFreeDebtShares.mulDivUp(1e18,1e36); 
            emit NewEpoch(epoch);
        }

        emit Redeemed(msg.sender, amountIn, amountOut);
        return amountOut;
    }

    function sell(uint coinIn, uint minAssetOut) external returns (uint assetOut) {
        accruePsmProfit();
        assetOut = getSellAmountOut(coinIn);
        require(assetOut >= minAssetOut, "insufficient amount out");
        // get and burn coins from caller
        coin.transferFrom(msg.sender, address(this), coinIn);
        coin.burn(coinIn);
        // give assets to caller
        if(psmVault != ERC4626(address(0))) {
            psmVault.withdraw(assetOut, msg.sender, address(this));
        } else {
            psmAsset.safeTransfer(msg.sender, assetOut);
        }
        emit Sold(msg.sender, coinIn, assetOut);
    }

    function buy(uint assetIn, uint minCoinOut) external beforeDeadline returns (uint coinOut) {
        accruePsmProfit();
        uint coinFee;
        (coinOut, coinFee) = getBuyAmountOut(assetIn);
        require(coinOut >= minCoinOut, "insufficient amount out");

        accruedLocalReserves += uint120(coinFee);

        // get assets from caller
        psmAsset.safeTransferFrom(msg.sender, address(this), assetIn);
        if(psmVault != ERC4626(address(0))) {
            psmVault.deposit(assetIn, address(this));
        }
        // give coins to caller
        coin.mint(msg.sender, coinOut);
        emit Bought(msg.sender, assetIn, coinOut);
    }


    // Internal functions

    function accruePsmProfit() internal {
        if(psmVault != ERC4626(address(0))) {
            uint assets = psmVault.previewRedeem(psmVault.balanceOf(address(this)));
            uint _lastPsmAssets = lastPsmAssets;
            if(assets <= _lastPsmAssets) return; // avoids underflow in case of loss
            uint profit = assets - _lastPsmAssets;
            accruedLocalReserves += uint120(profit);
            lastPsmAssets = assets;
        }
    }

    function updateBorrower(address borrower) internal {
        uint borrowerDebtShares = freeDebtShares[borrower];
        
        if (borrowerDebtShares > 0) {
            uint _borrowerEpoch = borrowerEpoch[borrower];
            uint bal = _cachedCollateralBalances[borrower];
            uint lastIndex = borrowerLastRedeemedIndex[borrower];
            // Loop through missed epochs (max 5 iterations considering max uint256 is 2^256 - 1 would go to zero in 5 iterations)
            for (uint i = 0; i < 5 && _borrowerEpoch < epoch && borrowerDebtShares > 0; ++i) {
                // Apply redemption for the borrower's current epoch
                uint indexDelta = epochRedeemedCollateral[_borrowerEpoch] - lastIndex;
                uint redeemedCollateral = indexDelta.mulDivUp(borrowerDebtShares, 1e36);
                bal = bal < redeemedCollateral ? 0 : bal - redeemedCollateral;

                // Move to next epoch, reduce shares
                _borrowerEpoch += 1;
                borrowerDebtShares = borrowerDebtShares.divWadUp(1e36) == 1 ? 0 : borrowerDebtShares.divWadUp(1e36); // If shares is 1 round down to 0
                lastIndex = 0; // For new epoch, last redeemed index is 0
            }
            // Apply any remaining redemption for the current epoch
            if (borrowerDebtShares > 0) {
                uint indexDelta = epochRedeemedCollateral[_borrowerEpoch] - lastIndex;
                uint redeemedCollateral = indexDelta.mulDivUp(borrowerDebtShares, 1e36);
                bal = bal < redeemedCollateral ? 0 : bal - redeemedCollateral;
            }
            // Update state
            freeDebtShares[borrower] = borrowerDebtShares;
            _cachedCollateralBalances[borrower] = bal;
        }

        if(isRedeemable[borrower]){
            borrowerEpoch[borrower] = epoch;
            borrowerLastRedeemedIndex[borrower] = epochRedeemedCollateral[epoch];
        } 
    }

    function increaseDebt(address account, uint256 amount) internal {
        if (isRedeemable[account]) {
            // Handle free debt
            uint shares = totalFreeDebtShares == 0 ? 
                    amount : 
                    amount.mulDivUp(totalFreeDebtShares, totalFreeDebt);
            totalFreeDebt += amount;
            totalFreeDebtShares += shares;
            freeDebtShares[account] += shares;
        } else {
            // Handle paid debt 
            uint256 shares = totalPaidDebtShares == 0 ? 
                amount : 
                amount.mulDivUp(totalPaidDebtShares, totalPaidDebt);
            totalPaidDebt += amount;
            totalPaidDebtShares += shares;
            paidDebtShares[account] += shares;
        }
    }

    function decreaseDebt(address account, uint256 amount) internal {
        if (isRedeemable[account]) {
            // Handle free debt
            uint256 shares;
            if(amount == type(uint).max) {
                shares = freeDebtShares[account];
                amount = getDebtOf(account);
            } else {
                shares = amount.mulDivDown(totalFreeDebtShares, totalFreeDebt);
            }
            freeDebtShares[account] -= shares;
            totalFreeDebtShares = totalFreeDebtShares <= shares ? 0 : totalFreeDebtShares - shares; // prevent underflow
            totalFreeDebt = totalFreeDebt <= amount ? 0 : totalFreeDebt - amount; // prevent underflow
        } else {
            // Handle paid debt
            uint256 shares;
            if(amount == type(uint).max) {
                shares = paidDebtShares[account];
                amount = getDebtOf(account);
            } else {
                shares = amount.mulDivDown(totalPaidDebtShares, totalPaidDebt);
            }
            
            paidDebtShares[account] -= shares;
            totalPaidDebtShares -= shares;
            totalPaidDebt -= amount;
        }
    }

    function getLiquidatableDebt(uint collateralBalance, uint price, uint debt) internal view returns(uint liquidatableDebt){
        uint borrowingPower = price * collateralBalance * collateralFactor / 1e18 / 10000;
        if(borrowingPower > debt) return 0;
        // liquidate 25% of the total debt
        liquidatableDebt = debt / 4; // 25% of the debt
        // liquidate at least MIN_LIQUIDATION_DEBT (or the entire debt if it's less than MIN_LIQUIDATION_DEBT)
        if(liquidatableDebt < MIN_LIQUIDATION_DEBT) liquidatableDebt = debt < MIN_LIQUIDATION_DEBT ? debt : MIN_LIQUIDATION_DEBT;
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

    function getFreeDebtRatio() public view returns (uint) {
        uint _adjustedTotalFreeDebt = totalFreeDebt + lastPsmAssets;
        return _adjustedTotalFreeDebt == 0 ? 0 : _adjustedTotalFreeDebt * 10000 / (totalPaidDebt + _adjustedTotalFreeDebt);
    }

    function getDebtOf(address account) public view returns (uint) {
        if(isRedeemable[account]) {
            return totalFreeDebtShares == 0 ? 0 : freeDebtShares[account].mulDivUp(totalFreeDebt, totalFreeDebtShares);
        } else {
            return totalPaidDebtShares == 0 ? 0 : paidDebtShares[account].mulDivUp(totalPaidDebt, totalPaidDebtShares);
        }
    }

    /// @notice Gets the current price of the collateral asset
    /// @return price The price in USD normalized to (36 - collateral decimals) decimals for consistent calculations
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

        if (timeElapsed > STALENESS_THRESHOLD) {
            reduceOnly = true;
            uint stalenessDuration = timeElapsed - STALENESS_THRESHOLD;
            if (stalenessDuration < STALENESS_UNWIND_DURATION) {
                price = price * (STALENESS_UNWIND_DURATION - stalenessDuration) / STALENESS_UNWIND_DURATION;
            } else {
                price = 0;
            }
        }
        price = price == 0 ? 1 : price; // avoid division by zero in consumer functions
    }

    function getFeedPrice() external view returns (uint price, uint updatedAt) {
        (,int256 feedPrice,,uint256 feedUpdatedAt,) = feed.latestRoundData();
        uint8 feedDecimals = feed.decimals();
        uint8 tokenDecimals = collateral.decimals();
        if(feedDecimals + tokenDecimals <= 36) {
            uint8 decimals = 36 - tokenDecimals - feedDecimals;
            price = feedPrice > 0 ? uint(feedPrice) * (10**decimals) : 0; // convert negative price to uint 0 to signal invalid price
        } else {
            uint8 decimals = feedDecimals + tokenDecimals - 36;
            price = feedPrice > 0 ? uint(feedPrice) / (10**decimals) : 0; // convert negative price to uint 0 to signal invalid price
        }
        updatedAt = feedUpdatedAt;
    }

    /// @notice Calculates the amount of collateral received for redeeming Coin
    /// @param amountIn The amount of Coin to redeem
    /// @return amountOut The amount of collateral to receive
    function getRedeemAmountOut(uint amountIn) public view returns (uint amountOut) {
        if(amountIn > totalFreeDebt) return 0; // can't redeem more than free debt
        (uint price,, bool allowLiquidations) = getCollateralPrice();
        if(!allowLiquidations) return 0;
        // multiply amountIn by price then apply redeem fee to amountIn
        amountOut = amountIn * 1e18 * (10000 - redeemFeeBps) / price / 10000;
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

    function getBuyFeeBps() public view returns (uint) {
        uint startTime = deployTimestamp;
        uint deadline = immutabilityDeadline;
        uint current = block.timestamp;

        // Calculate the halfway point of the deadline period
        uint halfTime = startTime + ((deadline - startTime) / 2);

        if (current >= deadline || current < halfTime) {
            return 0;
        }

        // fee ramps from 0% to 1% (100 bps) over the second half of the deadline period
        // rampDuration = deadline - halfTime = (deadline - startTime) / 2
        // timeIntoRamp = current - halfTime
        // feeBps = timeIntoRamp * 100 / rampDuration
        uint rampDuration = deadline - halfTime;
        if (rampDuration == 0) return 100; // avoids division by zero

        uint timeIntoRamp = current - halfTime;
        uint buyFeeBps = timeIntoRamp * 100 / rampDuration;

        // Cap at 100 bps (1%)
        return buyFeeBps > 100 ? 100 : buyFeeBps;
    }

    function getBuyAmountOut(uint assetIn) public view returns (uint coinOut, uint coinFee) {
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

        // Apply buy fee
        uint buyFeeBps = getBuyFeeBps();
        coinFee = coinOut * buyFeeBps / 10000;
        coinOut -= coinFee;
    }

    // Setters

    function setHalfLife(uint64 halfLife) external onlyOperatorOrManager beforeDeadline {
        accrueInterest();
        require(halfLife >= 12 hours && halfLife <= 30 days, "Invalid half life");
        expRate = uint64(uint(wadLn(2*1e18)) / halfLife);
        emit HalfLifeUpdated(halfLife);
    }

    function setTargetFreeDebtRatio(uint16 startBps, uint16 endBps) external onlyOperatorOrManager beforeDeadline {
        accrueInterest();
        require(startBps >= 500 && startBps <= endBps, "Invalid start bps");
        require(endBps >= startBps && endBps <= 9500, "Invalid end bps");
        targetFreeDebtRatioStartBps = uint16(startBps);
        targetFreeDebtRatioEndBps = uint16(endBps);
        emit TargetFreeDebtRatioUpdated(startBps, endBps);
    }

    function setRedeemFeeBps(uint16 _redeemFeeBps) external onlyOperatorOrManager beforeDeadline {
        accrueInterest();
        require(_redeemFeeBps <= 300, "Invalid redeem fee bps");
        redeemFeeBps = uint16(_redeemFeeBps);
        emit RedeemFeeBpsUpdated(_redeemFeeBps);
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
        emit OperatorAccepted(pendingOperator);
    }

    function setManager(address _manager) external onlyOperatorOrManager {
        manager = _manager;
        emit ManagerUpdated(_manager);
    }

    function enableImmutabilityNow() external onlyOperator beforeDeadline {
        immutabilityDeadline = block.timestamp;
    }

    function pullLocalReserves() external onlyOperator {
        accrueInterest();
        accruePsmProfit();
        coin.mint(msg.sender, accruedLocalReserves);
        accruedLocalReserves = 0;
    }

    function pullGlobalReserves(address _to) external {
        require(msg.sender == address(factory), "Unauthorized");
        accrueInterest();
        coin.mint(_to, accruedGlobalReserves);
        accruedGlobalReserves = 0;
    }

    // Events

    event PositionAdjusted(address indexed account, int collateralDelta, int debtDelta);
    event HalfLifeUpdated(uint64 halfLife);
    event TargetFreeDebtRatioUpdated(uint16 startBps, uint16 endBps);
    event RedeemFeeBpsUpdated(uint16 redeemFeeBps);
    event DelegationUpdated(address indexed delegator, address indexed delegatee, bool isDelegatee);
    event PendingOperatorUpdated(address indexed pendingOperator);
    event OperatorAccepted(address indexed operator);
    event ManagerUpdated(address indexed manager);
    event LocalReserveFeeUpdated(uint256 feeBps);
    event RedemptionStatusUpdated(address indexed account, bool isRedeemable);
    event Liquidated(address indexed borrower, address indexed liquidator, uint repayAmount, uint collateralOut);
    event WrittenOff(address indexed borrower, address indexed to, uint debt, uint collateral);
    event NewEpoch(uint epoch);
    event Redeemed(address indexed account, uint amountIn, uint amountOut);
    event Sold(address indexed account, uint coinIn, uint assetOut);
    event Bought(address indexed account, uint assetIn, uint coinOut);
}
