// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MADToken} from "../src/MADToken.sol";

/// @dev Test-only stand-in for the launch factory: deploys the token through CREATE2 and distributes
/// it within the same call, as `launchCustom` does in one transaction.
contract MADCreate2Launcher {
    struct Result {
        address token;
        uint256 supplyAtDeploy;
        uint256 launcherBalanceAtDeploy;
        uint256 launcherBalanceAfter;
    }

    function launch(bytes32 salt, address distributor, address poolManager, address remainderTo, uint256 poolBps)
        external
        returns (Result memory r)
    {
        bytes memory code = type(MADToken).creationCode;
        address created;
        assembly ("memory-safe") {
            created := create2(0, add(code, 32), mload(code), salt)
        }
        require(created != address(0), "token constructor failed");
        MADToken token = MADToken(created);
        r.token = created;
        r.supplyAtDeploy = token.totalSupply();
        r.launcherBalanceAtDeploy = token.balanceOf(address(this));

        uint256 supply = r.supplyAtDeploy;
        uint256 swarm = supply / 10;
        uint256 pool = supply * poolBps / 10_000;
        require(token.transfer(distributor, swarm), "swarm transfer");
        require(token.transfer(poolManager, pool), "pool transfer");
        require(token.transfer(remainderTo, supply - swarm - pool), "remainder transfer");
        r.launcherBalanceAfter = token.balanceOf(address(this));
    }
}

contract MADTokenLaunchTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;

    address private distributor = makeAddr("distributor");
    address private poolManager = makeAddr("pool manager");
    address private remainderTo = makeAddr("remainder");

    function test_supplyLiteralIsExactlyOneBillionWholeTokens() public {
        MADToken token = new MADToken();
        assertEq(token.totalSupply(), 1_000_000_000_000_000_000_000_000_000);
        assertEq(token.totalSupply() / 10 ** token.decimals(), 1_000_000_000);
        assertEq(token.totalSupply() % 10 ** token.decimals(), 0);
    }

    function test_create2LaunchInOneCallDistributesExactly() public {
        MADCreate2Launcher launcher = new MADCreate2Launcher();
        bytes32 salt = keccak256("MAD launch");
        address predicted = vm.computeCreate2Address(salt, keccak256(type(MADToken).creationCode), address(launcher));

        MADCreate2Launcher.Result memory r = launcher.launch(salt, distributor, poolManager, remainderTo, 8_000);
        MADToken token = MADToken(r.token);

        assertEq(r.token, predicted);
        assertEq(r.supplyAtDeploy, SUPPLY);
        assertEq(r.launcherBalanceAtDeploy, SUPPLY);
        assertEq(r.launcherBalanceAfter, 0);
        assertEq(token.balanceOf(distributor), SUPPLY / 10);
        assertEq(token.balanceOf(poolManager), SUPPLY * 8 / 10);
        assertEq(token.balanceOf(remainderTo), SUPPLY / 10);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(tx.origin), 0);
    }

    function test_create2SameSaltTwiceFails() public {
        MADCreate2Launcher launcher = new MADCreate2Launcher();
        bytes32 salt = keccak256("MAD launch");
        launcher.launch(salt, distributor, poolManager, remainderTo, 8_000);
        vm.expectRevert(bytes("token constructor failed"));
        launcher.launch(salt, distributor, poolManager, remainderTo, 8_000);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_launchSplitsAlwaysSumToSupply(uint256 poolBps, bytes32 salt) public {
        poolBps = bound(poolBps, 0, 9_000);
        MADCreate2Launcher launcher = new MADCreate2Launcher();
        MADCreate2Launcher.Result memory r = launcher.launch(salt, distributor, poolManager, remainderTo, poolBps);
        MADToken token = MADToken(r.token);
        assertEq(r.launcherBalanceAfter, 0);
        assertEq(token.balanceOf(distributor), SUPPLY / 10);
        assertEq(token.balanceOf(poolManager), SUPPLY * poolBps / 10_000);
        assertEq(token.balanceOf(distributor) + token.balanceOf(poolManager) + token.balanceOf(remainderTo), SUPPLY);
    }

    /// @dev The pool manager and distributor receive nothing special: a holder trading against them
    /// moves exactly the requested amount in both directions.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_tradeLegsAreExactBothWays(address trader, uint256 buy, uint256 sell) public {
        vm.assume(trader != address(0) && trader != poolManager);
        MADCreate2Launcher launcher = new MADCreate2Launcher();
        MADToken token = MADToken(launcher.launch(bytes32(0), distributor, poolManager, remainderTo, 8_000).token);
        uint256 pool = token.balanceOf(poolManager);
        uint256 traderStart = token.balanceOf(trader);
        buy = bound(buy, 0, pool);
        sell = bound(sell, 0, traderStart + buy);

        vm.prank(poolManager);
        assertTrue(token.transfer(trader, buy));
        assertEq(token.balanceOf(trader), traderStart + buy);
        vm.prank(trader);
        assertTrue(token.transfer(poolManager, sell));
        assertEq(token.balanceOf(trader), traderStart + buy - sell);
        assertEq(token.balanceOf(poolManager), pool - buy + sell);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_anyCallerAnyRecipientTransferAndOverdraft(address from, address to, uint256 funded, uint256 value)
        public
    {
        vm.assume(from != address(0) && to != address(0) && from != address(this));
        MADToken token = new MADToken();
        funded = bound(funded, 0, SUPPLY);
        assertTrue(token.transfer(from, funded));
        uint256 toBefore = token.balanceOf(to);
        value = bound(value, 0, type(uint256).max);

        vm.prank(from);
        if (value > funded) {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, funded, value));
            token.transfer(to, value);
            assertEq(token.balanceOf(from), funded);
            assertEq(token.balanceOf(to), toBefore);
        } else {
            assertTrue(token.transfer(to, value));
            if (from == to) {
                assertEq(token.balanceOf(from), funded);
            } else {
                assertEq(token.balanceOf(from), funded - value);
                assertEq(token.balanceOf(to), toBefore + value);
            }
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Unlimited allowance is the sentinel `type(uint256).max` only; one less is finite and decreases.
    function test_allowanceOneBelowMaxIsFinite() public {
        MADToken token = new MADToken();
        address spender = makeAddr("spender");
        assertTrue(token.approve(spender, type(uint256).max - 1));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), remainderTo, 1));
        assertEq(token.allowance(address(this), spender), type(uint256).max - 2);
    }

    /// @dev Spending an allowance changes it silently: no Approval log is emitted by transferFrom.
    function test_transferFromEmitsOnlyTransfer() public {
        MADToken token = new MADToken();
        address spender = makeAddr("spender");
        assertTrue(token.approve(spender, 10));
        vm.recordLogs();
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), remainderTo, 4));
        assertEq(vm.getRecordedLogs().length, 1);
        assertEq(token.allowance(address(this), spender), 6);
    }

    /// @dev Tokens sent to the token contract are stranded: nothing can move them back out.
    function test_tokensSentToTokenContractAreStranded() public {
        MADToken token = new MADToken();
        assertTrue(token.transfer(address(token), 1 ether));
        assertEq(token.balanceOf(address(token)), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(address(token), address(this), 1);
        assertEq(token.balanceOf(address(token)), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
