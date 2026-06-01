// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { MockUSDC } from "../../contracts/mocks/MockUSDC.sol";
import { GatedVault } from "../../contracts/GatedVault.sol";
import { Whitelist } from "../../contracts/access/Whitelist.sol";
import { IdentityVerifier } from "../../contracts/identity/IdentityVerifier.sol";

/// @title  VaultWithAttestationTest
/// @author Sefa Tunçer
/// @notice Integration tests for `GatedVault.depositWithAttestation` wired to
///         a live `IdentityVerifier` (todo-37). Exercises the Variant A
///         policy: a valid EIP-712 attestation lets a non-whitelisted
///         receiver deposit, while the plain ERC-4626 path still gates on
///         the whitelist. Covers the verifier's revert taxonomy reaching the
///         vault unchanged and the session-model consequence (an attested
///         receiver can plain-deposit within the attestation window).
contract VaultWithAttestationTest is Test {
    uint256 internal constant INITIAL_YIELD_RATE = 500; // 5% APY (basis points)

    MockUSDC internal usdc;
    Whitelist internal whitelist;
    IdentityVerifier internal verifier;
    GatedVault internal vault;

    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("verifier-admin");
    address internal alice = makeAddr("alice"); // never whitelisted; uses the VC path
    address internal bob = makeAddr("bob"); // whitelisted; uses the plain path

    uint256 internal constant SIGNER_KEY = uint256(keccak256("vault-integration-signer-key"));
    address internal signer;

    uint256 internal constant DEPOSIT = 100e6; // 100 USDC (6 decimals)

    function setUp() public {
        usdc = new MockUSDC();
        whitelist = new Whitelist(owner);
        verifier = new IdentityVerifier(admin);

        signer = vm.addr(SIGNER_KEY);
        bytes32 signerRole = verifier.SIGNER_ROLE();
        vm.prank(admin);
        verifier.grantRole(signerRole, signer);

        vault = new GatedVault(IERC20Metadata(address(usdc)), owner, INITIAL_YIELD_RATE, whitelist, verifier);

        // Fund both actors; approvals are set per-actor in the helpers.
        usdc.mint(alice, 10 * DEPOSIT);
        usdc.mint(bob, 10 * DEPOSIT);
    }

    // -------- Helpers --------

    function _credentialHash(address user) internal pure returns (bytes32) {
        // Deterministic, distinct credential hash per user. The vault does
        // not inspect the credential type on-chain (off-chain signer's job),
        // so any value the trusted signer signs is accepted.
        return keccak256(abi.encode("kyc-credential", user));
    }

    function _sign(
        address user,
        bytes32 credentialHash,
        uint64 expiry,
        bytes32 nonce
    )
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = verifier.hashAttestation(user, credentialHash, expiry, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    // -------- Variant A: VC path --------

    function test_DepositWithValidAttestation() public {
        assertFalse(whitelist.isWhitelisted(alice), "alice must not be whitelisted for this test");

        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes32 nonce = keccak256("alice-nonce-1");
        bytes32 credentialHash = _credentialHash(alice);
        bytes memory sig = _sign(alice, credentialHash, expiry, nonce);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares = vault.depositWithAttestation(DEPOSIT, alice, credentialHash, expiry, nonce, sig);
        vm.stopPrank();

        assertGt(shares, 0, "no shares minted");
        assertEq(vault.balanceOf(alice), shares, "share balance mismatch");
        assertEq(vault.principal(), DEPOSIT, "principal not tracked");
        assertEq(verifier.attestedUntil(alice), expiry, "attestedUntil not recorded");
        assertTrue(verifier.usedNonces(nonce), "nonce not marked used");
    }

    function test_DepositWithoutAttestationRevertsForNonWhitelist() public {
        // Plain ERC-4626 path, no attestation: the gate falls through to the
        // whitelist and reverts with the familiar NotWhitelisted.
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(Whitelist.NotWhitelisted.selector, alice));
        vault.deposit(DEPOSIT, alice);
        vm.stopPrank();
    }

    function test_DepositWithExpiredAttestationReverts() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes32 nonce = keccak256("alice-nonce-expired");
        bytes32 credentialHash = _credentialHash(alice);
        bytes memory sig = _sign(alice, credentialHash, expiry, nonce);

        // Move past expiry so consumeAttestation's strict `expiry < now` fires.
        vm.warp(uint256(expiry) + 1);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IdentityVerifier.AttestationExpired.selector, expiry));
        vault.depositWithAttestation(DEPOSIT, alice, credentialHash, expiry, nonce, sig);
        vm.stopPrank();
    }

    function test_DepositWithReplayedAttestationReverts() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes32 nonce = keccak256("alice-nonce-replay");
        bytes32 credentialHash = _credentialHash(alice);
        bytes memory sig = _sign(alice, credentialHash, expiry, nonce);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.depositWithAttestation(DEPOSIT, alice, credentialHash, expiry, nonce, sig);

        // Second use of the same nonce must revert at the verifier.
        vm.expectRevert(abi.encodeWithSelector(IdentityVerifier.AttestationReplayed.selector, nonce));
        vault.depositWithAttestation(DEPOSIT, alice, credentialHash, expiry, nonce, sig);
        vm.stopPrank();
    }

    function test_DepositWithUntrustedSignerReverts() public {
        uint256 strangerKey = uint256(keccak256("not-a-signer"));
        address strangerSigner = vm.addr(strangerKey);

        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes32 nonce = keccak256("alice-nonce-untrusted");
        bytes32 credentialHash = _credentialHash(alice);
        bytes32 digest = verifier.hashAttestation(alice, credentialHash, expiry, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(strangerKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IdentityVerifier.UntrustedSigner.selector, strangerSigner));
        vault.depositWithAttestation(DEPOSIT, alice, credentialHash, expiry, nonce, sig);
        vm.stopPrank();
    }

    // -------- Coexistence: whitelist path stays live --------

    function test_WhitelistedUserStillDepositsWithoutAttestation() public {
        vm.prank(owner);
        whitelist.setWhitelist(bob, true);

        vm.startPrank(bob);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(DEPOSIT, bob);
        vm.stopPrank();

        assertGt(shares, 0, "whitelisted plain deposit failed");
        assertEq(vault.balanceOf(bob), shares, "bob share balance mismatch");
        assertEq(verifier.attestedUntil(bob), 0, "whitelisted path must not touch the verifier");
    }

    /// @dev Session-model disclosure: once an attestation is consumed,
    ///      `attestedUntil[alice]` gates her plain deposits for the whole
    ///      validity window. This is intended (an attestation is a
    ///      time-boxed deposit window, not a single-shot proof); the test
    ///      pins it so the behavior is a documented decision, not a silent
    ///      surprise.
    function test_AttestedUserCanPlainDepositWithinWindow() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes32 nonce = keccak256("alice-nonce-session");
        bytes32 credentialHash = _credentialHash(alice);
        bytes memory sig = _sign(alice, credentialHash, expiry, nonce);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.depositWithAttestation(DEPOSIT, alice, credentialHash, expiry, nonce, sig);

        // No new attestation: the plain path passes because the session
        // record is still live.
        uint256 shares = vault.deposit(DEPOSIT, alice);
        vm.stopPrank();

        assertGt(shares, 0, "plain deposit within window failed");
        assertEq(vault.principal(), 2 * DEPOSIT, "both deposits not tracked");
    }

    /// @dev After the window closes, the session record no longer satisfies
    ///      the gate and the plain path reverts on the whitelist again.
    function test_AttestedUserPlainDepositRevertsAfterExpiry() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes32 nonce = keccak256("alice-nonce-window-close");
        bytes32 credentialHash = _credentialHash(alice);
        bytes memory sig = _sign(alice, credentialHash, expiry, nonce);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.depositWithAttestation(DEPOSIT, alice, credentialHash, expiry, nonce, sig);
        vm.stopPrank();

        // Advance past the attestation window.
        vm.warp(uint256(expiry) + 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Whitelist.NotWhitelisted.selector, alice));
        vault.deposit(DEPOSIT, alice);
    }
}
