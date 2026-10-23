// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MADToken} from "../src/MADToken.sol";

/// @dev Test-only contract holder, so the actor set includes a contract as well as EOAs.
contract MADContractHolder {}

/// @dev Test-only handler. Unlike `MADHandler`, it also drives calls that must fail (overdrafts,
/// over-allowance spends, zero-address receivers and spenders, unknown privileged selectors) and keeps
/// an independent ghost ledger of every balance and allowance, which the invariants compare against.
contract MADGhostHandler is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;

    MADToken private immutable token;
    address[] private actors;

    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    uint256 public ghostSuccesses;
    uint256 public ghostExpectedFailures;
    uint256 public ghostOutcomeMismatches;

    constructor(MADToken token_, address initialHolder) {
        token = token_;
        actors.push(initialHolder);
        actors.push(makeAddr("ghost actor 1"));
        actors.push(makeAddr("ghost actor 2"));
        actors.push(makeAddr("ghost actor 3"));
        actors.push(address(new MADContractHolder()));
        // The token itself can receive (and strand) balances; it is part of the ledger.
        actors.push(address(token_));
        ghostBalance[initialHolder] = SUPPLY;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _record(bool succeeded, bool expected) private {
        if (succeeded != expected) ++ghostOutcomeMismatches;
        if (succeeded) ++ghostSuccesses;
        else ++ghostExpectedFailures;
    }

    /// @dev Amounts range to twice the sender's balance plus one, so overdrafts are drawn often.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 value) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        value = bound(value, 0, ghostBalance[from] * 2 + 1);
        bool shouldSucceed = value <= ghostBalance[from];

        vm.prank(from);
        try token.transfer(to, value) returns (bool ok) {
            assertTrue(ok);
            _record(true, shouldSucceed);
            ghostBalance[from] -= value;
            ghostBalance[to] += value;
        } catch (bytes memory reason) {
            _record(false, shouldSucceed);
            assertEq(
                reason,
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, ghostBalance[from], value)
            );
        }
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 value) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[from][spender];
        uint256 balance = ghostBalance[from];
        uint256 cap = allowed < balance ? allowed : balance;
        value = bound(value, 0, cap * 2 + 1);
        bool allowanceOk = allowed == type(uint256).max || value <= allowed;
        bool shouldSucceed = allowanceOk && value <= balance;

        vm.prank(spender);
        try token.transferFrom(from, to, value) returns (bool ok) {
            assertTrue(ok);
            _record(true, shouldSucceed);
            if (allowed != type(uint256).max) ghostAllowance[from][spender] = allowed - value;
            ghostBalance[from] -= value;
            ghostBalance[to] += value;
        } catch (bytes memory reason) {
            _record(false, shouldSucceed);
            // The allowance is checked before the balance.
            bytes memory expected = allowanceOk
                ? abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, value)
                : abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, value);
            assertEq(reason, expected);
        }
    }

    /// @dev One draw in four approves the maximum, so the unlimited-allowance path is exercised.
    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 value) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        if (value % 4 == 0) value = type(uint256).max;
        else value = bound(value, 0, SUPPLY * 2);

        vm.prank(owner);
        assertTrue(token.approve(spender, value));
        _record(true, true);
        ghostAllowance[owner][spender] = value;
    }

    function transferToZero(uint256 fromSeed, uint256 value) external {
        address from = _actor(fromSeed);
        value = bound(value, 0, ghostBalance[from]);
        vm.prank(from);
        try token.transfer(address(0), value) {
            _record(true, false);
        } catch (bytes memory reason) {
            _record(false, false);
            assertEq(reason, abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        }
    }

    function transferFromToZero(uint256 spenderSeed, uint256 fromSeed, uint256 value) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        uint256 allowed = ghostAllowance[from][spender];
        uint256 balance = ghostBalance[from];
        value = bound(value, 0, allowed < balance ? allowed : balance);
        vm.prank(spender);
        try token.transferFrom(from, address(0), value) {
            _record(true, false);
        } catch (bytes memory reason) {
            _record(false, false);
            assertEq(reason, abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        }
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 value) external {
        address owner = _actor(ownerSeed);
        vm.prank(owner);
        try token.approve(address(0), value) {
            _record(true, false);
        } catch (bytes memory reason) {
            _record(false, false);
            assertEq(reason, abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        }
    }

    /// @dev Anyone, including the original holder, attempting a privileged supply or balance change.
    function privilegedCall(uint256 callerSeed, uint256 targetSeed, uint256 selectorSeed, uint256 value) external {
        address caller = _actor(callerSeed);
        address target = _actor(targetSeed);
        bytes memory data;
        uint256 pick = selectorSeed % 6;
        if (pick == 0) data = abi.encodeWithSignature("mint(address,uint256)", caller, value);
        else if (pick == 1) data = abi.encodeWithSignature("burn(uint256)", value);
        else if (pick == 2) data = abi.encodeWithSignature("burnFrom(address,uint256)", target, value);
        else if (pick == 3) data = abi.encodeWithSignature("seize(address,address,uint256)", target, caller, value);
        else if (pick == 4) data = abi.encodeWithSignature("pause()");
        else data = abi.encodeWithSignature("blacklist(address)", target);

        vm.prank(caller);
        (bool success,) = address(token).call(data);
        _record(success, false);
    }
}

contract MADTokenGhostInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;

    MADToken private token;
    MADGhostHandler private handler;

    function setUp() public {
        token = new MADToken();
        address initialHolder = makeAddr("ghost actor 0");
        handler = new MADGhostHandler(token, initialHolder);
        assertTrue(token.transfer(initialHolder, SUPPLY));

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = MADGhostHandler.transfer.selector;
        selectors[1] = MADGhostHandler.transferFrom.selector;
        selectors[2] = MADGhostHandler.approve.selector;
        selectors[3] = MADGhostHandler.transferToZero.selector;
        selectors[4] = MADGhostHandler.transferFromToZero.selector;
        selectors[5] = MADGhostHandler.approveZeroSpender.selector;
        selectors[6] = MADGhostHandler.privilegedCall.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 100
    function invariant_balancesMatchGhostLedger() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actorAt(i);
            assertEq(token.balanceOf(a), handler.ghostBalance(a), "balance diverged from ghost ledger");
            sum += token.balanceOf(a);
        }
        assertEq(sum, SUPPLY, "tokens left the tracked actor set");
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(this)), 0);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 100
    function invariant_allowancesMatchGhostLedger() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address owner = handler.actorAt(i);
            for (uint256 j; j < n; ++j) {
                address spender = handler.actorAt(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.ghostAllowance(owner, spender),
                    "allowance diverged from ghost ledger"
                );
            }
            assertEq(token.allowance(owner, address(0)), 0, "zero-address spender holds an allowance");
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 100
    function invariant_supplyIsFixedAndOutcomesAsExpected() public view {
        assertEq(token.totalSupply(), SUPPLY, "supply changed");
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(handler.ghostOutcomeMismatches(), 0, "a call succeeded or failed against the specification");
        assertEq(address(token).balance, 0);
    }

    /// @dev Guards against a vacuous campaign: each run must exercise both accepted and refused calls.
    function afterInvariant() public view {
        assertGt(handler.ghostSuccesses(), 0, "no call succeeded");
        assertGt(handler.ghostExpectedFailures(), 0, "no failure path was exercised");
    }
}
