// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "lib/solmate/src/tokens/ERC20.sol";
import "lib/solmate/src/utils/SignedWadMath.sol";
import "./CollateralManager.sol";

interface IFactory {
    function feeBps() external view returns (uint256);
}

interface ICollateral {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

interface IChainlinkFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IsUSD2 {
    function totalAssets() external view returns (uint256);
}

/// @title USD2 - An autonomous collateralized debt position (CDP) protocol
/// @notice Allows users to borrow USD2 stablecoins against collateral
/// @dev Implements a dual debt system with free (redeemable) and paid debt
contract USD2 is ERC20 {

    // single 256-bit slot
    uint16 public targetFreeDebtRatioStartBps = 2000; // max uint16 is 65535 bps which is outside of the range [0, 10000]
    uint16 public targetFreeDebtRatioEndBps = 4000; // max uint16 is 65535 bps which is outside of the range [0, 10000]
    uint16 public redeemFeeBps = 30; // max uint16 is 65535 bps fee which is outside of the range [0, 10000]
    uint64 public expRate = uint64(uint(wadLn(2*1e18)) / 7 days); // max result is 693147180559945309 which is within uint64 range
    uint40 public lastAccrue; // max uint40 is year 36812
    uint88 public lastBorrowRateMantissa = uint88(MIN_RATE); // max uint88 is equivalent to 309485000% APR
    uint16 public feeBps; // max uint16 is 65535 bps which is outside of the range [0, 10000]

    // single 256-bit slot
    uint128 public accruedLocalFees;
    uint128 public accruedGlobalFees;

    // other slots
    uint public totalFreeDebt;
    uint public totalFreeDebtShares;
    uint public totalPaidDebt;
    uint public totalPaidDebtShares;
    address public operator;

    // immutables and constants
    address public immutable factory;
    uint public constant MAX_FEE_BPS = 1000;
    uint public immutable IMMUTABILITY_DEADLINE;
    uint public immutable COLLATERAL_FACTOR_BPS;
    uint internal constant MAX_UINT256 = 2**256 - 1;
    uint internal constant MIN_RATE = 5e15; // 0.5%
    uint public constant MIN_LIQUIDATION_DEBT = 10_000e18; // 10,000 USD2
    ICollateral public immutable collateral;
    IChainlinkFeed public immutable feed;
    IsUSD2 public immutable sUSD2;
    CollateralManager public immutable collateralManager;
    uint private immutable WAD_LN2 = uint(wadLn(2*1e18));

    mapping(address => uint) public freeDebtShares;
    mapping(address => uint) public paidDebtShares;
    mapping(address => mapping(address => bool)) public delegations;

    event OperatorUpdated(address indexed newOperator);
    event HalfLifeUpdated(uint newHalfLife);
    event TargetFreeDebtRatioRangeUpdated(uint newStartBps, uint newEndBps);
    event RedeemFeeUpdated(uint newFeeBps);
    event DelegationUpdated(address indexed account, address indexed delegatee, bool isDelegatee);
    event PositionAdjusted(address indexed account, int256 collateralDelta, int256 debtDelta);
    event Liquidated(address indexed borrower, address indexed liquidator, uint repayAmount, uint collateralOut);
    event ReserveAdded(address indexed from, uint amount);
    event ReserveRemoved(uint amount);
    event Redeemed(address indexed redeemer, uint amountIn, uint amountOut);
    event WrittenOff(address indexed account, address indexed caller, uint redistributedDebt, uint collateral);
    event InterestFeeUpdated(uint newFeeBps);

    constructor(
        string memory _name,
        string memory _symbol, 
        address _sUSD2,
        address _collateral,
        address _feed,
        address _operator,
        uint _collateralFactor
    ) ERC20(_name, _symbol, 18) {
        require(_collateralFactor <= 10000, "USD2: invalid collateral factor");
        factory = msg.sender;
        COLLATERAL_FACTOR_BPS = _collateralFactor;
        sUSD2 = IsUSD2(_sUSD2);
        collateral = ICollateral(_collateral);
        feed = IChainlinkFeed(_feed);
        operator = _operator;
        IMMUTABILITY_DEADLINE = block.timestamp + 365 days;
        collateralManager = new CollateralManager(_collateral);
        lastAccrue = uint40(block.timestamp);
    }

    modifier onlyOperator() {
        require(msg.sender == operator, "USD2: not operator");
        _;
    }

    modifier beforeDeadline() {
        require(block.timestamp < IMMUTABILITY_DEADLINE, "USD2: immutability deadline passed");
        _;
    }

    /// @notice Burns USD2 tokens without receiving anything in return
    /// @param amount The amount of USD2 tokens to burn
    function burn(uint amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice Updates the operator address
    /// @param _operator The new operator address
    /// @dev Can only be called by the current operator
    function setOperator(address _operator) external {
        require(msg.sender == operator, "USD2: not operator");
        operator = _operator;
        emit OperatorUpdated(_operator);
    }

    function setInterestFeeBps(uint _feeBps) external onlyOperator {
        accrueInterest();
        require(_feeBps <= MAX_FEE_BPS, "USD2: invalid fee");
        feeBps = uint16(_feeBps);
        emit InterestFeeUpdated(_feeBps);
    }

    /// @notice Sets the half-life period for interest rate adjustments. Half life is the duration needed for the rate to decay by half or double
    /// @param _halfLife The new half-life period in seconds
    /// @dev Can only be called by operator before immutability deadline
    function setHalfLife(uint _halfLife) external onlyOperator beforeDeadline {
        accrueInterest();
        require(_halfLife > 0, "USD2: invalid half-life");
        expRate = uint64(WAD_LN2 / _halfLife);
        emit HalfLifeUpdated(_halfLife);
    }

    /// @notice Sets the target range for free debt ratio (between 0 and 10000 each)
    /// @param _start The lower bound of target range in basis points
    /// @param _end The upper bound of target range in basis points
    /// @dev Can only be called by operator before immutability deadline
    function setTargetFreeDebtRatioRangeBps(uint _start, uint _end) external onlyOperator beforeDeadline {
        require(_start <= _end, "USD2: invalid target free debt ratio range");
        require(_end <= 10000, "USD2: invalid target free debt ratio range");
        accrueInterest();
        targetFreeDebtRatioStartBps = uint16(_start);
        targetFreeDebtRatioEndBps = uint16(_end);
        emit TargetFreeDebtRatioRangeUpdated(_start, _end);
    }

    /// @notice Sets the fee charged for redeeming USD2 for collateral (between 0 and 9999)
    /// @param _redeemFeeBps The new redeem fee in basis points (100 = 1%)
    /// @dev Can only be called by operator before immutability deadline
    function setRedeemFeeBps(uint _redeemFeeBps) external onlyOperator beforeDeadline {
        require(_redeemFeeBps < 10000, "USD2: invalid redeem fee");
        redeemFeeBps = uint16(_redeemFeeBps);
        emit RedeemFeeUpdated(_redeemFeeBps);
    }

    /// @notice Gets the ratio of free debt to total debt in basis points
    /// @return The ratio of free debt to total debt (between 0 and 10000)
    function getFreeDebtRatio() public view returns (uint) {
        return totalFreeDebt == 0 ? 0 : totalFreeDebt * 10000 / (totalFreeDebt + totalPaidDebt);
    }

    /// @notice Performs multiplication and division while rounding down
    /// @param x First multiplication factor
    /// @param y Second multiplication factor
    /// @param denominator The divisor
    /// @return z The result, rounded down
    function mulDivDown(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) internal pure returns (uint256 z) {
        /// @solidity memory-safe-assembly
        assembly {
            // Equivalent to require(denominator != 0 && (y == 0 || x <= type(uint256).max / y))
            if iszero(mul(denominator, iszero(mul(y, gt(x, div(MAX_UINT256, y)))))) {
                revert(0, 0)
            }

            // Divide x * y by the denominator.
            z := div(mul(x, y), denominator)
        }
    }

    /// @notice Performs multiplication and division while rounding up
    /// @param x First multiplication factor
    /// @param y Second multiplication factor
    /// @param denominator The divisor
    /// @return z The result, rounded up
    function mulDivUp(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) internal pure returns (uint256 z) {
        /// @solidity memory-safe-assembly
        assembly {
            // Equivalent to require(denominator != 0 && (y == 0 || x <= type(uint256).max / y))
            if iszero(mul(denominator, iszero(mul(y, gt(x, div(MAX_UINT256, y)))))) {
                revert(0, 0)
            }

            // If x * y modulo the denominator is strictly greater than 0,
            // 1 is added to round up the division of x * y by the denominator.
            z := add(gt(mod(mul(x, y), denominator), 0), div(mul(x, y), denominator))
        }
    }

    /// @notice Gets the total debt of a borrower whether it is free or paid debt
    /// @param borrower The address of the borrower
    /// @return The total debt in USD2
    function getDebtOf(address borrower) public view returns (uint) {
        if(collateralManager.isRedeemable(borrower)) {
            return convertToAssets(freeDebtShares[borrower], totalFreeDebt, totalFreeDebtShares);
        } else {
            return convertToAssets(paidDebtShares[borrower], totalPaidDebt, totalPaidDebtShares);
        }
    }

    /// @notice Gets the current price of the collateral asset
    /// @return The price in USD with 18 decimals
    function getCollateralPrice() public view returns (uint) {
        (,int256 price,,,) = feed.latestRoundData();
        // We assume the collateral token is 18 decimals AND that the feed is 18 decimals or lower.
        uint8 decimals = 18 - feed.decimals();
        return uint(price) * (10**decimals);
    }

    /// @notice Converts shares to assets
    /// @param shares The number of shares to convert
    /// @param totalAssets The total assets in the system
    /// @param sharesSupply The total shares supply
    /// @return The amount of assets
    function convertToAssets(uint shares, uint totalAssets, uint sharesSupply) internal pure returns (uint) {
        return sharesSupply == 0 ? shares : mulDivDown(shares, totalAssets, sharesSupply);
    }

    /// @notice Converts assets to shares
    /// @param assets The amount of assets to convert
    /// @param totalAssets The total assets in the system
    /// @param sharesSupply The total shares supply
    /// @return The number of shares
    function convertToShares(uint assets, uint totalAssets, uint sharesSupply) internal pure returns (uint) {
        return sharesSupply == 0 ? assets : mulDivDown(assets, sharesSupply, totalAssets);
    }

    /// @notice Calculates the current interest rate and integral of accumulated interest rates per second
    /// @param _lastRate The previous interest rate
    /// @param _timeElapsed Time since last rate update in seconds
    /// @param _expRate The exponential rate parameter
    /// @param _lastFreeDebtRatioBps Previous free debt ratio in basis points
    /// @param _targetFreeDebtRatioStartBps Target range start in basis points
    /// @param _targetFreeDebtRatioEndBps Target range end in basis points
    /// @return currBorrowRate The new interest rate
    /// @return integral The accumulated interest rates per second over the period
    function calculateRate(
        uint _lastRate,
        uint _timeElapsed,
        uint _expRate,
        uint _lastFreeDebtRatioBps,
        uint _targetFreeDebtRatioStartBps,
        uint _targetFreeDebtRatioEndBps
    ) internal pure returns (uint currBorrowRate, uint integral) {
        // check _expRate * _timeElapsed overflow
        if(uint(type(int256).max) / _expRate < _timeElapsed) _timeElapsed = uint(type(int256).max) / _expRate;
        // we use a negative exponent in order to prevent growthDecay overflow due to large timeElapsed
        // Results of positive exponents can exceed max uint256, negative exponents only return a value between [0, 1e18]
        uint growthDecay = uint(wadExp(-int(_expRate * _timeElapsed)));
        
        if (_lastFreeDebtRatioBps < _targetFreeDebtRatioStartBps) {
            currBorrowRate = _lastRate * 1e18 / growthDecay;
            integral = (currBorrowRate - _lastRate) * 1e18 / _expRate / 365 days;
        } else if (_lastFreeDebtRatioBps > _targetFreeDebtRatioEndBps) {
            currBorrowRate = _lastRate * growthDecay / 1e18;
            if (currBorrowRate < MIN_RATE) {
                currBorrowRate = MIN_RATE;
                // calculate integral
                if (_lastRate <= MIN_RATE) {
                    // Already at min rate, just use flat rate for entire period
                    integral = MIN_RATE * _timeElapsed / 365 days;
                } else {
                    // Calculate time until min rate is reached
                    uint timeToMin = uint(wadLn(int(MIN_RATE * 1e18 / _lastRate))) * 1e18 / _expRate;
                    // Decaying integral up to min rate, then add flat rate portion
                    integral = ((_lastRate - MIN_RATE) * 1e18 / _expRate + 
                              MIN_RATE * (_timeElapsed - timeToMin)) / 365 days;
                }
            } else {
                integral = (_lastRate - currBorrowRate) * 1e18 / _expRate / 365 days;
            }
        } else {
            currBorrowRate = _lastRate;
            integral = _lastRate * _timeElapsed / 365 days;
        }
    }

    /// @notice Charges interest on all paid debt based on the current interest rate, sends interest to stakers and adds any excess interest to reserve.
    /// @dev Updates interest rate state and mints interest to stakers
    function accrueInterest() public {
        uint timeElapsed = block.timestamp - lastAccrue;
        if(timeElapsed == 0) return;

        // calculate rate
        (uint currBorrowRate, uint rateIntegral) = calculateRate(
            lastBorrowRateMantissa,
            timeElapsed,
            expRate,
            getFreeDebtRatio(),
            targetFreeDebtRatioStartBps,
            targetFreeDebtRatioEndBps
        );
    
        uint interest = totalPaidDebt * rateIntegral / 1e18;
        uint128 localFee = uint128(interest * IFactory(factory).feeBps() / 10000);
        uint128 globalFee = uint128(interest * feeBps / 10000);
        accruedLocalFees += localFee;
        accruedGlobalFees += globalFee;
        interest -= (localFee + globalFee);

        if(interest > 0) {
            uint totalStaked = sUSD2.totalAssets();
            if(totalStaked < totalPaidDebt) {
                uint stakedDebt = totalPaidDebt - totalStaked;
                uint stakedInterest = interest * stakedDebt / totalPaidDebt;
                _mint(address(sUSD2), stakedInterest);
                uint remainingInterest = interest - stakedInterest;
                accruedLocalFees += uint128(remainingInterest);

            } else {
                _mint(address(sUSD2), interest);
            }
            totalPaidDebt += interest;
        }

        lastAccrue = uint40(block.timestamp);
        lastBorrowRateMantissa = uint88(currBorrowRate);
    }

    /// @notice Allows an account to delegate control of their position to another address (adjustPosition, optInRedemptions, optOutRedemptions functions)
    /// @param delegatee The address to delegate to
    /// @param isDelegatee True to enable delegation, false to revoke
    function delegate(address delegatee, bool isDelegatee) external {
        delegations[msg.sender][delegatee] = isDelegatee;
        emit DelegationUpdated(msg.sender, delegatee, isDelegatee);
    }

    /// @notice Adjusts a user's collateral and debt position
    /// @param account The account whose position is being adjusted
    /// @param collateralDelta The change in collateral amount (positive for deposit, negative for withdrawal)
    /// @param debtDelta The change in debt amount (positive for borrow, negative for repay)
    /// @dev This function can be called by anyone if it only repays debt and/or adds collateral. If it includes borrowing or withdrawing collateral, it must be called by the account itself or by a delegatee.
    function adjust(address account, int256 collateralDelta, int256 debtDelta) public {
        accrueInterest();
        
        // Handle collateral changes
        if (collateralDelta > 0) {
            // Deposit collateral
            require(collateral.transferFrom(
                msg.sender, // we deposit from msg.sender to the account
                address(collateralManager), 
                uint256(collateralDelta)
            ), "USD2: collateral transfer failed");
            collateralManager.deposit(account);
        } else if (collateralDelta < 0) {
            // Withdraw collateral
            collateralManager.withdraw(
                uint256(-collateralDelta), 
                msg.sender, // we withdraw to msg.sender from the account
                account
            );
        }

        // Handle debt changes
        if (debtDelta > 0) {
            // Borrow
            if(collateralManager.isRedeemable(account)) {
                uint256 amount = uint256(debtDelta);
                uint256 shares = totalFreeDebtShares == 0 ? amount : mulDivUp(amount, totalFreeDebtShares, totalFreeDebt);
                freeDebtShares[account] += shares;
                totalFreeDebt += amount;
                totalFreeDebtShares += shares;
            } else {
                uint256 amount = uint256(debtDelta);
                uint256 shares = totalPaidDebtShares == 0 ? amount : mulDivUp(amount, totalPaidDebtShares, totalPaidDebt);
                paidDebtShares[account] += shares;
                totalPaidDebt += amount;
                totalPaidDebtShares += shares;
            }
            _mint(msg.sender, uint256(debtDelta)); // we mint to msg.sender from the account's credit
        } else if (debtDelta < 0) {
            // Repay
            uint256 amount = debtDelta == type(int256).min ? getDebtOf(account) : uint256(-debtDelta);

            if(collateralManager.isRedeemable(account)) {
                uint256 shares = convertToShares(amount, totalFreeDebt, totalFreeDebtShares);
                freeDebtShares[account] -= shares;
                totalFreeDebt -= amount;
                totalFreeDebtShares -= shares;
            } else {
                uint256 shares = convertToShares(amount, totalPaidDebt, totalPaidDebtShares);
                paidDebtShares[account] -= shares;
                totalPaidDebt -= amount;
                totalPaidDebtShares -= shares;
            }
            _burn(msg.sender, amount); // we burn from msg.sender to repay the account's credit
        }

        // Skip invariants if user does not reduce collateral AND does not increase debt
        if(collateralDelta >= 0 && debtDelta <= 0) return;

        // Enforce invariants
        require(msg.sender == account || delegations[account][msg.sender], "USD2: not authorized");
        uint256 debtBalance = getDebtOf(account);
        if(debtBalance == 0) return;
        uint256 collateralBalance = collateralManager.collateralOf(account);
        uint256 price = getCollateralPrice();
        uint256 borrowingPower = price * collateralBalance * COLLATERAL_FACTOR_BPS / 1e18 / 10000;
        require(borrowingPower >= debtBalance, "USD2: unsafe position");

        emit PositionAdjusted(account, collateralDelta, debtDelta);
    }

    /// @notice Overloaded function that adjusts a user's collateral, debt position and opts them into/out of redeemable state
    /// @param account The account whose position is being adjusted
    /// @param collateralDelta The change in collateral amount (positive for deposit, negative for withdrawal)
    /// @param debtDelta The change in debt amount (positive for borrow, negative for repay)
    /// @param isRedeemable True to opt in to redeemable state, false to opt out
    function adjust(address account, int256 collateralDelta, int256 debtDelta, bool isRedeemable) external {
        if(isRedeemable) {
            optInRedemptions(account);
        } else {
            optOutRedemptions(account);
        }
        adjust(account, collateralDelta, debtDelta);
    }

    function getLiquidatableDebt(address borrower) public view returns (uint liquidatableDebt) {
        // check liquidation condition
        uint collateralBalance = collateralManager.collateralOf(borrower);
        uint price = getCollateralPrice();
        uint borrowingPower = price * collateralBalance * COLLATERAL_FACTOR_BPS / 1e18 / 10000;
        uint debtBalance = getDebtOf(borrower);
        if(borrowingPower > debtBalance) return 0;
        // liquidate only the amount of debt that is above the borrowing power
        liquidatableDebt = debtBalance - borrowingPower;
        // liquidate at least MIN_LIQUIDATION_DEBT (or the entire debt if it's less than MIN_LIQUIDATION_DEBT)
        if(liquidatableDebt < MIN_LIQUIDATION_DEBT) liquidatableDebt = debtBalance < MIN_LIQUIDATION_DEBT ? debtBalance : MIN_LIQUIDATION_DEBT;
    }

    /// @notice Liquidates an unsafe position
    /// @param borrower The account to be liquidated
    /// @param repayAmount The amount of debt to repay
    /// @param minCollateralOut The minimum amount of collateral to receive
    /// @return The amount of collateral received
    function liquidate(address borrower, uint repayAmount, uint minCollateralOut) external returns(uint) {
        accrueInterest();

        require(repayAmount > 0, "USD2: repay amount must be greater than 0");

        // check liquidation condition
        uint liquidatableDebt = getLiquidatableDebt(borrower);
        require(liquidatableDebt >= repayAmount, "USD2: insufficient liquidatable debt");

        // record debt before repayment
        uint debtBefore = getDebtOf(borrower);

        // apply repayment
        if(collateralManager.isRedeemable(borrower)) {
            uint shares = convertToShares(repayAmount, totalFreeDebt, totalFreeDebtShares);
            require(shares > 0, "USD2: insufficient debt shares");
            freeDebtShares[borrower] -= shares;
            totalFreeDebt -= repayAmount;
            totalFreeDebtShares -= shares;
        } else {
            uint shares = convertToShares(repayAmount, totalPaidDebt, totalPaidDebtShares);
            require(shares > 0, "USD2: insufficient debt shares");
            paidDebtShares[borrower] -= shares;
            totalPaidDebt -= repayAmount;
            totalPaidDebtShares -= shares;
        }

        // calculate collateral reward
        uint collateralBalance = collateralManager.collateralOf(borrower);
        // liquidator gets the same % of collateral as the debt they repay (e.g. repaying 1% of debt gets them 1% of collateral)
        uint collateralReward = collateralBalance * repayAmount / debtBefore;
        require(collateralReward >= minCollateralOut, "USD2: insufficient collateral out");

        if(collateralReward > 0) {
            collateralManager.withdraw(collateralReward, msg.sender, borrower);
        }
        _burn(msg.sender, repayAmount);
        // try to write off remaining debt
        writeOff(borrower);
        emit Liquidated(borrower, msg.sender, repayAmount, collateralReward);
        return collateralReward;
    }

    /// @notice Redistributes excess debt of undercollateralized accounts among other borrowers
    /// @param borrower The account in potentiallyundercollateralized state
    /// @dev This function is called by liquidate() when a borrower's position is undercollateralized. It should never revert to avoid liquidation failure.
    function writeOff(address borrower) public {
        accrueInterest();
        // check for write off
        uint debt = getDebtOf(borrower);
        if(debt > 0) {
            uint collateralBalance = collateralManager.collateralOf(borrower);
            uint price = getCollateralPrice();
            uint collateralValue = price * collateralBalance / 1e18;
            if(collateralValue < debt) {
                // 1. delete all of the borrower's debt
                bool isRedeemable = collateralManager.isRedeemable(borrower);
                if(isRedeemable) {
                    uint shares = convertToShares(debt, totalFreeDebt, totalFreeDebtShares);
                    totalFreeDebtShares -= shares;
                    freeDebtShares[borrower] = 0;
                    totalFreeDebt -= debt;
                } else {
                    uint shares = convertToShares(debt, totalPaidDebt, totalPaidDebtShares);
                    totalPaidDebtShares -= shares;
                    paidDebtShares[borrower] = 0;
                    totalPaidDebt -= debt;
                }
                // 2. redistribute excess debt among remaining borrowers
                uint256 totalDebt = totalFreeDebt + totalPaidDebt;
                uint256 excessDebt = debt - collateralValue;
                if (totalDebt > 0) {
                    uint256 freeDebtIncrease = excessDebt * totalFreeDebt / totalDebt;
                    uint256 paidDebtIncrease = excessDebt - freeDebtIncrease;

                    totalFreeDebt += freeDebtIncrease;
                    totalPaidDebt += paidDebtIncrease;
                }
                // 3. assign the borrower a new debt equal to his collateral value
                if(isRedeemable) {
                    uint shares = convertToShares(collateralValue, totalFreeDebt, totalFreeDebtShares);
                    totalFreeDebtShares += shares;
                    freeDebtShares[borrower] = shares;
                    totalFreeDebt += collateralValue;
                } else {
                    uint shares = convertToShares(collateralValue, totalPaidDebt, totalPaidDebtShares);
                    totalPaidDebtShares += shares;
                    paidDebtShares[borrower] = shares;
                    totalPaidDebt += collateralValue;
                }
                emit WrittenOff(borrower, msg.sender, excessDebt, collateralBalance);
            }
        }
    }

    /// @notice Calculates the amount of collateral received for redeeming USD2
    /// @param amountIn The amount of USD2 to redeem
    /// @return amountOut The amount of collateral to receive
    function getRedeemAmountOut(uint amountIn) public view returns (uint amountOut) {
        if(amountIn > totalFreeDebt) return 0; // can't redeem more than free debt
        uint price = getCollateralPrice();
        // multiply amountIn by price then apply redeem fee to amountIn
        amountOut = amountIn * 1e18 * (10000 - redeemFeeBps) / price / 10000;
    }

    /// @notice Redeems USD2 for collateral at current market price minus a fee
    /// @param amountIn The amount of USD2 to redeem
    /// @param minAmountOut The minimum amount of collateral to receive
    /// @return amountOut The amount of collateral received
    /// @dev Redemptions requires sufficient redeemable collateral to seize and free debt to repay
    function redeem(uint amountIn, uint minAmountOut) external returns (uint amountOut) {
        accrueInterest();

        // calculate amountOut
        amountOut = getRedeemAmountOut(amountIn);
        require(amountOut >= minAmountOut, "USD2: insufficient amount out");

        // repay on behalf of free debtors
        totalFreeDebt -= amountIn; // can this be abused in a share inflation attack?
        _burn(msg.sender, amountIn);

        // pay caller from redeemable collateral
        collateralManager.seize(amountOut, msg.sender);

        emit Redeemed(msg.sender, amountIn, amountOut);
        return amountOut;
    }

    /// @notice Opts into the collateral redemption system, converting paid debt to free debt
    /// @param account The account to opt in
    /// @dev This function is called by the account itself or by a delegatee
    function optInRedemptions(address account) public {
        require(msg.sender == account || delegations[account][msg.sender], "USD2: not authorized");
        accrueInterest();
        collateralManager.setRedeemable(account, true);

        // convert paid debt to free debt
        uint paidShares = paidDebtShares[account];
        if(paidShares == 0) return;
        uint debt = mulDivUp(paidShares, totalPaidDebt, totalPaidDebtShares);
        require(debt > 0, "USD2: insufficient debt");
        paidDebtShares[account] = 0;
        totalPaidDebt -= debt;
        totalPaidDebtShares -= paidShares;
        uint freeDebtSupply = totalFreeDebtShares; // Saves an extra SLOAD if totalFreeDebtShares is non-zero.
        uint freeShares = freeDebtSupply == 0 ? debt : mulDivUp(debt, freeDebtSupply, totalFreeDebt);
        freeDebtShares[account] += freeShares;
        totalFreeDebt += debt;
        totalFreeDebtShares += freeShares;
        // redemption status events are tracked in CollateralManager
    }

    /// @notice Opts out of the collateral redemption system, converting free debt to paid debt
    /// @param account The account to opt out
    /// @dev This function is called by the account itself or by a delegatee
    function optOutRedemptions(address account) public {
        require(msg.sender == account || delegations[account][msg.sender], "USD2: not authorized");
        accrueInterest();
        collateralManager.setRedeemable(account, false);

        // convert free debt to paid debt
        uint freeShares = freeDebtShares[account];
        if(freeShares == 0) return;
        uint debt = mulDivDown(freeShares, totalFreeDebt, totalFreeDebtShares);
        require(debt > 0, "USD2: insufficient debt");
        freeDebtShares[account] = 0;
        totalFreeDebt -= debt;
        totalFreeDebtShares -= freeShares;
        uint paidDebtSupply = totalPaidDebtShares; // Saves an extra SLOAD if totalPaidDebtShares is non-zero.
        uint paidShares = paidDebtSupply == 0 ? debt : mulDivUp(debt, paidDebtSupply, totalPaidDebt);
        paidDebtShares[account] += paidShares;
        totalPaidDebt += debt;
        totalPaidDebtShares += paidShares;
        // redemption status events are tracked in CollateralManager
    }

    function pullLocalFees() external onlyOperator {
        accrueInterest();
        _mint(msg.sender, accruedLocalFees);
        accruedLocalFees = 0;
    }

    function pullGlobalFees(address _to) external {
        accrueInterest();
        require(msg.sender == factory, "Only factory can pull global fees");
        _mint(_to, accruedGlobalFees);
        accruedGlobalFees = 0;
    }

}
