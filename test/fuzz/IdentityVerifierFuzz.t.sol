// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IdentityVerifier } from "../../contracts/identity/IdentityVerifier.sol";

/// @title  IdentityVerifierFuzzTest
/// @author Sefa Tunçer
/// @notice Property-based tests for `IdentityVerifier.consumeAttestation`
///         (todo-39). Each property guards one invariant across the random
///         input space: the happy-path state writes, the expiry / replay /
///         untrusted-signer reverts, and the digest field-binding that makes
///         a tampered attestation unauthenticatable. Stateful invariants
///         (handler-driven) live in the Faz-7 suite.
contract IdentityVerifierFuzzTest is Test {
    IdentityVerifier internal verifier;

    address internal admin = makeAddr("admin");
    address internal user = makeAddr("alice");

    uint256 internal constant SIGNER_KEY = uint256(keccak256("identity-verifier-fuzz-signer-key"));
    address internal signer;

    /// @dev secp256k1 group order; upper bound (exclusive) for valid keys.
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function setUp() public {
        verifier = new IdentityVerifier(admin);

        signer = vm.addr(SIGNER_KEY);
        bytes32 signerRole = verifier.SIGNER_ROLE();
        vm.prank(admin);
        verifier.grantRole(signerRole, signer);

        // Baseline timestamp well above zero so "past expiry" fuzzing has
        // room to bound an expiry strictly below `block.timestamp`.
        vm.warp(1_000_000_000);
    }

    function _sign(IdentityVerifier.Attestation memory a, uint256 key) internal view returns (bytes memory) {
        bytes32 digest = verifier.hashAttestation(a.user, a.credentialHash, a.expiry, a.nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev A valid attestation, for any (expiry, nonce, credentialHash) in
    ///      range, performs all three state writes: nonce marked,
    ///      `attestedUntil` set, and `attestedCredentialType` recorded
    ///      (todo-38 type record holds across the whole type space).
    function testFuzz_ConsumeHappyPathInvariant(uint64 expiry, bytes32 nonce, bytes32 credentialHash) public {
        expiry = uint64(bound(expiry, block.timestamp, block.timestamp + 365 days));

        IdentityVerifier.Attestation memory a =
            IdentityVerifier.Attestation({ user: user, credentialHash: credentialHash, expiry: expiry, nonce: nonce });
        bytes memory sig = _sign(a, SIGNER_KEY);

        verifier.consumeAttestation(a, sig);

        assertTrue(verifier.usedNonces(nonce), "nonce not marked");
        assertEq(verifier.attestedUntil(user), expiry, "attestedUntil mismatch");
        assertEq(verifier.attestedCredentialType(user), credentialHash, "credential type not recorded");
    }

    /// @dev Any expiry strictly in the past reverts with `AttestationExpired`,
    ///      even when the signature is otherwise valid. Fail-fast: the
    ///      expiry check precedes signature recovery.
    function testFuzz_ExpiredAlwaysReverts(uint64 expiry) public {
        expiry = uint64(bound(expiry, 0, block.timestamp - 1));

        IdentityVerifier.Attestation memory a = IdentityVerifier.Attestation({
            user: user,
            credentialHash: keccak256("cred"),
            expiry: expiry,
            nonce: keccak256(abi.encode("expired-nonce", expiry))
        });
        bytes memory sig = _sign(a, SIGNER_KEY);

        vm.expectRevert(abi.encodeWithSelector(IdentityVerifier.AttestationExpired.selector, expiry));
        verifier.consumeAttestation(a, sig);
    }

    /// @dev A nonce is single-use across the whole nonce space: the second
    ///      consume of any nonce reverts with `AttestationReplayed`.
    function testFuzz_ReplayAlwaysReverts(bytes32 nonce) public {
        IdentityVerifier.Attestation memory a = IdentityVerifier.Attestation({
            user: user, credentialHash: keccak256("cred"), expiry: uint64(block.timestamp + 1 hours), nonce: nonce
        });
        bytes memory sig = _sign(a, SIGNER_KEY);

        verifier.consumeAttestation(a, sig);

        vm.expectRevert(abi.encodeWithSelector(IdentityVerifier.AttestationReplayed.selector, nonce));
        verifier.consumeAttestation(a, sig);
    }

    /// @dev No key outside `SIGNER_ROLE` can produce a consumable attestation,
    ///      across the full private-key space. The signature is well-formed
    ///      (the random key signs the real digest), so recovery succeeds to
    ///      the random address, which simply lacks the role.
    function testFuzz_UntrustedSignerAlwaysReverts(uint256 pk) public {
        pk = bound(pk, 1, SECP256K1_N - 1);
        address randomSigner = vm.addr(pk);
        vm.assume(randomSigner != signer);

        IdentityVerifier.Attestation memory a = IdentityVerifier.Attestation({
            user: user,
            credentialHash: keccak256("cred"),
            expiry: uint64(block.timestamp + 1 hours),
            nonce: keccak256(abi.encode("untrusted-nonce", pk))
        });
        bytes memory sig = _sign(a, pk);

        vm.expectRevert(abi.encodeWithSelector(IdentityVerifier.UntrustedSigner.selector, randomSigner));
        verifier.consumeAttestation(a, sig);
    }

    /// @dev Digest field-binding: mutating any signed field after the
    ///      signature is produced breaks authentication. The mutated message
    ///      recovers to a different address, which lacks the role, so the
    ///      consume reverts `UntrustedSigner(recovered)`. `expiry` is left
    ///      untouched so the path always reaches signature recovery rather
    ///      than short-circuiting on the expiry / replay checks.
    function testFuzz_TamperedSignedFieldReverts(uint8 sel, bytes32 mutation) public {
        IdentityVerifier.Attestation memory base = IdentityVerifier.Attestation({
            user: user,
            credentialHash: keccak256("cred-base"),
            expiry: uint64(block.timestamp + 1 hours),
            nonce: keccak256("nonce-base")
        });
        bytes memory sig = _sign(base, SIGNER_KEY);

        IdentityVerifier.Attestation memory tampered = base;
        uint8 field = sel % 3;
        if (field == 0) {
            address mutatedUser = address(uint160(uint256(mutation)));
            vm.assume(mutatedUser != base.user);
            tampered.user = mutatedUser;
        } else if (field == 1) {
            vm.assume(mutation != base.credentialHash);
            tampered.credentialHash = mutation;
        } else {
            vm.assume(mutation != base.nonce);
            tampered.nonce = mutation;
        }

        bytes32 digest =
            verifier.hashAttestation(tampered.user, tampered.credentialHash, tampered.expiry, tampered.nonce);
        address recovered = ECDSA.recover(digest, sig);
        vm.assume(recovered != signer);

        vm.expectRevert(abi.encodeWithSelector(IdentityVerifier.UntrustedSigner.selector, recovered));
        verifier.consumeAttestation(tampered, sig);
    }
}
