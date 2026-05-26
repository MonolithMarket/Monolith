// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import "lib/solmate/src/tokens/ERC20.sol";
import "lib/solmate/src/utils/LibString.sol";
import "lib/solmate/src/utils/SafeTransferLib.sol";

interface IUmaOptimisticOracleV3 {
    function defaultCurrency() external view returns (ERC20);
    function defaultLiveness() external view returns (uint64);
    function getMinimumBond(address currency) external view returns (uint256);
    function assertTruth(
        bytes memory claim,
        address asserter,
        address callbackRecipient,
        address escalationManager,
        uint64 liveness,
        ERC20 currency,
        uint256 bond,
        bytes32 identifier,
        bytes32 domainId
    ) external returns (bytes32 assertionId);
    function settleAndGetAssertionResult(bytes32 assertionId) external returns (bool);
}

interface IEventTriggerLender {
    function eventTriggerOperator() external view returns (address);
    function eventTriggerMode() external view returns (bool);
    function enableEventTriggerMode() external;
}

/// @notice UMA OOv3 adapter that activates a Lender's permanent event trigger mode.
contract UmaEventTriggerOracle {
    using SafeTransferLib for ERC20;
    using LibString for uint256;

    bytes32 public constant UMA_ASSERT_TRUTH_IDENTIFIER = bytes32("ASSERT_TRUTH2");
    bytes32 public constant UMA_DOMAIN_ID = keccak256("Monolith.UmaEventTriggerOracle.EventTrigger");
    bytes16 private constant HEX_DIGITS = "0123456789abcdef";

    IUmaOptimisticOracleV3 public immutable optimisticOracleV3;
    address public immutable owner;
    /// @notice Human-readable definition of the off-chain event that permanently activates the lender trigger mode.
    bytes public triggerClaim;

    IEventTriggerLender public lender;

    struct AssertionState {
        address asserter;
        bool resolved;
        bool disputed;
    }

    mapping(bytes32 => AssertionState) public assertions;

    modifier onlyOwner() {
        require(msg.sender == owner, "Unauthorized");
        _;
    }

    constructor(address _optimisticOracleV3, bytes memory _triggerClaim) {
        require(_optimisticOracleV3 != address(0), "Invalid oracle");
        require(_triggerClaim.length > 0, "Invalid claim");
        optimisticOracleV3 = IUmaOptimisticOracleV3(_optimisticOracleV3);
        owner = msg.sender;
        triggerClaim = _triggerClaim;
    }

    /// @notice Binds the adapter to the lender it is allowed to activate.
    /// @dev The lender must have been deployed with this adapter as its immutable eventTriggerOperator.
    function bindLender(address _lender) external onlyOwner {
        require(address(lender) == address(0), "Lender already bound");
        require(_lender != address(0), "Invalid lender");
        require(IEventTriggerLender(_lender).eventTriggerOperator() == address(this), "Invalid event trigger operator");

        lender = IEventTriggerLender(_lender);

        emit LenderBound(_lender);
    }

    /// @notice Posts the UMA bond and asserts that the configured trigger event occurred.
    function assertEventTrigger() external returns (bytes32 assertionId) {
        IEventTriggerLender _lender = lender;
        require(address(_lender) != address(0), "Lender not bound");
        require(!_lender.eventTriggerMode(), "Event trigger mode active");

        ERC20 currency = optimisticOracleV3.defaultCurrency();
        require(address(currency) != address(0), "Invalid currency");

        uint256 bond = optimisticOracleV3.getMinimumBond(address(currency));
        if (bond > 0) {
            currency.safeTransferFrom(msg.sender, address(this), bond);
            currency.safeApprove(address(optimisticOracleV3), 0);
            currency.safeApprove(address(optimisticOracleV3), bond);
        }

        bytes memory claim = _buildClaim(_lender, msg.sender);
        uint64 liveness = optimisticOracleV3.defaultLiveness();
        bytes32 identifier = UMA_ASSERT_TRUTH_IDENTIFIER;

        assertionId = optimisticOracleV3.assertTruth(
            claim, msg.sender, address(this), address(0), liveness, currency, bond, identifier, UMA_DOMAIN_ID
        );

        assertions[assertionId] = AssertionState({asserter: msg.sender, resolved: false, disputed: false});

        emit EventTriggerAsserted(assertionId, msg.sender, address(currency), bond, liveness, identifier);
    }

    /// @notice Convenience wrapper around UMA settlement for assertions created by this adapter.
    function settleAndGetAssertionResult(bytes32 assertionId) external returns (bool) {
        require(assertions[assertionId].asserter != address(0), "Unknown assertion");
        return optimisticOracleV3.settleAndGetAssertionResult(assertionId);
    }

    /// @notice UMA OOv3 callback invoked when an assertion is resolved.
    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external {
        require(msg.sender == address(optimisticOracleV3), "Unauthorized");

        AssertionState storage assertion = assertions[assertionId];
        address asserter = assertion.asserter;
        require(asserter != address(0), "Unknown assertion");
        require(!assertion.resolved, "Assertion already resolved");

        bool activated;
        assertion.resolved = true;

        if (assertedTruthfully) {
            IEventTriggerLender _lender = lender;
            if (address(_lender) != address(0) && !_lender.eventTriggerMode()) {
                _lender.enableEventTriggerMode();
                activated = true;
            }
        } else {
            delete assertions[assertionId];
        }

        emit EventTriggerAssertionResolved(assertionId, asserter, assertedTruthfully, activated);
    }

    /// @notice UMA OOv3 callback invoked when an assertion is disputed.
    function assertionDisputedCallback(bytes32 assertionId) external {
        require(msg.sender == address(optimisticOracleV3), "Unauthorized");

        AssertionState storage assertion = assertions[assertionId];
        address asserter = assertion.asserter;
        require(asserter != address(0), "Unknown assertion");

        assertion.disputed = true;

        emit EventTriggerAssertionDisputed(assertionId, asserter);
    }

    function _buildClaim(IEventTriggerLender _lender, address asserter) internal view returns (bytes memory) {
        return abi.encodePacked(
            "Monolith event trigger assertion. Trigger definition: ",
            triggerClaim,
            ". Chain ID: ",
            uint256(block.chainid).toString(),
            ". Lender: ",
            _addressToString(address(_lender)),
            ". Adapter: ",
            _addressToString(address(this)),
            ". Asserter: ",
            _addressToString(asserter),
            ". Asserted at Unix timestamp: ",
            uint256(block.timestamp).toString(),
            ". The trigger definition is true for this lender on this chain as of the assertion timestamp. ",
            "If the trigger definition is false, ambiguous, unverifiable, or refers to a different lender or chain, resolve as false."
        );
    }

    function _addressToString(address account) internal pure returns (string memory) {
        bytes20 value = bytes20(account);
        bytes memory buffer = new bytes(42);
        buffer[0] = "0";
        buffer[1] = "x";

        for (uint256 i = 0; i < 20; i++) {
            buffer[2 + i * 2] = HEX_DIGITS[uint8(value[i] >> 4)];
            buffer[3 + i * 2] = HEX_DIGITS[uint8(value[i] & 0x0f)];
        }

        return string(buffer);
    }

    event LenderBound(address indexed lender);
    event EventTriggerAsserted(
        bytes32 indexed assertionId,
        address indexed asserter,
        address indexed currency,
        uint256 bond,
        uint64 liveness,
        bytes32 identifier
    );
    event EventTriggerAssertionDisputed(bytes32 indexed assertionId, address indexed asserter);
    event EventTriggerAssertionResolved(
        bytes32 indexed assertionId, address indexed asserter, bool assertedTruthfully, bool activated
    );
}
