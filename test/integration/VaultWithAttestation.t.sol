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

    // -------- Credential type enforcement (todo-38) --------

    bytes32 internal constant TYPE_INVESTOR = keccak256("VerifiedInvestor");
    bytes32 internal constant TYPE_KYC = keccak256("KYCApproved");

    function _setRequiredType(bytes32 t) internal {
        vm.prank(owner);
        vault.setRequiredCredentialType(t);
    }

    /// @dev Happy path with a type filter: the attestation's credentialHash
    ///      matches `requiredCredentialType`, so the deposit clears.
    function test_TypeMatchDepositSucceeds() public {
        _setRequiredType(TYPE_INVESTOR);

        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes32 nonce = keccak256("alice-type-match");
        bytes memory sig = _sign(alice, TYPE_INVESTOR, expiry, nonce);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares = vault.depositWithAttestation(DEPOSIT, alice, TYPE_INVESTOR, expiry, nonce, sig);
        vm.stopPrank();

        assertGt(shares, 0, "type-matching deposit failed");
        assertEq(verifier.attestedCredentialType(alice), TYPE_INVESTOR, "recorded type mismatch");
    }

    /// @dev Wrong type on the vault's own entry point reverts early with
    ///      CredentialTypeMismatch, before the nonce is consumed.
    function test_WrongTypeDepositWithAttestationReverts() public {
        _setRequiredType(TYPE_INVESTOR);

        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes32 nonce = keccak256("alice-wrong-type");
        bytes memory sig = _sign(alice, TYPE_KYC, expiry, nonce);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(GatedVault.CredentialTypeMismatch.selector, TYPE_KYC, TYPE_INVESTOR));
        vault.depositWithAttestation(DEPOSIT, alice, TYPE_KYC, expiry, nonce, sig);
        vm.stopPrank();

        // Nonce preserved: the wrong-type attempt did not consume it.
        assertFalse(verifier.usedNonces(nonce), "wrong-type attempt burned the nonce");
    }

    /// @dev Migration: after the owner switches the required type, an old-type
    ///      attestation no longer clears the vault entry point, and a holder
    ///      attested under the old type can no longer plain-deposit either
    ///      (the gate's recorded-type clause rejects the stale session).
    function test_OldTypeAttestationFailsAfterChange() public {
        _setRequiredType(TYPE_INVESTOR);

        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes32 nonce1 = keccak256("alice-old-type-1");
        bytes memory sig1 = _sign(alice, TYPE_INVESTOR, expiry, nonce1);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.depositWithAttestation(DEPOSIT, alice, TYPE_INVESTOR, expiry, nonce1, sig1);
        vm.stopPrank();

        // Owner migrates to a new KYC standard.
        _setRequiredType(TYPE_KYC);

        // A fresh old-type attestation is rejected early at the entry point.
        bytes32 nonce2 = keccak256("alice-old-type-2");
        bytes memory sig2 = _sign(alice, TYPE_INVESTOR, expiry, nonce2);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(GatedVault.CredentialTypeMismatch.selector, TYPE_INVESTOR, TYPE_KYC));
        vault.depositWithAttestation(DEPOSIT, alice, TYPE_INVESTOR, expiry, nonce2, sig2);

        // The still-live old-type session no longer satisfies the gate, so
        // her plain deposit falls through to the whitelist and reverts.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Whitelist.NotWhitelisted.selector, alice));
        vault.deposit(DEPOSIT, alice);
    }

    /// @dev After the owner switches the required type, an attestation of the
    ///      new type clears the gate.
    function test_NewTypeAttestationSucceedsAfterChange() public {
        _setRequiredType(TYPE_INVESTOR);
        _setRequiredType(TYPE_KYC);

        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes32 nonce = keccak256("alice-new-type");
        bytes memory sig = _sign(alice, TYPE_KYC, expiry, nonce);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares = vault.depositWithAttestation(DEPOSIT, alice, TYPE_KYC, expiry, nonce, sig);
        vm.stopPrank();

        assertGt(shares, 0, "new-type deposit failed");
    }

    /// @dev Audit-grade bypass closure: a caller who consumes a wrong-type
    ///      (but trusted-signed) attestation directly on the verifier —
    ///      skipping the vault's early type check — still cannot deposit. The
    ///      gate reads the recorded `attestedCredentialType`, which does not
    ///      match `requiredCredentialType`, so the deposit falls through to
    ///      the whitelist and reverts. This is the property that makes the
    ///      on-chain type filter real rather than theater.
    function test_DirectConsumeWrongTypeCannotBypassGate() public {
        _setRequiredType(TYPE_INVESTOR);

        // Attacker holds a valid, trusted-signed attestation of the WRONG
        // type and consumes it directly on the verifier.
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes32 nonce = keccak256("alice-direct-consume");
        bytes memory sig = _sign(alice, TYPE_KYC, expiry, nonce);
        IdentityVerifier.Attestation memory a =
            IdentityVerifier.Attestation({ user: alice, credentialHash: TYPE_KYC, expiry: expiry, nonce: nonce });
        verifier.consumeAttestation(a, sig);

        assertEq(verifier.attestedUntil(alice), expiry, "direct consume did not set session");
        assertEq(verifier.attestedCredentialType(alice), TYPE_KYC, "direct consume did not record type");

        // The plain deposit still reverts: recorded type != required type.
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(Whitelist.NotWhitelisted.selector, alice));
        vault.deposit(DEPOSIT, alice);
        vm.stopPrank();
    }
}
