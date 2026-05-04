// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { MockUSDC } from "../../contracts/mocks/MockUSDC.sol";
import { GatedVault } from "../../contracts/GatedVault.sol";

/// @title  GatedVaultTest (skeleton smoke tests)
/// @notice Constructor and metadata sanity checks for the empty vault shell.
///         Deposit/withdraw flow, decimals offset, yield, and VC-gating
///         tests live in later todo-specific test files.
contract GatedVaultTest is Test {
    MockUSDC internal usdc;
    GatedVault internal vault;
    address internal owner = makeAddr("owner");

    function setUp() public {
        usdc = new MockUSDC();
        vault = new GatedVault(IERC20Metadata(address(usdc)), owner);
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
}
