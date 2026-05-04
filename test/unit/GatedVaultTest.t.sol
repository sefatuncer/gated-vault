// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20, IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { MockUSDC } from "../../contracts/mocks/MockUSDC.sol";
import { MockERC777 } from "../../contracts/mocks/MockERC777.sol";
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
        // After todo-13 (tracked AUM in `totalAssets()`), the donation no
        // longer warps share price. Victim's redemption value should be
        // within 1% of their deposit (some dust drift from offset math is
        // acceptable; catastrophic dilution is not).
        uint256 victimRedemption = vault.previewRedeem(victimShares);
        assertGe(victimRedemption, victimDeposit * 99 / 100, "victim redemption diluted past 1%");
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

    // -------- Tracked AUM + toxic asset reject (todo-13) --------

    function test_TotalAssetsZeroBeforeAnyDeposit() public view {
        assertEq(vault.totalAssets(), 0, "fresh vault must report zero AUM");
    }

    function test_TotalAssetsEqualsPrincipalBeforeYield() public {
        uint256 amount = 100 * 10 ** usdc.decimals();
        _aliceDeposits(amount);
        // No time elapsed -> no pending yield -> totalAssets == principal
        assertEq(vault.totalAssets(), amount, "totalAssets equals principal pre-yield");
    }

    function test_TotalAssetsIncludesPendingYield() public {
        uint256 amount = 100 * 10 ** usdc.decimals();
        _aliceDeposits(amount);
        _ownerFundsReserve(50 * 10 ** usdc.decimals());

        vm.warp(block.timestamp + 30 days);
        uint256 pending = vault.pendingYield();
        assertGt(pending, 0, "fixture must produce nonzero pending yield");
        assertEq(vault.totalAssets(), amount + pending, "totalAssets = principal + pendingYield");
    }

    function test_DonationDoesNotWarpShares() public {
        uint256 deposit = 100 * 10 ** usdc.decimals();
        _aliceDeposits(deposit);

        // Capture share-quote BEFORE donation
        uint256 quote = 50 * 10 ** usdc.decimals();
        uint256 sharesBefore = vault.convertToShares(quote);

        // Anyone bare-transfers a large donation to the vault contract address.
        // Tracked AUM means `principal` does not change, so `totalAssets()` is
        // unaffected and `convertToShares()` returns the same number.
        address donator = makeAddr("donator");
        uint256 donation = 1000 * 10 ** usdc.decimals();
        usdc.mint(donator, donation);
        vm.prank(donator);
        bool ok = usdc.transfer(address(vault), donation);
        assertTrue(ok, "donation transfer return value");

        uint256 sharesAfter = vault.convertToShares(quote);
        assertEq(sharesBefore, sharesAfter, "donation must not warp share price");
    }

    function test_RejectsERC777Asset() public {
        MockERC777 erc777 = new MockERC777();
        vm.expectRevert(GatedVault.ERC777NotSupported.selector);
        new GatedVault(IERC20Metadata(address(erc777)), owner, INITIAL_YIELD_RATE);
    }

    // -------- Deposit flow (todo-14) --------

    function test_FirstDepositMintsCorrectShares() public {
        // Virtual-shares math at first deposit:
        //   shares = assets * (totalSupply + 10^offset) / (totalAssets + 1)
        //          = assets * 10^6 / 1
        // For 100 USDC = 100e6 wei, expected = 1e14 shares.
        uint256 amount = 100 * 10 ** usdc.decimals();
        (, uint256 shares) = _aliceDeposits(amount);

        uint256 expected = amount * (10 ** 6); // virtual-shares scale
        assertEq(shares, expected, "first deposit shares math");
    }

    function test_SecondDepositProportionalShares() public {
        uint256 amount = 100 * 10 ** usdc.decimals();
        (, uint256 aliceShares) = _aliceDeposits(amount);

        // Bob deposits the same amount immediately — no yield elapsed.
        // Bob's shares should be approximately equal to Alice's.
        address bob = makeAddr("bob");
        usdc.mint(bob, amount);
        vm.startPrank(bob);
        usdc.approve(address(vault), type(uint256).max);
        uint256 bobShares = vault.deposit(amount, bob);
        vm.stopPrank();

        // Tolerance: 0.01% — second-depositor sees one extra unit of accounted
        // assets vs supply, so shares can drift by a wei-level amount.
        assertApproxEqRel(bobShares, aliceShares, 1e14, "equal-deposit shares within tolerance");
    }

    function test_DepositZeroReverts() public {
        address alice = makeAddr("alice");
        usdc.mint(alice, 100 * 10 ** usdc.decimals());
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert(GatedVault.ZeroAssets.selector);
        vault.deposit(0, alice);
        vm.stopPrank();
    }

    function test_DepositMaxUint256Reverts() public {
        // The math `assets * (totalSupply + 10^offset)` overflows uint256
        // when assets is type(uint256).max. Solidity 0.8+ checked arithmetic
        // panics with the well-known 0x11 selector.
        address alice = makeAddr("alice");
        // Mint full uint256 supply isn't realistic, but the math overflow is
        // checked before the transferFrom path even runs.
        usdc.mint(alice, type(uint128).max);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert(); // Panic(0x11) arithmetic overflow
        vault.deposit(type(uint256).max, alice);
        vm.stopPrank();
    }

    function test_DepositToReceiver() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        uint256 amount = 100 * 10 ** usdc.decimals();
        usdc.mint(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(amount, bob);
        vm.stopPrank();

        // Alice paid the asset, Bob received the shares.
        assertEq(usdc.balanceOf(alice), 0, "alice asset spent");
        assertEq(vault.balanceOf(bob), shares, "bob received shares");
        assertEq(vault.balanceOf(alice), 0, "alice received no shares");
    }

    function test_DepositEmitsEvent() public {
        address alice = makeAddr("alice");
        uint256 amount = 100 * 10 ** usdc.decimals();
        uint256 expectedShares = vault.previewDeposit(amount);
        usdc.mint(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectEmit(true, true, true, true, address(vault));
        emit IERC4626.Deposit(alice, alice, amount, expectedShares);
        vault.deposit(amount, alice);
        vm.stopPrank();
    }

    function test_DepositTransferFromCaller() public {
        address alice = makeAddr("alice");
        uint256 amount = 100 * 10 ** usdc.decimals();
        usdc.mint(alice, amount);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(amount, alice);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), aliceBefore - amount, "alice balance debit");
        assertEq(usdc.balanceOf(address(vault)), vaultBefore + amount, "vault balance credit");
    }

    function test_DepositRevertsInsufficientApproval() public {
        address alice = makeAddr("alice");
        uint256 amount = 100 * 10 ** usdc.decimals();
        uint256 capped = 50 * 10 ** usdc.decimals();
        usdc.mint(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), capped);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), capped, amount)
        );
        vault.deposit(amount, alice);
        vm.stopPrank();
    }

    // -------- Withdraw flow (todo-15) --------

    function test_WithdrawHappyPathNoYield() public {
        uint256 amount = 100 * 10 ** usdc.decimals();
        (address alice, uint256 shares) = _aliceDeposits(amount);

        // No time elapsed, no yield. Round-trip should be near-perfect; the
        // virtual-shares offset can leave a 1 wei drift from the rounding,
        // which is the standard OZ behavior.
        vm.prank(alice);
        uint256 assetsBack = vault.redeem(shares, alice, alice);

        assertApproxEqAbs(assetsBack, amount, 1, "round-trip deposit/redeem within 1 wei");
        assertEq(vault.balanceOf(alice), 0, "all alice shares burned");
        assertEq(vault.principal(), 0, "principal back to zero");
    }

    function test_WithdrawAfter30Days() public {
        uint256 amount = 100 * 10 ** usdc.decimals();
        uint256 reserveAmount = 50 * 10 ** usdc.decimals();
        (address alice, uint256 shares) = _aliceDeposits(amount);
        _ownerFundsReserve(reserveAmount);

        vm.warp(block.timestamp + 30 days);

        uint256 expectedYield = (amount * INITIAL_YIELD_RATE * 30 days) / (10_000 * vault.SECONDS_PER_YEAR());
        uint256 expectedTotal = amount + expectedYield;

        vm.prank(alice);
        uint256 assetsBack = vault.redeem(shares, alice, alice);

        assertApproxEqRel(assetsBack, expectedTotal, 1e16, "30d yield match within 1%");
    }

    function test_WithdrawAfterYearReturnsYield() public {
        uint256 amount = 100 * 10 ** usdc.decimals();
        uint256 reserveAmount = 50 * 10 ** usdc.decimals();
        (address alice, uint256 shares) = _aliceDeposits(amount);
        _ownerFundsReserve(reserveAmount);

        vm.warp(block.timestamp + 365 days);

        // 5% APY * 100 USDC * 1 year = 5 USDC yield
        uint256 expectedYield = 5 * 10 ** usdc.decimals();
        uint256 expectedTotal = amount + expectedYield;

        vm.prank(alice);
        uint256 assetsBack = vault.redeem(shares, alice, alice);

        assertApproxEqRel(assetsBack, expectedTotal, 1e16, "1-year 5% yield realized");
    }

    function test_WithdrawAllShares() public {
        uint256 amount = 100 * 10 ** usdc.decimals();
        (address alice, uint256 shares) = _aliceDeposits(amount);

        uint256 maxRedeemable = vault.maxRedeem(alice);
        assertEq(maxRedeemable, shares, "maxRedeem matches balance");

        vm.prank(alice);
        vault.redeem(maxRedeemable, alice, alice);

        assertEq(vault.balanceOf(alice), 0, "all shares redeemed");
        assertEq(vault.totalSupply(), 0, "total supply zero");
    }

    function test_WithdrawZeroReverts() public {
        address alice = makeAddr("alice");
        // No setup needed; ZeroAssets() rejects before any state read.
        vm.prank(alice);
        vm.expectRevert(GatedVault.ZeroAssets.selector);
        vault.withdraw(0, alice, alice);
    }

    function test_WithdrawMoreThanBalanceReverts() public {
        uint256 amount = 100 * 10 ** usdc.decimals();
        (address alice, uint256 shares) = _aliceDeposits(amount);

        uint256 tooMany = shares + 1;
        uint256 maxR = vault.maxRedeem(alice);
        vm.prank(alice);
        // OZ v5 ERC4626 emits ERC4626ExceededMaxRedeem(owner, shares, max).
        // We pre-compute selector + args to avoid the inline-call gotcha.
        bytes memory expectedRevert =
            abi.encodeWithSignature("ERC4626ExceededMaxRedeem(address,uint256,uint256)", alice, tooMany, maxR);
        vm.expectRevert(expectedRevert);
        vault.redeem(tooMany, alice, alice);
    }

    function test_WithdrawByApprovedSpender() public {
        uint256 amount = 100 * 10 ** usdc.decimals();
        (address alice, uint256 shares) = _aliceDeposits(amount);

        address bob = makeAddr("bob");
        address charlie = makeAddr("charlie");

        // Alice approves Bob to spend her vault shares (ERC-4626 share is ERC-20).
        vm.prank(alice);
        vault.approve(bob, shares);

        // Bob redeems Alice's shares, sends asset to Charlie.
        vm.prank(bob);
        uint256 assetsBack = vault.redeem(shares, charlie, alice);

        assertEq(usdc.balanceOf(charlie), assetsBack, "charlie received asset");
        assertEq(vault.balanceOf(alice), 0, "alice shares burned");
        assertEq(vault.allowance(alice, bob), 0, "allowance fully spent");
    }

    function test_WithdrawEmitsEvent() public {
        uint256 amount = 100 * 10 ** usdc.decimals();
        (address alice, uint256 shares) = _aliceDeposits(amount);

        uint256 expectedAssets = vault.previewRedeem(shares);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(vault));
        emit IERC4626.Withdraw(alice, alice, alice, expectedAssets, shares);
        vault.redeem(shares, alice, alice);
    }

    // -------- Yield distribution + rate change + edge cases (todo-16) --------

    /// @dev Helper: deposits `amount` for a named address.
    function _userDeposits(string memory label, uint256 amount) internal returns (address user, uint256 shares) {
        user = makeAddr(label);
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), type(uint256).max);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
    }

    function test_MultiUserProportionalYield() public {
        uint256 unit = 10 ** usdc.decimals();
        uint256 aliceAmount = 100 * unit;
        uint256 bobAmount = 200 * unit;

        // Both deposit at the same block — no fairness skew from timestamp.
        (address alice, uint256 aliceShares) = _userDeposits("alice", aliceAmount);
        (address bob, uint256 bobShares) = _userDeposits("bob", bobAmount);

        _ownerFundsReserve(50 * unit);

        vm.warp(block.timestamp + 365 days);

        vm.prank(alice);
        uint256 aliceBack = vault.redeem(aliceShares, alice, alice);
        vm.prank(bob);
        uint256 bobBack = vault.redeem(bobShares, bob, bob);

        uint256 aliceYield = aliceBack - aliceAmount;
        uint256 bobYield = bobBack - bobAmount;

        // Bob deposited 2x Alice -> Bob yield should be ~2x Alice yield
        assertApproxEqRel(bobYield, aliceYield * 2, 1e16, "Bob yield ~= 2x Alice yield");

        // Total realized yield should be ~5% of total principal (300 * 0.05 = 15)
        uint256 totalYield = aliceYield + bobYield;
        assertApproxEqRel(totalYield, 15 * unit, 1e16, "total yield ~5% of total principal");
    }

    function test_LateDepositorGetsCorrectShare() public {
        uint256 unit = 10 ** usdc.decimals();
        uint256 amount = 100 * unit;

        (address alice, uint256 aliceShares) = _userDeposits("alice", amount);
        _ownerFundsReserve(50 * unit);

        // Half a year passes -> Alice has accrued 2.5 USDC pending yield
        vm.warp(block.timestamp + 182.5 days);

        // Bob's deposit triggers _harvestYield, realizing Alice's pending yield
        // into principal. Bob then mints shares against the post-harvest state.
        (address bob, uint256 bobShares) = _userDeposits("bob", amount);

        // Another half year passes
        vm.warp(block.timestamp + 182.5 days);

        vm.prank(alice);
        uint256 aliceBack = vault.redeem(aliceShares, alice, alice);
        vm.prank(bob);
        uint256 bobBack = vault.redeem(bobShares, bob, bob);

        uint256 aliceYield = aliceBack - amount;
        uint256 bobYield = bobBack - amount;

        // Alice was in for the full year, Bob only for the second half.
        // Temporal fairness: Alice yield > Bob yield.
        assertGt(aliceYield, bobYield, "earlier depositor accrues more yield");

        // Bob's yield window is exactly half. Alice's window is full year on
        // a principal that grew at the half-year mark; her yield is roughly
        // 2x Bob's (within tolerance for the principal step at T+6m).
        assertApproxEqRel(aliceYield, bobYield * 2, 5e16, "Alice yield ~2x Bob yield (5% tol)");
    }

    function test_HarvestEventEmittedWithAmount() public {
        uint256 unit = 10 ** usdc.decimals();
        uint256 amount = 100 * unit;
        _userDeposits("alice", amount);
        _ownerFundsReserve(50 * unit);

        vm.warp(block.timestamp + 30 days);
        uint256 expectedYield = vault.pendingYield();
        assertGt(expectedYield, 0, "fixture must produce nonzero yield");

        vm.expectEmit(true, true, true, true, address(vault));
        emit GatedVault.YieldHarvested(expectedYield);
        vault.harvest();
    }

    function test_ZeroYieldRateNoAccrual() public {
        uint256 unit = 10 ** usdc.decimals();
        uint256 amount = 100 * unit;

        // Owner sets the yield rate to zero before any deposit.
        vm.prank(owner);
        vault.setYieldRate(0);

        (address alice, uint256 aliceShares) = _userDeposits("alice", amount);

        // A full year goes by; with rate=0, no yield should accrue regardless.
        vm.warp(block.timestamp + 365 days);
        assertEq(vault.pendingYield(), 0, "zero rate must produce zero yield");

        vm.prank(alice);
        uint256 aliceBack = vault.redeem(aliceShares, alice, alice);

        // Round-trip within 1 wei (only the offset-rounding drift remains).
        assertApproxEqAbs(aliceBack, amount, 1, "redemption equals deposit at zero rate");
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
