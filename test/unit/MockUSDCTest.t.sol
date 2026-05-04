// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { MockUSDC } from "../../contracts/mocks/MockUSDC.sol";

/// @title  MockUSDCTest
/// @notice Unit tests for the MockUSDC test asset.
contract MockUSDCTest is Test {
    MockUSDC internal usdc;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        usdc = new MockUSDC();
    }

    function test_NameAndSymbol() public view {
        assertEq(usdc.name(), "Mock USDC", "name");
        assertEq(usdc.symbol(), "USDC", "symbol");
    }

    function test_DecimalsIs6() public view {
        assertEq(usdc.decimals(), 6, "decimals must match real USDC");
    }

    function test_MintIncreasesBalance() public {
        uint256 amount = 1000 * 10 ** usdc.decimals();

        usdc.mint(alice, amount);

        assertEq(usdc.balanceOf(alice), amount, "alice balance");
        assertEq(usdc.totalSupply(), amount, "totalSupply");
    }

    function test_TransferWorks() public {
        uint256 amount = 500 * 10 ** usdc.decimals();
        usdc.mint(alice, amount);

        vm.prank(alice);
        bool ok = usdc.transfer(bob, amount);

        assertTrue(ok, "transfer return value");
        assertEq(usdc.balanceOf(alice), 0, "alice after transfer");
        assertEq(usdc.balanceOf(bob), amount, "bob after transfer");
        assertEq(usdc.totalSupply(), amount, "totalSupply unchanged");
    }
}
