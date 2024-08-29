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

contract USD2 is ERC20 {

    uint public collateralFactorBps = 8500;
    uint public liqIncentiveBps = 1000;
    uint public targetFreeDebtRatioStartBps = 2000;
    uint public targetFreeDebtRatioEndBps = 4000;
    uint public redeemFeeBps = 30; // 0.3%
    uint public immutable IMMUTABILITY_DEADLINE;
    uint internal constant MAX_UINT256 = 2**256 - 1;
    ICollateral public immutable collateral;
    IChainlinkFeed public immutable feed;
    address public sUSD2;
    address public operator;
    CollateralManager public immutable collateralManager;

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
        require(sUSD2 == address(0), "USD2: already initialized");
        sUSD2 = _sUSD2;
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
            integral =  (_lastRate - currBorrowRate) * 1e18 / _expRate;
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
    
        // update debt
        uint interest = totalPaidDebt * rateIntegral / 1e18;

        // update debt
        totalPaidDebt += interest;
        if(interest > 0) _mint(sUSD2, interest);
        lastAccrue = block.timestamp;
        lastBorrowRateMantissa = currBorrowRate;
    }

    function depositCollateral(uint amount, address to) external {
        require(collateral.transferFrom(msg.sender, address(collateralManager), amount), "USD2: collateral transfer failed");
        collateralManager.deposit(to);
    }

    function withdrawCollateral(uint amount, address to) external {
        accrueInterest();
        collateralManager.withdraw(amount, to, msg.sender);
        uint collateralBalance = collateralManager.collateralOf(msg.sender);
        uint price = getCollateralPrice();
        uint borrowingPower = price * collateralBalance * collateralFactorBps / 1e18 / 10000;
        uint debtBalance = getDebtOf(msg.sender);
        require(borrowingPower >= debtBalance, "USD2: insufficient borrowing power");
    }

    function borrow(uint amount) external {
        accrueInterest();
        if(collateralManager.isRedeemable(msg.sender)) {
            uint256 supply = totalFreeDebtShares; // Saves an extra SLOAD if totalFreeDebtShares is non-zero.
            uint shares = supply == 0 ? amount : mulDivUp(amount, supply, totalFreeDebt);
            require(shares > 0, "USD2: insufficient shares");
            freeDebtShares[msg.sender] += shares;
            totalFreeDebt += amount;
            totalFreeDebtShares += shares;
        } else {
            uint256 supply = totalPaidDebtShares; // Saves an extra SLOAD if totalPaidDebtShares is non-zero.
            uint shares = supply == 0 ? amount : mulDivUp(amount, supply, totalPaidDebt);
            require(shares > 0, "USD2: insufficient shares");
            paidDebtShares[msg.sender] += shares;
            totalPaidDebt += amount;
            totalPaidDebtShares += shares;
        }
        uint collateralBalance = collateralManager.collateralOf(msg.sender);
        uint price = getCollateralPrice();
        uint borrowingPower = price * collateralBalance * collateralFactorBps / 1e18 / 10000;
        uint debtBalance = getDebtOf(msg.sender);
        require(borrowingPower >= debtBalance, "USD2: insufficient borrowing power");
        _mint(msg.sender, amount);
    }

    function repay(uint amount) external {
        accrueInterest();
        if(collateralManager.isRedeemable(msg.sender)) {
            uint shares = convertToShares(amount, totalFreeDebt, totalFreeDebtShares);
            require(shares > 0, "USD2: insufficient shares");
            freeDebtShares[msg.sender] -= shares;
            totalFreeDebt -= amount;
            totalFreeDebtShares -= shares;
        } else {
            uint shares = convertToShares(amount, totalPaidDebt, totalPaidDebtShares);
            require(shares > 0, "USD2: insufficient shares");
            paidDebtShares[msg.sender] -= shares;
            totalPaidDebt -= amount;
            totalPaidDebtShares -= shares;
        }
        _burn(msg.sender, amount);
    }

    function liquidate(address borrower, uint repayAmount) external returns(uint) {
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

        collateralManager.withdraw(collateralReward, msg.sender, borrower);
        _burn(msg.sender, repayAmount);
        return collateralReward;
    }

    function getRedeemAmountOut(uint amountIn) public view returns (uint amountOut) {
        if(amountIn > totalFreeDebt) return 0; // can't redeem more than free debt
        uint price = getCollateralPrice();
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

    function optInRedemptions() external {
        accrueInterest();
        collateralManager.setRedeemable(msg.sender, true);

        // convert paid debt to free debt
        uint paidShares = paidDebtShares[msg.sender];
        uint debt = mulDivUp(paidShares, totalPaidDebt, totalPaidDebtShares);
        if(paidShares > 0) require(debt > 0, "USD2: insufficient debt");
        paidDebtShares[msg.sender] = 0;
        totalPaidDebt -= debt;
        totalPaidDebtShares -= paidShares;
        uint freeDebtSupply = totalFreeDebtShares; // Saves an extra SLOAD if totalFreeDebtShares is non-zero.
        uint freeShares = freeDebtSupply == 0 ? debt : mulDivUp(debt, freeDebtSupply, totalFreeDebt);
        require(freeShares > 0, "USD2: insufficient free debt shares");
        freeDebtShares[msg.sender] += freeShares;
        totalFreeDebt += debt;
        totalFreeDebtShares += freeShares;
    }

    function optOutRedemptions() external {
        accrueInterest();
        collateralManager.setRedeemable(msg.sender, false);

        // convert free debt to paid debt
        uint freeShares = freeDebtShares[msg.sender];
        uint debt = mulDivDown(freeShares, totalFreeDebt, totalFreeDebtShares);
        if(freeShares > 0) require(debt > 0, "USD2: insufficient debt");
        freeDebtShares[msg.sender] = 0;
        totalFreeDebt -= debt;
        totalFreeDebtShares -= freeShares;
        uint paidDebtSupply = totalPaidDebtShares; // Saves an extra SLOAD if totalPaidDebtShares is non-zero.
        uint paidShares = paidDebtSupply == 0 ? debt : mulDivUp(debt, paidDebtSupply, totalPaidDebt);
        require(paidShares > 0, "USD2: insufficient paid debt shares");
        paidDebtShares[msg.sender] += paidShares;
        totalPaidDebt += debt;
        totalPaidDebtShares += paidShares;
    }

}
