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
}
