// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "lib/solmate/src/tokens/ERC20.sol";
import "lib/solmate/src/utils/SignedWadMath.sol";

interface ICollateral {
    function transferFrom(address sender, address recipient, uint amount) external returns (bool);
    function transfer(address recipient, uint amount) external returns (bool);
}

interface IChainlinkFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint, uint, uint80);
}

contract USD2 is ERC20 {

    struct ShareData {
        uint128 collateral;
        uint128 shares;
    }

    struct AccrueInterestData {
        uint96 lastBorrowRateMantissa;
        uint64 lastAccrue;
        uint64 expRate;
        uint16 targetFreeDebtRatioStartBps;
        uint16 targetFreeDebtRatioEndBps;
    }


    uint public collateralFactorBps = 8500;
    uint public liqIncentiveBps = 1000;
    uint public writeOffIncentiveBps = 2500;
    uint public redeemFeeBps = 30; // 0.3%
    uint public immutable IMMUTABILITY_DEADLINE;
    uint internal constant MAX_UINT256 = 2**256 - 1;
    ICollateral public immutable collateral;
    IChainlinkFeed public immutable feed;
    address public sUSD2;
    address public operator;

    // collateral state
    ShareData public totalRedeemable;
    mapping(address => bool) public redeemableBorrowers;
    mapping(address => uint128) public redeemableCollateralShares;
    ShareData public totalNonRedeemable;
    mapping(address => uint128) public nonRedeemableCollateralShares;

    // debt state
    uint public totalFreeDebt;
    uint public totalFreeDebtShares;
    mapping(address => uint) public freeDebtShares;
    uint public totalPaidDebt;
    uint public totalPaidDebtShares;
    mapping(address => uint) public paidDebtShares;

    // interest state
    uint64 private immutable WAD_LN2 = uint64(uint(wadLn(2*1e18)));
    AccrueInterestData public accrueInterestData = AccrueInterestData(uint96(1e16), uint64(0), uint64(uint((wadLn(2*1e18) / 7 days))), 2000, 4000);

    constructor(address _collateral, address _feed, address _operator) ERC20("USD2", "USD2", 18) {
        collateral = ICollateral(_collateral);
        feed = IChainlinkFeed(_feed);
        operator = _operator;
        IMMUTABILITY_DEADLINE = block.timestamp + 365 days;
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

    function setHalfLife(uint64 _halfLife) external onlyOperator beforeDeadline {
        require(_halfLife > 0, "USD2: invalid half-life");
        accrueInterestData.expRate = WAD_LN2 / _halfLife;
    }

    function setCollateralFactorBps(uint _collateralFactorBps) external onlyOperator beforeDeadline {
        require(_collateralFactorBps <= 10000, "USD2: invalid collateral factor");
        collateralFactorBps = _collateralFactorBps;
    }

    function setLiqIncentiveBps(uint _liqIncentiveBps) external onlyOperator beforeDeadline {
        require(_liqIncentiveBps <= 10000, "USD2: invalid liquidation incentive");
        liqIncentiveBps = _liqIncentiveBps;
    }

    function setWriteOffIncentiveBps(uint _writeOffIncentiveBps) external onlyOperator beforeDeadline {
        require(_writeOffIncentiveBps <= 10000, "USD2: invalid write-off incentive");
        writeOffIncentiveBps = _writeOffIncentiveBps;
    }

    function setTargetFreeDebtRatioRangeBps(uint16 _start, uint16 _end) external onlyOperator beforeDeadline {
        require(_start <= _end, "USD2: invalid target free debt ratio range");
        require(_end <= 10000, "USD2: invalid target free debt ratio range");
        accrueInterestData.targetFreeDebtRatioStartBps = _start;
        accrueInterestData.targetFreeDebtRatioEndBps = _end;
    }

    function setRedeemFeeBps(uint _redeemFeeBps) external onlyOperator beforeDeadline {
        require(_redeemFeeBps < 10000, "USD2: invalid redeem fee");
        redeemFeeBps = _redeemFeeBps;
    }

    function mulDivDown(
        uint x,
        uint y,
        uint denominator
    ) internal pure returns (uint z) {
        /// @solidity memory-safe-assembly
        assembly {
            // Equivalent to require(denominator != 0 && (y == 0 || x <= type(uint).max / y))
            if iszero(mul(denominator, iszero(mul(y, gt(x, div(MAX_UINT256, y)))))) {
                revert(0, 0)
            }

            // Divide x * y by the denominator.
            z := div(mul(x, y), denominator)
        }
    }

    function mulDivUp(
        uint x,
        uint y,
        uint denominator
    ) internal pure returns (uint z) {
        /// @solidity memory-safe-assembly
        assembly {
            // Equivalent to require(denominator != 0 && (y == 0 || x <= type(uint).max / y))
            if iszero(mul(denominator, iszero(mul(y, gt(x, div(MAX_UINT256, y)))))) {
                revert(0, 0)
            }

            // If x * y modulo the denominator is strictly greater than 0,
            // 1 is added to round up the division of x * y by the denominator.
            z := add(gt(mod(mul(x, y), denominator), 0), div(mul(x, y), denominator))
        }
    }

    function expRate() external view returns(uint) {
        return uint(accrueInterestData.expRate);
    }

    function targetFreeDebtRatioStartBps() external view returns(uint) {
        return uint(accrueInterestData.targetFreeDebtRatioStartBps);
    }

    function targetFreeDebtRatioEndBps() external view returns(uint) {
        return uint(accrueInterestData.targetFreeDebtRatioEndBps);
    }

    function getCollateralOf(address borrower) public view returns (uint128) {
        if(redeemableBorrowers[borrower]) {
            return convertToAssets128(redeemableCollateralShares[borrower], totalRedeemable.collateral, totalRedeemable.shares);
        } else {
            return convertToAssets128(nonRedeemableCollateralShares[borrower], totalNonRedeemable.collateral, totalNonRedeemable.shares);
        }
    }

    function getDebtOf(address borrower) public view returns (uint) {
        if(redeemableBorrowers[borrower]) {
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

    function convertToAssets128(uint128 shares, uint128 totalAssets, uint128 sharesSupply) internal pure returns (uint128) {
        return sharesSupply == 0 ? shares : uint128(mulDivDown(shares, totalAssets, sharesSupply));
    }

    function convertToShares(uint assets, uint totalAssets, uint sharesSupply) internal pure returns (uint) {
        return sharesSupply == 0 ? assets : mulDivDown(assets, sharesSupply, totalAssets);
    }

    function convertToShares128(uint128 assets, uint128 totalAssets, uint128 sharesSupply) internal pure returns (uint128) {
        return sharesSupply == 0 ? assets : uint128(mulDivDown(assets, sharesSupply, totalAssets));
    }

    function calculateRate(
        uint _lastRate,
        uint _timeElapsed,
        uint _expRate,
        uint _freeDebtRatioBps,
        uint _targetFreeDebtRatioStartBps,
        uint _targetFreeDebtRatioEndBps
        ) internal pure returns (uint currBorrowRate, uint integral) {
        uint growthDecay = uint(wadExp(int(_expRate * _timeElapsed)));
        if(_freeDebtRatioBps < _targetFreeDebtRatioStartBps) {
            currBorrowRate = _lastRate * growthDecay / 1e18;
            integral = (currBorrowRate - _lastRate) * 1e18 / _expRate;
        } else if(_freeDebtRatioBps > _targetFreeDebtRatioEndBps) {
            currBorrowRate = _lastRate * 1e18 / growthDecay;
            integral =  (_lastRate - currBorrowRate) * 1e18 / _expRate;
        } else {
            currBorrowRate = _lastRate;
            integral = _lastRate * _timeElapsed;
        }
    
    }

    function accrueInterest() public {
        uint timeElapsed = block.timestamp - accrueInterestData.lastAccrue;
        if(timeElapsed == 0) return;

        // calculate rate
        (uint currBorrowRate, uint rateIntegral) = calculateRate(
            accrueInterestData.lastBorrowRateMantissa,
            timeElapsed,
            accrueInterestData.expRate,
            freeDebtRatioBps(),
            accrueInterestData.targetFreeDebtRatioStartBps,
            accrueInterestData.targetFreeDebtRatioEndBps
        );
    
        // update debt
        uint interest = totalPaidDebt * rateIntegral / 1e18;

        // update debt
        totalPaidDebt += interest;
        if(interest > 0) _mint(sUSD2, interest);
        accrueInterestData.lastAccrue = uint64(block.timestamp);
        accrueInterestData.lastBorrowRateMantissa = uint96(currBorrowRate);
    }

    function freeDebtRatioBps() public view returns(uint) {
        uint _totalFreeDebt = totalFreeDebt;
        return _totalFreeDebt == 0 ? 0 : _totalFreeDebt * 10000 / (_totalFreeDebt + totalPaidDebt);
    }

    function depositCollateral(uint128 amount) external {
        accrueInterest();
        if(redeemableBorrowers[msg.sender]) {
            uint128 shares = convertToShares128(amount, totalRedeemable.collateral, totalRedeemable.shares);
            require(shares > 0, "USD2: insufficient shares");
            redeemableCollateralShares[msg.sender] += shares;
            totalRedeemable.collateral += amount;
            totalRedeemable.shares += shares;
        } else {
            uint128 shares = convertToShares128(amount, totalNonRedeemable.collateral, totalNonRedeemable.shares);
            require(shares > 0, "USD2: insufficient shares");
            nonRedeemableCollateralShares[msg.sender] += shares;
            totalNonRedeemable.collateral += amount;
            totalNonRedeemable.shares += shares;
        }
        require(collateral.transferFrom(msg.sender, address(this), amount), "USD2: transfer failed");
    }

    function withdrawCollateral(uint128 amount) external {
        accrueInterest();
        if(redeemableBorrowers[msg.sender]) {
            uint128 supply = totalRedeemable.shares; // Saves an extra SLOAD if totalRedeemable.shares is non-zero.
            uint128 shares = supply == 0 ? amount : uint128(mulDivUp(amount, supply, totalRedeemable.collateral));
            require(shares > 0, "USD2: insufficient shares");
            redeemableCollateralShares[msg.sender] -= shares;
            totalRedeemable.collateral -= uint128(amount);
            totalRedeemable.shares -= shares;
        } else {
            uint supply = totalNonRedeemable.shares; // Saves an extra SLOAD if totalNonRedeemable.shares is non-zero.
            uint128 shares = supply == 0 ? amount : uint128(mulDivUp(amount, supply, totalNonRedeemable.shares));
            require(shares > 0, "USD2: insufficient shares");
            nonRedeemableCollateralShares[msg.sender] -= shares;
            totalNonRedeemable.collateral -= amount;
            totalNonRedeemable.shares -= shares;
        }
        uint collateralBalance = getCollateralOf(msg.sender);
        uint price = getCollateralPrice();
        uint borrowingPower = price * collateralBalance * collateralFactorBps / 1e18 / 10000;
        uint debtBalance = getDebtOf(msg.sender);
        require(borrowingPower >= debtBalance, "USD2: insufficient borrowing power");
        require(collateral.transfer(msg.sender, amount), "USD2: collateral transfer failed");
    }

    function borrow(uint amount) external {
        accrueInterest();
        if(redeemableBorrowers[msg.sender]) {
            uint supply = totalFreeDebtShares; // Saves an extra SLOAD if totalFreeDebtShares is non-zero.
            uint shares = supply == 0 ? amount : mulDivUp(amount, supply, totalFreeDebt);
            require(shares > 0, "USD2: insufficient shares");
            freeDebtShares[msg.sender] += shares;
            totalFreeDebt += amount;
            totalFreeDebtShares += shares;
        } else {
            uint supply = totalPaidDebtShares; // Saves an extra SLOAD if totalPaidDebtShares is non-zero.
            uint shares = supply == 0 ? amount : mulDivUp(amount, supply, totalPaidDebt);
            require(shares > 0, "USD2: insufficient shares");
            paidDebtShares[msg.sender] += shares;
            totalPaidDebt += amount;
            totalPaidDebtShares += shares;
        }
        uint collateralBalance = getCollateralOf(msg.sender);
        uint price = getCollateralPrice();
        uint borrowingPower = price * collateralBalance * collateralFactorBps / 1e18 / 10000;
        uint debtBalance = getDebtOf(msg.sender);
        require(borrowingPower >= debtBalance, "USD2: insufficient borrowing power");
        _mint(msg.sender, amount);
    }

    function repay(uint amount) external {
        accrueInterest();
        if(redeemableBorrowers[msg.sender]) {
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
        uint collateralBalance = getCollateralOf(borrower);
        uint price = getCollateralPrice();
        uint borrowingPower = price * collateralBalance * collateralFactorBps / 1e18 / 10000;
        uint debtBalance = getDebtOf(borrower);
        require(borrowingPower < debtBalance, "USD2: excessive borrowing power");

        // apply repayment
        if(redeemableBorrowers[borrower]) {
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

        // reduce collateral
        if(redeemableBorrowers[borrower]) {
            uint128 supply = totalRedeemable.shares; // Saves an extra SLOAD if totalRedeemable.shares is non-zero.
            uint128 shares = uint128(supply == 0 ? collateralReward : mulDivUp(collateralReward, supply, totalRedeemable.collateral));
            require(shares > 0, "USD2: insufficient collateral shares");
            redeemableCollateralShares[borrower] -= shares;
            totalRedeemable.collateral -= uint128(collateralReward);
            totalRedeemable.shares -= shares;
        } else {
            uint128 supply = totalNonRedeemable.shares; // Saves an extra SLOAD if totalNonRedeemable.shares is non-zero.
            uint128 shares = uint128(supply == 0 ? collateralReward : mulDivUp(collateralReward, supply, totalNonRedeemable.shares));
            require(shares > 0, "USD2: insufficient collateral shares");
            nonRedeemableCollateralShares[borrower] -= shares;
            totalNonRedeemable.collateral -= uint128(collateralReward);
            totalNonRedeemable.shares -= shares;
        }

        require(collateral.transfer(msg.sender, collateralReward));
        _burn(msg.sender, repayAmount);
            return collateralReward;
    }

    function writeOff(address borrower) external {
        accrueInterest();

        // check write off condition
        uint collateralBalance = getCollateralOf(borrower);
        uint price = getCollateralPrice();
        uint collateralValue = price * collateralBalance / 1e18; // no CF check in this case
        uint debtBalance = getDebtOf(borrower);
        require(collateralValue < debtBalance, "USD2: excessive collateral value");

        // delete their debt before redistributing it
        if(redeemableBorrowers[borrower]) {
            totalFreeDebtShares -= freeDebtShares[borrower];
            freeDebtShares[borrower] = 0;
            totalFreeDebt -= debtBalance;
        } else {
            totalPaidDebtShares -= paidDebtShares[borrower];
            paidDebtShares[borrower] = 0;
            totalPaidDebt -= debtBalance;
        }

        // distribute loss to both buckets of debt pro-rata
        uint freeDebtLoss = debtBalance * totalFreeDebt / (totalFreeDebt + totalPaidDebt);
        uint paidDebtLoss = debtBalance - freeDebtLoss;
        totalFreeDebt += freeDebtLoss;
        totalPaidDebt += paidDebtLoss;

        // now delete their collateral before redistributing it
        if(redeemableBorrowers[borrower]) {
            totalRedeemable.shares -= redeemableCollateralShares[borrower];
            redeemableCollateralShares[borrower] = 0;
            totalRedeemable.collateral -= uint128(collateralBalance);
        } else {
            totalNonRedeemable.shares -= nonRedeemableCollateralShares[borrower];
            nonRedeemableCollateralShares[borrower] = 0;
            totalNonRedeemable.collateral -= uint128(collateralBalance);
        }

        uint callerReward = collateralBalance * writeOffIncentiveBps / 10000;
        uint borrowersReward = collateralBalance - callerReward;
        uint redeemableBorrowersReward = borrowersReward * totalRedeemable.collateral / (totalRedeemable.collateral + totalNonRedeemable.collateral);
        uint nonRedeemableBorrowersReward = borrowersReward - redeemableBorrowersReward;
        totalRedeemable.collateral += uint128(redeemableBorrowersReward);
        totalNonRedeemable.collateral += uint128(nonRedeemableBorrowersReward);
        require(collateral.transfer(msg.sender, callerReward));
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
        totalRedeemable.collateral -= uint128(amountOut); // can this be abused in a share inflation attack?
        require(collateral.transfer(msg.sender, amountOut));
        }

    function optInRedemptions() external {
        accrueInterest();
        // convert non-redeemable shares to redeemable shares
        uint128 amount = convertToAssets128(nonRedeemableCollateralShares[msg.sender], totalNonRedeemable.collateral, totalNonRedeemable.shares);
        uint128 shares = convertToShares128(amount, totalRedeemable.collateral, totalRedeemable.shares);
        // delete old state
        totalNonRedeemable.collateral -= amount;
        totalNonRedeemable.shares -= nonRedeemableCollateralShares[msg.sender];
        nonRedeemableCollateralShares[msg.sender] = 0;
        // create new state
        redeemableCollateralShares[msg.sender] += shares;
        totalRedeemable.collateral += amount;
        totalRedeemable.shares += shares;
        redeemableBorrowers[msg.sender] = true;

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
        // convert redeemable shares to non-redeemable shares
        uint128 amount = convertToAssets128(redeemableCollateralShares[msg.sender], totalRedeemable.collateral, totalRedeemable.shares);
        uint128 shares = convertToShares128(amount, totalRedeemable.collateral, totalRedeemable.shares);
        // delete old state
        totalRedeemable.collateral -= amount;
        totalRedeemable.shares -= redeemableCollateralShares[msg.sender];
        redeemableCollateralShares[msg.sender] = 0;
        // create new state
        nonRedeemableCollateralShares[msg.sender] += shares;
        totalNonRedeemable.collateral += amount;
        totalNonRedeemable.shares += shares;
        redeemableBorrowers[msg.sender] = false;

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
