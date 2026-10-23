// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MADToken} from "../src/MADToken.sol";

/// @dev Test-only handler. All balances remain within a known set of four holders.
contract MADHandler is Test {
    MADToken private immutable token;
    address[4] public holders;

    constructor(MADToken token_) {
        token = token_;
        holders[0] = makeAddr("invariant holder 0");
        holders[1] = makeAddr("invariant holder 1");
        holders[2] = makeAddr("invariant holder 2");
        holders[3] = makeAddr("invariant holder 3");
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 value) external {
        address from = holders[fromSeed % holders.length];
        address to = holders[toSeed % holders.length];
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        value = bound(value, 0, fromBefore);
        vm.prank(from);
        assertTrue(token.transfer(to, value));
        assertEq(token.balanceOf(from), from == to ? fromBefore : fromBefore - value);
        assertEq(token.balanceOf(to), from == to ? toBefore : toBefore + value);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 value) external {
        address owner = holders[ownerSeed % holders.length];
        address spender = holders[spenderSeed % holders.length];
        vm.prank(owner);
        assertTrue(token.approve(spender, value));
        assertEq(token.allowance(owner, spender), value);
    }

    function transferFrom(uint256 fromSeed, uint256 toSeed, uint256 spenderSeed, uint256 value) external {
        address from = holders[fromSeed % holders.length];
        address to = holders[toSeed % holders.length];
        address spender = holders[spenderSeed % holders.length];
        uint256 available = token.allowance(from, spender);
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        value = bound(value, 0, available < fromBefore ? available : fromBefore);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, value));
        assertEq(token.balanceOf(from), from == to ? fromBefore : fromBefore - value);
        assertEq(token.balanceOf(to), from == to ? toBefore : toBefore + value);
        assertEq(token.allowance(from, spender), available == type(uint256).max ? available : available - value);
    }
}

contract MADTokenInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    MADToken private token;
    MADHandler private handler;

    function setUp() public {
        token = new MADToken();
        handler = new MADHandler(token);
        assertTrue(token.transfer(handler.holders(0), SUPPLY));

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = MADHandler.transfer.selector;
        selectors[1] = MADHandler.approve.selector;
        selectors[2] = MADHandler.transferFrom.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_supplyAndBalancesAreConserved() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            sum += token.balanceOf(handler.holders(i));
        }
        assertEq(sum, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function invariant_metadataNeverChanges() public view {
        assertEq(token.name(), "Mutually Assured Destruction");
        assertEq(token.symbol(), "MAD");
        assertEq(token.decimals(), 18);
    }
}
