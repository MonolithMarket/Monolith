// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "lib/solmate/src/tokens/ERC20.sol";
import "lib/solmate/src/utils/SignedWadMath.sol";
import "./CollateralManager.sol";

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
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
}

contract USD2 is ERC20 {

    uint public collateralFactorBps = 8500;
    uint public liqIncentiveBps = 1000;
    uint public targetFreeDebtRatioStartBps = 2000;
    uint public targetFreeDebtRatioEndBps = 4000;
    uint public redeemFeeBps = 30; // 0.3%
    uint public immutable IMMUTABILITY_DEADLINE;
    uint internal constant MAX_UINT256 = 2**256 - 1;
    uint internal constant MIN_RATE = 5e15; // 0.5%
    ICollateral public immutable collateral;
    IChainlinkFeed public immutable feed;
    IsUSD2 public sUSD2;
    address public operator;
    CollateralManager public immutable collateralManager;

    mapping(address => mapping(address => bool)) public delegations;

    // debt state
    uint public totalFreeDebt;
    uint public totalFreeDebtShares;
    mapping(address => uint) public freeDebtShares;
    uint public totalPaidDebt;
    uint public totalPaidDebtShares;
    mapping(address => uint) public paidDebtShares;

    // interest state
    uint private immutable WAD_LN2 = uint(wadLn(2*1e18));
    uint public expRate = uint(wadLn(2*1e18)) / 7 days; // 7 days half-life
    uint public lastBorrowRateMantissa = 1e16; // 1%
    uint public lastAccrue;

    constructor(address _collateral, address _feed, address _operator) ERC20("USD2", "USD2", 18) {
        collateral = ICollateral(_collateral);
        feed = IChainlinkFeed(_feed);
        operator = _operator;
        IMMUTABILITY_DEADLINE = block.timestamp + 365 days;
        collateralManager = new CollateralManager(_collateral);
    }

    modifier onlyOperator() {
        require(msg.sender == operator, "USD2: not operator");
        _;
    }

    modifier beforeDeadline() {
        require(block.timestamp < IMMUTABILITY_DEADLINE, "USD2: immutability deadline passed");
        _;
    }

    function initialize(address _sUSD2) external {
        require(sUSD2 == IsUSD2(address(0)), "USD2: already initialized");
        sUSD2 = IsUSD2(_sUSD2);
        USD2(address(this)).approve(address(sUSD2), type(uint).max);
    }

    function burn(uint amount) external {
        _burn(msg.sender, amount);
    }

    function setOperator(address _operator) external {
        require(msg.sender == operator, "USD2: not operator");
        operator = _operator;
    }

    function setHalfLife(uint _halfLife) external onlyOperator beforeDeadline {
        accrueInterest();
        require(_halfLife > 0, "USD2: invalid half-life");
        expRate = WAD_LN2 / _halfLife;
    }

    function setCollateralFactorBps(uint _collateralFactorBps) external onlyOperator beforeDeadline {
        require(_collateralFactorBps <= 10000, "USD2: invalid collateral factor");
        collateralFactorBps = _collateralFactorBps;
    }

    function setLiqIncentiveBps(uint _liqIncentiveBps) external onlyOperator beforeDeadline {
        require(_liqIncentiveBps <= 10000, "USD2: invalid liquidation incentive");
        liqIncentiveBps = _liqIncentiveBps;
    }

    function setTargetFreeDebtRatioRangeBps(uint _start, uint _end) external onlyOperator beforeDeadline {
        require(_start <= _end, "USD2: invalid target free debt ratio range");
        require(_end <= 10000, "USD2: invalid target free debt ratio range");
        accrueInterest();
        targetFreeDebtRatioStartBps = _start;
        targetFreeDebtRatioEndBps = _end;
    }

    function setRedeemFeeBps(uint _redeemFeeBps) external onlyOperator beforeDeadline {
        require(_redeemFeeBps < 10000, "USD2: invalid redeem fee");
        redeemFeeBps = _redeemFeeBps;
    }

    function getFreeDebtRatio() public view returns (uint) {
        return totalFreeDebt == 0 ? 0 : totalFreeDebt * 10000 / (totalFreeDebt + totalPaidDebt);
    }

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

    function getDebtOf(address borrower) public view returns (uint) {
        if(collateralManager.isRedeemable(borrower)) {
            return convertToAssets(freeDebtShares[borrower], totalFreeDebt, totalFreeDebtShares);
        } else {
            return convertToAssets(paidDebtShares[borrower], totalPaidDebt, totalPaidDebtShares);
        }
    }

    function getCollateralPrice() public view returns (uint) {
        (,int256 price,,,) = feed.latestRoundData();
        // We assume the collateral token is 18 decimals AND that the feed is 18 decimals or lower.
        uint8 decimals = 18 - feed.decimals();
        return uint(price) * (10**decimals);
    }

    function convertToAssets(uint shares, uint totalAssets, uint sharesSupply) internal pure returns (uint) {
        return sharesSupply == 0 ? shares : mulDivDown(shares, totalAssets, sharesSupply);
    }

    function convertToShares(uint assets, uint totalAssets, uint sharesSupply) internal pure returns (uint) {
        return sharesSupply == 0 ? assets : mulDivDown(assets, sharesSupply, totalAssets);
    }

    function calculateRate(
        uint _lastRate,
        uint _timeElapsed,
        uint _expRate,
        uint _lastFreeDebtRatioBps,
        uint _targetFreeDebtRatioStartBps,
        uint _targetFreeDebtRatioEndBps
        ) internal pure returns (uint currBorrowRate, uint integral) {
        uint growthDecay = uint(wadExp(int(_expRate * _timeElapsed)));
        if(_lastFreeDebtRatioBps < _targetFreeDebtRatioStartBps) {
            currBorrowRate = _lastRate * growthDecay / 1e18;
            integral = (currBorrowRate - _lastRate) * 1e18 / _expRate;
        } else if(_lastFreeDebtRatioBps > _targetFreeDebtRatioEndBps) {
            currBorrowRate = _lastRate * 1e18 / growthDecay;
            if (currBorrowRate < MIN_RATE) {
                currBorrowRate = MIN_RATE;
                // calculate integral
                if (_lastRate <= MIN_RATE) {
                    // Already at min rate, just use flat rate for entire period
                    integral = MIN_RATE * _timeElapsed;
                } else {
                    // Calculate time until min rate is reached
                    uint timeToMin = uint(wadLn(int(MIN_RATE * 1e18 / _lastRate))) * 1e18 / _expRate;
                    // Decaying integral up to min rate, then add flat rate portion
                    integral = (_lastRate - MIN_RATE) * 1e18 / _expRate + 
                              MIN_RATE * (_timeElapsed - timeToMin);
                }
            } else {
                integral = (_lastRate - currBorrowRate) * 1e18 / _expRate;
            }
        } else {
            currBorrowRate = _lastRate;
            integral = _lastRate * _timeElapsed;
        }
    
    }

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

        if(interest > 0) {
            uint totalStaked = sUSD2.totalAssets();
            if(totalStaked < totalPaidDebt) {
                uint stakedDebt = totalPaidDebt - totalStaked;
                uint stakedInterest = interest * stakedDebt / totalPaidDebt;
                _mint(address(sUSD2), stakedInterest);
                uint remainingInterest = interest - stakedInterest;
                _mint(address(this), remainingInterest);
                sUSD2.deposit(remainingInterest, address(this));

            } else {
                _mint(address(sUSD2), interest);
            }
            totalPaidDebt += interest;
        }

        lastAccrue = block.timestamp;
        lastBorrowRateMantissa = currBorrowRate;
    }

    function delegate(address delegatee, bool isDelegatee) external {
        delegations[msg.sender][delegatee] = isDelegatee;
    }

    function adjust(address account, int256 collateralDelta, int256 debtDelta) external {
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
        uint256 borrowingPower = price * collateralBalance * collateralFactorBps / 1e18 / 10000;
        require(borrowingPower >= debtBalance, "USD2: unsafe position");
    }

    function liquidate(address borrower, uint repayAmount, uint minCollateralOut) external returns(uint) {
        accrueInterest();

        // check liquidation condition
        uint collateralBalance = collateralManager.collateralOf(borrower);
        uint price = getCollateralPrice();
        uint borrowingPower = price * collateralBalance * collateralFactorBps / 1e18 / 10000;
        uint debtBalance = getDebtOf(borrower);
        require(borrowingPower < debtBalance, "USD2: excessive borrowing power");

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
        uint collateralRewardValue = repayAmount * (10000 + liqIncentiveBps) / 10000;
        uint collateralReward = collateralRewardValue * 1e18 / price;
        bool useEntireBalance;
        if(collateralBalance < collateralReward) {
            useEntireBalance = true;
            collateralReward = collateralBalance;
        }
        require(collateralReward >= minCollateralOut, "USD2: insufficient collateral out");

        if(collateralReward > 0) {
            collateralManager.withdraw(useEntireBalance ? type(uint).max : collateralReward, msg.sender, borrower);
        }
        _burn(msg.sender, repayAmount);
        // try to write off remaining debt
        writeOff(borrower);
        return collateralReward;
    }

    function writeOff(address borrower) public {
        accrueInterest();
        // check for write off
        uint debt = getDebtOf(borrower);
        if(debt > 0) {
            uint price = getCollateralPrice();
            uint collateralValue = price * collateralManager.collateralOf(borrower) / 1e18;
            if(collateralValue < debt) {
                // collateral redistribution
                collateralManager.withdraw(type(uint).max, address(collateralManager), borrower);
                collateralManager.sync();
                // debt redistribution
                bool isRedeemable = collateralManager.isRedeemable(borrower);
                if(isRedeemable) {
                    totalFreeDebtShares -= freeDebtShares[borrower];
                    freeDebtShares[borrower] = 0;
                    totalFreeDebt -= debt;
                } else {
                    totalPaidDebtShares -= paidDebtShares[borrower];
                    paidDebtShares[borrower] = 0;
                    totalPaidDebt -= debt;
                }
                uint256 totalDebt = totalFreeDebt + totalPaidDebt;
                if (totalDebt > 0) {
                    uint256 freeDebtIncrease = debt * totalFreeDebt / totalDebt;
                    uint256 paidDebtIncrease = debt - freeDebtIncrease;

                    totalFreeDebt += freeDebtIncrease;
                    totalPaidDebt += paidDebtIncrease;
                }
            }
        }
    }

    function getRedeemAmountOut(uint amountIn) public view returns (uint amountOut) {
        if(amountIn > totalFreeDebt) return 0; // can't redeem more than free debt
        uint price = getCollateralPrice();
        // multiply amountIn by price then apply redeem fee to amountIn
        amountOut = amountIn * 1e18 * (10000 - redeemFeeBps) / price / 10000;
    }

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
    }

    function optInRedemptions(address account) external {
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
    }

    function optOutRedemptions(address account) external {
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
    }

    function addToReserve(uint amount) external {
        USD2(address(this)).transferFrom(msg.sender, address(this), amount);
        sUSD2.deposit(amount, address(this));
    }

    function removeFromReserve(uint amount) external onlyOperator {
        sUSD2.withdraw(amount, msg.sender, address(this));
    }

}
