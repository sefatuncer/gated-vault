// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { MockUSDC } from "../../contracts/mocks/MockUSDC.sol";
import { GatedVault } from "../../contracts/GatedVault.sol";
import { Whitelist } from "../../contracts/access/Whitelist.sol";
import { IdentityVerifier } from "../../contracts/identity/IdentityVerifier.sol";

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
    Whitelist internal whitelist;
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");

    function setUp() public {
        usdc = new MockUSDC();
        whitelist = new Whitelist(owner);
        vault = new GatedVault(
            IERC20Metadata(address(usdc)), owner, INITIAL_YIELD_RATE, whitelist, IdentityVerifier(address(0))
        );
        // Fuzz properties exercise the happy path; alice is the sole actor and
        // is whitelisted at construction so the gating check never reverts.
        vm.prank(owner);
        whitelist.setWhitelist(alice, true);
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

    /// @notice Realized yield from `harvest()` is always bounded by both the
    ///         pre-harvest reserve and the pre-harvest pendingYield.
    /// @dev    The reserve is `vault balance − tracked principal`. The
    ///         `_harvestYield` core caps the in-flight `yield_` to
    ///         `min(pending, reserve)` before mutating principal. Five
    ///         invariants exercised:
    ///           1. principal delta == harvest() return value (state vs ABI),
    ///           2. harvested ≤ reserveBefore (reserve cap),
    ///           3. harvested ≤ pendingBefore (pending upper bound),
    ///           4. pendingYield() resets to zero (lastHarvest stamped),
    ///           5. vault balance unchanged (harvest is pure accounting).
    ///         3-D fuzz: deposit ∈ [1 USDC, 1M USDC], reserve ∈ [0, 1M USDC]
    ///         (zero is the kill-switch path), elapsed ∈ [1s, 10y].
    function testFuzz_PendingYieldReserveBounded(
        uint256 depositAmount,
        uint256 reserveAmount,
        uint256 timeJump
    )
        public
    {
        depositAmount = bound(depositAmount, 1e6, 1_000_000e6);
        reserveAmount = bound(reserveAmount, 0, 1_000_000e6);
        timeJump = bound(timeJump, 1, 365 days * 10);

        usdc.mint(alice, depositAmount);
        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        if (reserveAmount > 0) {
            usdc.mint(owner, reserveAmount);
            vm.startPrank(owner);
            usdc.approve(address(vault), reserveAmount);
            vault.depositYieldReserve(reserveAmount);
            vm.stopPrank();
        }

        vm.warp(block.timestamp + timeJump);

        uint256 principalBefore = vault.principal();
        uint256 vaultBalBefore = usdc.balanceOf(address(vault));
        // Vault balance is principal (deposits) plus reserve (donations through
        // the documented entry point); subtraction can never underflow because
        // tracked principal is never inflated past balance by construction.
        uint256 reserveBefore = vaultBalBefore - principalBefore;
        uint256 pendingBefore = vault.pendingYield();

        uint256 harvested = vault.harvest();

        uint256 realized = vault.principal() - principalBefore;

        assertEq(realized, harvested, "principal delta != harvested return");
        assertLe(harvested, reserveBefore, "harvest exceeded reserve");
        assertLe(harvested, pendingBefore, "harvest exceeded pending");
        assertEq(vault.pendingYield(), 0, "pending must reset post-harvest");
        assertEq(usdc.balanceOf(address(vault)), vaultBalBefore, "balance moved during pure-accounting harvest");
    }

    /// @notice `pendingYield()` simple-interest math stays inside uint256 even
    ///         under inputs orders of magnitude beyond any realistic supply.
    /// @dev    Worst-case product: principal × yieldRate × elapsed. With
    ///         principal up to type(uint128).max (~3.4e38), yieldRate = 500
    ///         (5% APY fixture), and elapsed up to a century (~3.15e9 s),
    ///         the numerator tops out near 5.4e50 — uint256 ceiling is 1.16e77,
    ///         leaving ~26 decimal digits of headroom. This test pins that
    ///         bound: a future refactor that drops the divide-last ordering
    ///         (or widens precision unsafely) would surface here as a Panic.
    ///         Sanity assert: pending ≤ deposit × 5 (5% APY for 100 years).
    function testFuzz_NoOverflowInYieldCalc(uint256 depositAmount, uint256 timeJump) public {
        depositAmount = bound(depositAmount, 1e6, type(uint128).max);
        timeJump = bound(timeJump, 0, 365 days * 100);

        usdc.mint(alice, depositAmount);
        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + timeJump);

        // Must not panic with arithmetic overflow.
        uint256 pending = vault.pendingYield();

        // Sanity: bounded by 5% APY × 100 years = 5x principal.
        assertLe(pending, depositAmount * 5, "pending wildly above sanity bound");
    }
}
