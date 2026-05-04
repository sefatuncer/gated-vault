// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { MockUSDC } from "../../contracts/mocks/MockUSDC.sol";
import { GatedVault } from "../../contracts/GatedVault.sol";

/// @title  GatedVaultTest
/// @notice Unit tests for the vault: construction metadata, inflation defense,
///         and yield-rate state surface (todo-11). Deposit/withdraw flow,
///         pendingYield math, and VC-gating tests live in later test files.
contract GatedVaultTest is Test {
    uint256 internal constant INITIAL_YIELD_RATE = 500; // 5% APY (basis points)

    MockUSDC internal usdc;
    GatedVault internal vault;
    address internal owner = makeAddr("owner");

    function setUp() public {
        usdc = new MockUSDC();
        vault = new GatedVault(IERC20Metadata(address(usdc)), owner, INITIAL_YIELD_RATE);
    }

    function test_DeployedWithCorrectName() public view {
        assertEq(vault.name(), "Gated USDC Vault", "vault name");
    }

    function test_DeployedWithCorrectSymbol() public view {
        assertEq(vault.symbol(), "gUSDC", "vault symbol");
    }

    function test_DeployedWithCorrectAsset() public view {
        assertEq(address(vault.asset()), address(usdc), "vault asset");
    }

    function test_OwnerSetAtConstruction() public view {
        assertEq(vault.owner(), owner, "vault owner");
    }

    /// @notice Inflation attack resistance via _decimalsOffset = 6.
    /// @dev    Without offset, a 1-wei first deposit + large bare transfer
    ///         (donation) would warp share price so the next depositor floor-
    ///         rounds to zero shares. With offset = 6, virtual-shares math
    ///         absorbs the donation; the legitimate depositor still receives
    ///         non-zero shares and a redemption value close to their deposit.
    ///         Tracked `_accountedAssets` (todo-13) tightens this further by
    ///         ignoring donations entirely; until that ships, the offset alone
    ///         is the active defense layer being exercised here.
    function test_InflationAttackResistance() public {
        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");

        uint256 oneUnit = 10 ** usdc.decimals(); // 1 USDC = 1e6 wei
        uint256 donationAmount = 1_000_000 * oneUnit; // 1M USDC
        uint256 victimDeposit = 100 * oneUnit; // 100 USDC

        usdc.mint(attacker, 1 + donationAmount);
        usdc.mint(victim, victimDeposit);

        // Step 1: attacker first-depositor with 1 wei
        vm.startPrank(attacker);
        usdc.approve(address(vault), type(uint256).max);
        uint256 attackerShares = vault.deposit(1, attacker);

        // Step 2: bare transfer (donation) — bypass deposit() to skip share mint
        bool ok = usdc.transfer(address(vault), donationAmount);
        assertTrue(ok, "donation transfer return value");
        vm.stopPrank();

        // Step 3: legitimate depositor enters
        vm.startPrank(victim);
        usdc.approve(address(vault), type(uint256).max);
        uint256 victimShares = vault.deposit(victimDeposit, victim);
        vm.stopPrank();

        // Without offset, victimShares would be 0 (floor rounding); attack succeeds.
        // With offset = 6, virtual-shares math keeps share allocation meaningful.
        assertGt(victimShares, 0, "inflation attack succeeded: victim received zero shares");

        // Attacker shares are large (~1e6) due to virtual-shares ratio at first deposit;
        // the goal of the attack was to make victim's shares zero, not to deny attacker
        // shares. We assert attacker did receive shares but not at victim's expense.
        assertGt(attackerShares, 0, "attacker should still receive shares (sanity)");

        // Most important invariant: victim's redemption value is not catastrophically
        // diluted. With tracked AUM (todo-13) this rises to ~exact deposit; with offset
        // alone, donation still inflates share price, so victim's redemption is bounded
        // below by the offset-protected share count translated back through the warped
        // ratio. Concrete bound: victim recovers at least 50% of deposit even in this
        // pre-tracked-AUM regime; full ~99% expected after todo-13.
        uint256 victimRedemption = vault.previewRedeem(victimShares);
        assertGe(victimRedemption, victimDeposit / 2, "victim redemption catastrophically diluted");
    }

    // -------- Yield state surface (todo-11) --------

    function test_YieldRateInitializedCorrectly() public view {
        assertEq(vault.yieldRate(), INITIAL_YIELD_RATE, "initial yield rate");
        assertEq(vault.MAX_YIELD_RATE(), 5000, "max yield rate constant");
        assertEq(vault.SECONDS_PER_YEAR(), 365 days, "seconds per year constant");
        assertEq(vault.lastHarvest(), block.timestamp, "lastHarvest set at construction");
        assertEq(vault.principal(), 0, "principal zero before any deposit");
    }

    function test_ConstructorRevertsAboveMax() public {
        uint256 tooHigh = 5001;
        vm.expectRevert(abi.encodeWithSelector(GatedVault.YieldRateTooHigh.selector, tooHigh, 5000));
        new GatedVault(IERC20Metadata(address(usdc)), owner, tooHigh);
    }

    function test_SetYieldRateRevertsAboveMax() public {
        uint256 tooHigh = 5001;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GatedVault.YieldRateTooHigh.selector, tooHigh, 5000));
        vault.setYieldRate(tooHigh);
    }

    function test_SetYieldRateOnlyOwner() public {
        address nonOwner = makeAddr("nonOwner");
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        vault.setYieldRate(1000);
    }

    function test_SetYieldRateEmitsEvent() public {
        uint256 newRate = 1000; // 10% APY
        vm.prank(owner);
        vm.expectEmit(true, true, true, true, address(vault));
        emit GatedVault.YieldRateUpdated(INITIAL_YIELD_RATE, newRate);
        vault.setYieldRate(newRate);
        assertEq(vault.yieldRate(), newRate, "rate updated");
    }

    // -------- Yield mechanics + harvest (todo-12) --------

    /// @dev Helper: Alice deposits `amount` USDC into the vault.
    function _aliceDeposits(uint256 amount) internal returns (address alice, uint256 shares) {
        alice = makeAddr("alice");
        usdc.mint(alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        shares = vault.deposit(amount, alice);
        vm.stopPrank();
    }

    /// @dev Helper: owner tops up the yield reserve by `amount` USDC.
    function _ownerFundsReserve(uint256 amount) internal {
        usdc.mint(owner, amount);
        vm.startPrank(owner);
        usdc.approve(address(vault), type(uint256).max);
        vault.depositYieldReserve(amount);
        vm.stopPrank();
    }

    function test_PendingYieldZeroBeforePrincipal() public view {
        assertEq(vault.pendingYield(), 0, "yield must be zero with no principal");
    }

    function test_PendingYieldAccruesOverTime() public {
        uint256 deposit = 100 * 10 ** usdc.decimals(); // 100 USDC
        _aliceDeposits(deposit);

        uint256 elapsed = 30 days;
        vm.warp(block.timestamp + elapsed);

        uint256 expected = (deposit * INITIAL_YIELD_RATE * elapsed) / (10_000 * vault.SECONDS_PER_YEAR());
        assertEq(vault.pendingYield(), expected, "simple-interest accrual");
        assertGt(expected, 0, "expected nonzero yield over 30d");
    }

    function test_HarvestUpdatesPrincipalAndTimestamp() public {
        uint256 deposit = 100 * 10 ** usdc.decimals();
        _aliceDeposits(deposit);

        // Reserve large enough to absorb full pending yield
        _ownerFundsReserve(50 * 10 ** usdc.decimals());

        vm.warp(block.timestamp + 30 days);
        uint256 expectedYield = vault.pendingYield();
        assertGt(expectedYield, 0, "fixture must have nonzero pending yield");

        uint256 harvestedAt = block.timestamp;
        uint256 harvested = vault.harvest();

        assertEq(harvested, expectedYield, "harvested amount matches preview");
        assertEq(vault.principal(), deposit + expectedYield, "principal increased by yield");
        assertEq(vault.lastHarvest(), harvestedAt, "lastHarvest stamped");
        assertEq(vault.pendingYield(), 0, "no yield left to harvest immediately after");
    }

    function test_HarvestCappedByReserve() public {
        uint256 deposit = 1000 * 10 ** usdc.decimals(); // 1000 USDC, large principal
        _aliceDeposits(deposit);

        // Owner funds only 1 USDC reserve — far less than 30d of yield on 1000 principal
        uint256 smallReserve = 1 * 10 ** usdc.decimals();
        _ownerFundsReserve(smallReserve);

        vm.warp(block.timestamp + 30 days);

        // Theoretical yield = 1000 × 0.05 × 30/365 ≈ 4.11 USDC, far above the 1 USDC reserve
        uint256 theoretical = vault.pendingYield();
        assertGt(theoretical, smallReserve, "fixture must over-promise yield");

        uint256 harvested = vault.harvest();

        assertEq(harvested, smallReserve, "harvest capped to available reserve");
        assertEq(vault.principal(), deposit + smallReserve, "principal grew only by reserve cap");
    }

    function test_HarvestExternalCallableByAnyone() public {
        uint256 deposit = 100 * 10 ** usdc.decimals();
        _aliceDeposits(deposit);
        _ownerFundsReserve(50 * 10 ** usdc.decimals());

        vm.warp(block.timestamp + 30 days);

        address keeper = makeAddr("keeper");
        vm.prank(keeper);
        uint256 harvested = vault.harvest();

        assertGt(harvested, 0, "keeper-triggered harvest produced realization");
    }

    function test_DepositYieldReserveOnlyOwner() public {
        // Pre-compute the argument; an inline expression like
        // `50 * 10 ** usdc.decimals()` makes an external call that is consumed
        // by vm.expectRevert before the actual depositYieldReserve call runs.
        uint256 amount = 50 * 10 ** usdc.decimals();
        address attacker = makeAddr("unauthCaller");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vault.depositYieldReserve(amount);
    }

    function test_SetYieldRateHarvestsBefore() public {
        uint256 deposit = 100 * 10 ** usdc.decimals();
        _aliceDeposits(deposit);
        _ownerFundsReserve(50 * 10 ** usdc.decimals());

        vm.warp(block.timestamp + 30 days);
        uint256 oldRateYield = vault.pendingYield();
        assertGt(oldRateYield, 0, "must have accrued under old rate");

        // Owner changes the rate. Yield under the OLD rate must be realized first;
        // otherwise it would be silently re-priced at the new (lower) rate.
        uint256 newRate = 100; // 1% APY (down from 5%)
        vm.prank(owner);
        vault.setYieldRate(newRate);

        // Old-rate yield is now in principal; pendingYield should be 0 immediately after
        assertEq(vault.principal(), deposit + oldRateYield, "old-rate yield realized into principal");
        assertEq(vault.pendingYield(), 0, "no yield carried over at new rate");
        assertEq(vault.yieldRate(), newRate, "rate updated");
    }
}
