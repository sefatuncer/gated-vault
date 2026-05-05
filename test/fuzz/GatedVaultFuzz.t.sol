// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { MockUSDC } from "../../contracts/mocks/MockUSDC.sol";
import { GatedVault } from "../../contracts/GatedVault.sol";

/// @title  GatedVaultFuzzTest
/// @author Sefa Tunçer
/// @notice Property-based tests for the vault. The single round-trip property
///         here covers the deposit/redeem accounting boundary across the full
///         realistic input range; yield-time fuzz lives in todo-18 and stateful
///         invariants in the Faz-7 handler suite.
contract GatedVaultFuzzTest is Test {
    uint256 internal constant INITIAL_YIELD_RATE = 500; // 5% APY (basis points)

    MockUSDC internal usdc;
    GatedVault internal vault;
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");

    function setUp() public {
        usdc = new MockUSDC();
        vault = new GatedVault(IERC20Metadata(address(usdc)), owner, INITIAL_YIELD_RATE);
    }

    /// @notice Deposit then immediate redeem must return the full principal
    ///         within a single wei of drift.
    /// @dev    No time passes between deposit and redeem, so `pendingYield()`
    ///         is zero on both `_harvestYield` calls in the hooks. The only
    ///         residual drift is OZ ERC4626 floor rounding under the
    ///         `_decimalsOffset = 6` virtual-shares scheme: at most one wei
    ///         can be absorbed by the offset on the way in or out. Anything
    ///         beyond that bound is an accounting bug. Bound:
    ///           - lower 1e6 (1 USDC) skips the dust regime where rounding
    ///             dominates economics and avoids the `ZeroAssets` revert.
    ///           - upper 1_000_000e6 (1M USDC) keeps inputs inside realistic
    ///             USDC magnitudes; multiplication by `10**offset` stays well
    ///             below uint256 overflow.
    function testFuzz_DepositRedeemRoundTrip(uint256 amount) public {
        amount = bound(amount, 1e6, 1_000_000e6);
        usdc.mint(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        uint256 received = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertApproxEqAbs(received, amount, 1, "round-trip drift > 1 wei");
        assertEq(vault.balanceOf(alice), 0, "alice shares burned");
        assertEq(vault.principal(), 0, "principal back to zero");
    }
}
