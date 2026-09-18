// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20, IEventTriggerLender, IUmaOptimisticOracleV3, UmaEventTriggerOracle} from "src/UmaEventTriggerOracle.sol";
import {LibString} from "lib/solmate/src/utils/LibString.sol";

interface IUmaCallbackRecipient {
    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external;
    function assertionDisputedCallback(bytes32 assertionId) external;
}

contract UmaCurrencyMock is ERC20 {
    constructor() ERC20("UMA Bond", "BOND", 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract UmaOptimisticOracleV3Mock is IUmaOptimisticOracleV3 {
    ERC20 public defaultCurrency;
    uint64 public defaultLiveness = 7200;
    bytes32 public defaultIdentifier = bytes32("ASSERT_TRUTH");
    uint256 public minimumBond = 100e18;

    uint256 public assertionCount;
    bytes32 public lastAssertionId;
    bytes public lastClaim;
    address public lastCaller;
    address public lastAsserter;
    address public lastCallbackRecipient;
    address public lastEscalationManager;
    uint64 public lastLiveness;
    ERC20 public lastCurrency;
    uint256 public lastBond;
    bytes32 public lastIdentifier;
    bytes32 public lastDomainId;

    mapping(bytes32 => bool) public assertionExists;
    mapping(bytes32 => bool) public assertionSettled;
    mapping(bytes32 => bool) public settlementResult;
    mapping(bytes32 => address) public callbackRecipient;

    constructor(ERC20 _defaultCurrency) {
        defaultCurrency = _defaultCurrency;
    }

    function setMinimumBond(uint256 _minimumBond) external {
        minimumBond = _minimumBond;
    }

    function setSettlementResult(bytes32 assertionId, bool result) external {
        settlementResult[assertionId] = result;
    }

    function getMinimumBond(address) external view returns (uint256) {
        return minimumBond;
    }

    function assertTruth(
        bytes memory claim,
        address asserter,
        address _callbackRecipient,
        address escalationManager,
        uint64 liveness,
        ERC20 currency,
        uint256 bond,
        bytes32 identifier,
        bytes32 domainId
    ) external returns (bytes32 assertionId) {
        if (bond > 0) currency.transferFrom(msg.sender, address(this), bond);

        assertionId = keccak256(abi.encode(claim, asserter, ++assertionCount));
        assertionExists[assertionId] = true;
        callbackRecipient[assertionId] = _callbackRecipient;

        lastAssertionId = assertionId;
        lastClaim = claim;
        lastCaller = msg.sender;
        lastAsserter = asserter;
        lastCallbackRecipient = _callbackRecipient;
        lastEscalationManager = escalationManager;
        lastLiveness = liveness;
        lastCurrency = currency;
        lastBond = bond;
        lastIdentifier = identifier;
        lastDomainId = domainId;
    }

    function settleAndGetAssertionResult(bytes32 assertionId) external returns (bool) {
        require(assertionExists[assertionId], "unknown assertion");

        bool result = settlementResult[assertionId];
        if (!assertionSettled[assertionId]) {
            assertionSettled[assertionId] = true;
            IUmaCallbackRecipient(callbackRecipient[assertionId]).assertionResolvedCallback(assertionId, result);
        }
        return result;
    }

    function disputeAssertion(bytes32 assertionId) external {
        require(assertionExists[assertionId], "unknown assertion");
        IUmaCallbackRecipient(callbackRecipient[assertionId]).assertionDisputedCallback(assertionId);
    }
}

contract EventTriggerLenderMock is IEventTriggerLender {
    address public eventTriggerOperator;
    bool public eventTriggerMode;
    address public enabledBy;
    uint256 public enableCalls;

    constructor(address _eventTriggerOperator) {
        eventTriggerOperator = _eventTriggerOperator;
    }

    function enableEventTriggerMode() external {
        require(msg.sender == eventTriggerOperator, "Unauthorized");
        require(!eventTriggerMode, "Event trigger mode active");

        eventTriggerMode = true;
        enabledBy = msg.sender;
        enableCalls++;
    }

    function forceEnable() external {
        eventTriggerMode = true;
    }
}

contract UmaEventTriggerOracleTest is Test {
    using LibString for uint256;

    bytes constant TRIGGER_CLAIM = "The configured Monolith event trigger has occurred.";
    bytes16 private constant HEX_DIGITS = "0123456789abcdef";

    UmaCurrencyMock currency;
    UmaOptimisticOracleV3Mock optimisticOracleV3;
    UmaEventTriggerOracle adapter;

    address asserter = address(0xA55E);

    function setUp() public {
        currency = new UmaCurrencyMock();
        optimisticOracleV3 = new UmaOptimisticOracleV3Mock(ERC20(address(currency)));
        adapter = new UmaEventTriggerOracle(address(optimisticOracleV3), TRIGGER_CLAIM);
    }

    function test_constructorValidatesInputs() public {
        vm.expectRevert("Invalid oracle");
        new UmaEventTriggerOracle(address(0), TRIGGER_CLAIM);

        vm.expectRevert("Invalid claim");
        new UmaEventTriggerOracle(address(optimisticOracleV3), "");
    }

    function test_bindLenderRequiresOwnerAndMatchingOperator() public {
        EventTriggerLenderMock lender = new EventTriggerLenderMock(address(adapter));

        vm.prank(asserter);
        vm.expectRevert("Unauthorized");
        adapter.bindLender(address(lender));

        EventTriggerLenderMock wrongOperator = new EventTriggerLenderMock(address(0xBAD));
        vm.expectRevert("Invalid event trigger operator");
        adapter.bindLender(address(wrongOperator));

        adapter.bindLender(address(lender));
        assertEq(address(adapter.lender()), address(lender));

        vm.expectRevert("Lender already bound");
        adapter.bindLender(address(lender));
    }

    function test_assertEventTriggerPostsBondAndUsesCurrentUmaIdentifierAndContextualClaim() public {
        EventTriggerLenderMock lender = _bindLender();

        bytes32 assertionId = _assertEventTrigger();

        assertFalse(lender.eventTriggerMode());
        assertEq(currency.balanceOf(asserter), 0);
        assertEq(currency.balanceOf(address(adapter)), 0);
        assertEq(currency.balanceOf(address(optimisticOracleV3)), optimisticOracleV3.minimumBond());

        assertEq(optimisticOracleV3.lastAssertionId(), assertionId);
        assertEq(optimisticOracleV3.lastClaim(), _expectedClaim(address(lender)));
        assertEq(optimisticOracleV3.lastCaller(), address(adapter));
        assertEq(optimisticOracleV3.lastAsserter(), asserter);
        assertEq(optimisticOracleV3.lastCallbackRecipient(), address(adapter));
        assertEq(optimisticOracleV3.lastEscalationManager(), address(0));
        assertEq(optimisticOracleV3.lastLiveness(), optimisticOracleV3.defaultLiveness());
        assertEq(address(optimisticOracleV3.lastCurrency()), address(currency));
        assertEq(optimisticOracleV3.lastBond(), optimisticOracleV3.minimumBond());
        assertEq(optimisticOracleV3.lastIdentifier(), adapter.UMA_ASSERT_TRUTH_IDENTIFIER());
        assertEq(optimisticOracleV3.lastIdentifier(), bytes32("ASSERT_TRUTH2"));
        assertNotEq(optimisticOracleV3.lastIdentifier(), optimisticOracleV3.defaultIdentifier());
        assertEq(optimisticOracleV3.lastDomainId(), adapter.UMA_DOMAIN_ID());
        assertNotEq(optimisticOracleV3.lastDomainId(), bytes32(0));

        (address recordedAsserter, bool resolved, bool disputed) = adapter.assertions(assertionId);
        assertEq(recordedAsserter, asserter);
        assertFalse(resolved);
        assertFalse(disputed);
    }

    function test_assertEventTriggerRequiresBoundInactiveLender() public {
        _fundAndApproveAsserter();

        vm.prank(asserter);
        vm.expectRevert("Lender not bound");
        adapter.assertEventTrigger();

        EventTriggerLenderMock lender = _bindLender();
        lender.forceEnable();

        vm.prank(asserter);
        vm.expectRevert("Event trigger mode active");
        adapter.assertEventTrigger();
    }

    function test_truthfulResolutionActivatesLender() public {
        EventTriggerLenderMock lender = _bindLender();
        bytes32 assertionId = _assertEventTrigger();

        optimisticOracleV3.setSettlementResult(assertionId, true);
        bool result = adapter.settleAndGetAssertionResult(assertionId);

        assertTrue(result);
        assertTrue(lender.eventTriggerMode());
        assertEq(lender.enabledBy(), address(adapter));
        assertEq(lender.enableCalls(), 1);

        (, bool resolved, bool disputed) = adapter.assertions(assertionId);
        assertTrue(resolved);
        assertFalse(disputed);
    }

    function test_falseResolutionDeletesAssertionAndDoesNotActivate() public {
        EventTriggerLenderMock lender = _bindLender();
        bytes32 assertionId = _assertEventTrigger();

        optimisticOracleV3.setSettlementResult(assertionId, false);
        bool result = adapter.settleAndGetAssertionResult(assertionId);

        assertFalse(result);
        assertFalse(lender.eventTriggerMode());

        (address recordedAsserter, bool resolved, bool disputed) = adapter.assertions(assertionId);
        assertEq(recordedAsserter, address(0));
        assertFalse(resolved);
        assertFalse(disputed);
    }

    function test_disputeMarksAssertion() public {
        _bindLender();
        bytes32 assertionId = _assertEventTrigger();

        optimisticOracleV3.disputeAssertion(assertionId);

        (address recordedAsserter, bool resolved, bool disputed) = adapter.assertions(assertionId);
        assertEq(recordedAsserter, asserter);
        assertFalse(resolved);
        assertTrue(disputed);
    }

    function test_callbacksRejectUnauthorizedAndUnknownAssertions() public {
        bytes32 unknownAssertionId = bytes32("unknown");

        vm.expectRevert("Unauthorized");
        adapter.assertionResolvedCallback(unknownAssertionId, true);

        vm.prank(address(optimisticOracleV3));
        vm.expectRevert("Unknown assertion");
        adapter.assertionResolvedCallback(unknownAssertionId, true);

        vm.expectRevert("Unauthorized");
        adapter.assertionDisputedCallback(unknownAssertionId);

        vm.prank(address(optimisticOracleV3));
        vm.expectRevert("Unknown assertion");
        adapter.assertionDisputedCallback(unknownAssertionId);
    }

    function test_lateTruthfulSettlementAfterActivationDoesNotRevert() public {
        EventTriggerLenderMock lender = _bindLender();
        bytes32 firstAssertionId = _assertEventTrigger();
        bytes32 secondAssertionId = _assertEventTrigger();

        optimisticOracleV3.setSettlementResult(firstAssertionId, true);
        assertTrue(adapter.settleAndGetAssertionResult(firstAssertionId));
        assertTrue(lender.eventTriggerMode());
        assertEq(lender.enableCalls(), 1);

        optimisticOracleV3.setSettlementResult(secondAssertionId, true);
        assertTrue(adapter.settleAndGetAssertionResult(secondAssertionId));
        assertEq(lender.enableCalls(), 1);

        (, bool resolved,) = adapter.assertions(secondAssertionId);
        assertTrue(resolved);

        _fundAndApproveAsserter();
        vm.prank(asserter);
        vm.expectRevert("Event trigger mode active");
        adapter.assertEventTrigger();
    }

    function test_zeroBondAssertionsDoNotRequireFunding() public {
        _bindLender();
        optimisticOracleV3.setMinimumBond(0);

        vm.prank(asserter);
        bytes32 assertionId = adapter.assertEventTrigger();

        assertTrue(optimisticOracleV3.assertionExists(assertionId));
        assertEq(currency.balanceOf(address(optimisticOracleV3)), 0);
        assertEq(optimisticOracleV3.lastBond(), 0);
    }

    function test_settleRequiresKnownAssertion() public {
        vm.expectRevert("Unknown assertion");
        adapter.settleAndGetAssertionResult(bytes32("unknown"));
    }

    function _bindLender() internal returns (EventTriggerLenderMock lender) {
        lender = new EventTriggerLenderMock(address(adapter));
        adapter.bindLender(address(lender));
    }

    function _assertEventTrigger() internal returns (bytes32 assertionId) {
        _fundAndApproveAsserter();

        vm.prank(asserter);
        assertionId = adapter.assertEventTrigger();
    }

    function _fundAndApproveAsserter() internal {
        uint256 bond = optimisticOracleV3.minimumBond();
        currency.mint(asserter, bond);

        vm.prank(asserter);
        currency.approve(address(adapter), bond);
    }

    function _expectedClaim(address lender) internal view returns (bytes memory) {
        return abi.encodePacked(
            "Monolith event trigger assertion. Trigger definition: ",
            TRIGGER_CLAIM,
            ". Chain ID: ",
            uint256(block.chainid).toString(),
            ". Lender: ",
            _addressToString(lender),
            ". Adapter: ",
            _addressToString(address(adapter)),
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
}
