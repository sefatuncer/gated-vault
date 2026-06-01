// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IdentityVerifier } from "../../contracts/identity/IdentityVerifier.sol";

/// @title  IdentityVerifierTest
/// @notice Skeleton tests (todo-30). Cover constructor wiring, role
///         seeding, EIP-712 domain visibility (ERC-5267), and default
///         state. The attestation consumption flow tests land with
///         the implementation in todo-32.
contract IdentityVerifierTest is Test {
    IdentityVerifier internal verifier;

    address internal admin = makeAddr("admin");
    address internal stranger = makeAddr("stranger");

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant SIGNER_ROLE = keccak256("SIGNER_ROLE");

    // Deterministic signer keypair for consumeAttestation tests
    // (todo-32). Re-derived in setUp so the same admin grant applies
    // across the whole test contract.
    uint256 internal constant SIGNER_KEY = uint256(keccak256("identity-verifier-signer-key"));
    address internal signer;

    function setUp() public {
        verifier = new IdentityVerifier(admin);

        signer = vm.addr(SIGNER_KEY);
        vm.prank(admin);
        verifier.grantRole(SIGNER_ROLE, signer);
    }

    // -------- consumeAttestation helpers (todo-32) --------

    function _defaultAttestation() internal returns (IdentityVerifier.Attestation memory a) {
        a = IdentityVerifier.Attestation({
            user: makeAddr("alice"),
            credentialHash: keccak256("credential-identifier:alice"),
            expiry: uint64(block.timestamp + 1 hours),
            nonce: keccak256("nonce-alice-001")
        });
    }

    function _signWithKey(IdentityVerifier.Attestation memory a, uint256 key) internal view returns (bytes memory) {
        bytes32 digest = verifier.hashAttestation(a.user, a.credentialHash, a.expiry, a.nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev EIP-2098 compact signature: 64 bytes (r || vs) where
    ///      vs = s | ((v - 27) << 255). `vm.sign` produces canonical
    ///      low-s signatures, so the top bit of `s` is always zero
    ///      and is safe to overwrite with the recovery bit.
    function _signCompact(IdentityVerifier.Attestation memory a, uint256 key) internal view returns (bytes memory) {
        bytes32 digest = verifier.hashAttestation(a.user, a.credentialHash, a.expiry, a.nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        bytes32 vs = bytes32(uint256(s) | (uint256(v - 27) << 255));
        return abi.encodePacked(r, vs);
    }

    // -------- Constructor / roles --------

    function test_AdminHasDefaultAdminRole() public view {
        assertTrue(verifier.hasRole(DEFAULT_ADMIN_ROLE, admin), "admin lacks DEFAULT_ADMIN_ROLE");
    }

    function test_SignerRoleNotGrantedAtDeploy() public view {
        assertFalse(verifier.hasRole(SIGNER_ROLE, admin), "admin should not hold SIGNER_ROLE at deploy");
        assertFalse(verifier.hasRole(SIGNER_ROLE, stranger), "stranger should not hold SIGNER_ROLE");
    }

    function test_SignerRoleAdminIsDefaultAdmin() public view {
        assertEq(verifier.getRoleAdmin(SIGNER_ROLE), DEFAULT_ADMIN_ROLE, "SIGNER_ROLE admin must be DEFAULT_ADMIN_ROLE");
    }

    function test_SignerRoleHashMatches() public view {
        assertEq(verifier.SIGNER_ROLE(), SIGNER_ROLE, "SIGNER_ROLE constant drift");
    }

    // -------- EIP-712 domain (ERC-5267) --------

    function test_EIP712DomainExposesName() public view {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            verifier.eip712Domain();
        assertEq(name, "GatedVault.IdentityVerifier", "domain name");
        assertEq(version, "1", "domain version");
        assertEq(chainId, block.chainid, "domain chainId");
        assertEq(verifyingContract, address(verifier), "domain verifyingContract");
    }

    function test_EIP712DomainFieldsBitmap() public view {
        // OZ EIP712 sets bits 1..4 (name, version, chainId, verifyingContract)
        // and leaves salt + extensions empty: fields == 0x0f.
        (bytes1 fields,,,,,,) = verifier.eip712Domain();
        assertEq(fields, bytes1(0x0f), "ERC-5267 fields bitmap mismatch");
    }

    // -------- ADR-003 type hash pinning --------

    function test_AttestationTypehashMatchesADR003() public view {
        // Compare the contract's public constant against a freshly
        // computed keccak256 of the ADR-003 type string. Any drift
        // (whitespace, field order) fails here before it can break
        // the off-chain signer in production. This is the first
        // half of the CI gate that todo-34 will formalize.
        bytes32 expected = keccak256("Attestation(address user,bytes32 credentialHash,uint64 expiry,bytes32 nonce)");
        assertEq(verifier.ATTESTATION_TYPEHASH(), expected, "contract typehash drift vs ADR-003");
    }

    // -------- Default state --------

    function test_UsedNonceDefaultIsFalse() public view {
        bytes32 randomNonce = keccak256("never-used");
        assertFalse(verifier.usedNonces(randomNonce), "fresh nonce must be unused");
    }

    function test_AttestedUntilDefaultIsZero() public view {
        assertEq(verifier.attestedUntil(stranger), 0, "fresh address must have zero attested-until");
    }

    // -------- Role grant flow (skeleton smoke) --------

    function test_AdminCanGrantSignerRole() public {
        address localSigner = makeAddr("local-signer-grant");

        vm.prank(admin);
        verifier.grantRole(SIGNER_ROLE, localSigner);

        assertTrue(verifier.hasRole(SIGNER_ROLE, localSigner), "grant did not stick");
    }

    function test_AdminCanRevokeSignerRole() public {
        address localSigner = makeAddr("local-signer-revoke");

        vm.startPrank(admin);
        verifier.grantRole(SIGNER_ROLE, localSigner);
        verifier.revokeRole(SIGNER_ROLE, localSigner);
        vm.stopPrank();

        assertFalse(verifier.hasRole(SIGNER_ROLE, localSigner), "revoke did not stick");
    }

    // -------- EIP-712 hashing helpers --------

    function _sampleAttestation()
        internal
        pure
        returns (address user, bytes32 credentialHash, uint64 expiry, bytes32 nonce)
    {
        user = address(0xA11CE);
        credentialHash = keccak256("credential-identifier:user-A11CE");
        expiry = uint64(1_800_000_000); // arbitrary future-ish UNIX ts; helper does not validate
        nonce = keccak256("nonce-0001");
    }

    function test_HashAttestationStable() public view {
        (address user, bytes32 credentialHash, uint64 expiry, bytes32 nonce) = _sampleAttestation();

        bytes32 a = verifier.hashAttestation(user, credentialHash, expiry, nonce);
        bytes32 b = verifier.hashAttestation(user, credentialHash, expiry, nonce);

        assertEq(a, b, "deterministic helper produced different digests for the same inputs");
        assertTrue(a != bytes32(0), "digest must not be zero");
    }

    function test_HashAttestationChangesPerField() public view {
        (address user, bytes32 credentialHash, uint64 expiry, bytes32 nonce) = _sampleAttestation();
        bytes32 base = verifier.hashAttestation(user, credentialHash, expiry, nonce);

        // Flip each of the four message fields one at a time. Any
        // skipped field in `abi.encode` would surface here as a
        // collision with `base`.
        assertTrue(
            verifier.hashAttestation(address(0xBEEF), credentialHash, expiry, nonce) != base, "user field not hashed"
        );
        assertTrue(
            verifier.hashAttestation(user, keccak256("other-credential"), expiry, nonce) != base,
            "credentialHash field not hashed"
        );
        assertTrue(verifier.hashAttestation(user, credentialHash, expiry + 1, nonce) != base, "expiry field not hashed");
        assertTrue(
            verifier.hashAttestation(user, credentialHash, expiry, keccak256("other-nonce")) != base,
            "nonce field not hashed"
        );
    }

    function test_HashAttestationMatchesManualReconstruction() public view {
        (address user, bytes32 credentialHash, uint64 expiry, bytes32 nonce) = _sampleAttestation();

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Attestation(address user,bytes32 credentialHash,uint64 expiry,bytes32 nonce)"),
                user,
                credentialHash,
                expiry,
                nonce
            )
        );

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("GatedVault.IdentityVerifier")),
                keccak256(bytes("1")),
                block.chainid,
                address(verifier)
            )
        );

        bytes32 expected = keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));

        assertEq(
            verifier.hashAttestation(user, credentialHash, expiry, nonce),
            expected,
            "helper digest drifted from EIP-712 spec reconstruction"
        );
    }

    function test_DomainSeparatorMatchesEIP712Spec() public view {
        // OZ EIP712's internal separator is not directly readable. We
        // assert it matches the EIP-712 spec by checking that the
        // spec-formula separator, when wrapped around our struct
        // hash, reproduces the helper's output. If an OZ upgrade
        // changes the internal layout, this drift surfaces here.
        bytes32 specSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("GatedVault.IdentityVerifier")),
                keccak256(bytes("1")),
                block.chainid,
                address(verifier)
            )
        );

        (address user, bytes32 credentialHash, uint64 expiry, bytes32 nonce) = _sampleAttestation();
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Attestation(address user,bytes32 credentialHash,uint64 expiry,bytes32 nonce)"),
                user,
                credentialHash,
                expiry,
                nonce
            )
        );

        bytes32 specDigest = keccak256(abi.encodePacked(hex"1901", specSeparator, structHash));

        assertEq(
            verifier.hashAttestation(user, credentialHash, expiry, nonce),
            specDigest,
            "OZ domain separator drifted from EIP-712 spec"
        );
    }

    function test_HashAttestationDistinctFromBareStructHash() public view {
        // ADR-003 rejected "ECDSA over raw keccak256(abi.encode(...))" because the bare
        // struct hash collides with possible transaction hashes. Lock the distinction in
        // a test fixture: the helper output must NOT equal the bare struct hash.
        (address user, bytes32 credentialHash, uint64 expiry, bytes32 nonce) = _sampleAttestation();

        bytes32 bareStructHash = keccak256(
            abi.encode(
                keccak256("Attestation(address user,bytes32 credentialHash,uint64 expiry,bytes32 nonce)"),
                user,
                credentialHash,
                expiry,
                nonce
            )
        );

        bytes32 wrapped = verifier.hashAttestation(user, credentialHash, expiry, nonce);

        assertTrue(wrapped != bareStructHash, "wrapped digest must differ from bare struct hash");
    }

    // -------- consumeAttestation smoke (todo-32) --------

    function test_ConsumeAttestationHappyPath() public {
        IdentityVerifier.Attestation memory a = _defaultAttestation();
        bytes memory sig = _signWithKey(a, SIGNER_KEY);

        vm.expectEmit(true, true, false, true, address(verifier));
        emit IdentityVerifier.AttestationConsumed(a.user, a.nonce, a.expiry);

        verifier.consumeAttestation(a, sig);

        assertTrue(verifier.usedNonces(a.nonce), "nonce not marked used");
        assertEq(verifier.attestedUntil(a.user), a.expiry, "attestedUntil not written");
    }

    function test_ConsumeRevertsOnExpired() public {
        IdentityVerifier.Attestation memory a = _defaultAttestation();
        // Move now past expiry so the check `expiry < block.timestamp` fires.
        vm.warp(uint256(a.expiry) + 1);
        bytes memory sig = _signWithKey(a, SIGNER_KEY);

        vm.expectRevert(abi.encodeWithSelector(IdentityVerifier.AttestationExpired.selector, a.expiry));
        verifier.consumeAttestation(a, sig);
    }

    function test_ConsumeRevertsOnReplay() public {
        IdentityVerifier.Attestation memory a = _defaultAttestation();
        bytes memory sig = _signWithKey(a, SIGNER_KEY);

        verifier.consumeAttestation(a, sig);

        vm.expectRevert(abi.encodeWithSelector(IdentityVerifier.AttestationReplayed.selector, a.nonce));
        verifier.consumeAttestation(a, sig);
    }

    function test_ConsumeRevertsOnUntrustedSigner() public {
        IdentityVerifier.Attestation memory a = _defaultAttestation();
        uint256 strangerKey = uint256(keccak256("not-a-signer"));
        address strangerSigner = vm.addr(strangerKey);
        bytes memory sig = _signWithKey(a, strangerKey);

        vm.expectRevert(abi.encodeWithSelector(IdentityVerifier.UntrustedSigner.selector, strangerSigner));
        verifier.consumeAttestation(a, sig);
    }

    function test_ConsumeRevertsOnMalformedSignature() public {
        IdentityVerifier.Attestation memory a = _defaultAttestation();
        // Length 7 -> ECDSA.tryRecover surfaces InvalidSignatureLength,
        // which we translate to SignatureInvalid().
        bytes memory sig = bytes("garbage");

        vm.expectRevert(IdentityVerifier.SignatureInvalid.selector);
        verifier.consumeAttestation(a, sig);
    }

    // -------- Nonce replay edge cases (todo-34) --------

    /// @dev State-transition focus: complements `test_ConsumeAttestationHappyPath`
    ///      by pinning the false -> true flip on `usedNonces[nonce]` around
    ///      a single consume call. A regression that skips the mark write
    ///      surfaces here even if the event + `attestedUntil` assertions
    ///      still pass elsewhere.
    function test_FirstUseFlipsNonceState() public {
        IdentityVerifier.Attestation memory a = _defaultAttestation();
        bytes memory sig = _signWithKey(a, SIGNER_KEY);

        assertFalse(verifier.usedNonces(a.nonce), "nonce dirty before first consume");
        verifier.consumeAttestation(a, sig);
        assertTrue(verifier.usedNonces(a.nonce), "first consume did not mark nonce");
    }

    /// @dev Mapping key isolation: a spent nonce must not poison sibling
    ///      keys. Two attestations for the same user with distinct nonces
    ///      both consume successfully, both flags land, and `attestedUntil`
    ///      reflects the latest expiry.
    function test_DifferentNonceTwiceSucceeds() public {
        IdentityVerifier.Attestation memory a1 = _defaultAttestation();
        bytes memory sig1 = _signWithKey(a1, SIGNER_KEY);
        verifier.consumeAttestation(a1, sig1);

        IdentityVerifier.Attestation memory a2 = _defaultAttestation();
        a2.nonce = keccak256("nonce-alice-002");
        a2.expiry = a1.expiry + 1;
        bytes memory sig2 = _signWithKey(a2, SIGNER_KEY);
        verifier.consumeAttestation(a2, sig2);

        assertTrue(verifier.usedNonces(a1.nonce), "first nonce unmarked");
        assertTrue(verifier.usedNonces(a2.nonce), "second nonce unmarked");
        assertEq(verifier.attestedUntil(a1.user), a2.expiry, "attestedUntil did not adopt latest expiry");
    }

    /// @dev Spec lock-in: a failed consume must NOT burn the nonce. An
    ///      attacker (or buggy client) cannot DoS a victim by spraying
    ///      malformed / untrusted attestations carrying the victim's
    ///      nonce. After two reverts on the same nonce, a valid
    ///      attestation with that nonce still goes through.
    function test_FailedAttestationDoesNotMarkNonce() public {
        IdentityVerifier.Attestation memory a = _defaultAttestation();

        // (1) Untrusted signer revert.
        uint256 strangerKey = uint256(keccak256("not-a-signer"));
        address strangerSigner = vm.addr(strangerKey);
        bytes memory sigUntrusted = _signWithKey(a, strangerKey);
        vm.expectRevert(abi.encodeWithSelector(IdentityVerifier.UntrustedSigner.selector, strangerSigner));
        verifier.consumeAttestation(a, sigUntrusted);
        assertFalse(verifier.usedNonces(a.nonce), "untrusted revert marked nonce");

        // (2) Malformed signature revert.
        bytes memory sigBad = bytes("garbage");
        vm.expectRevert(IdentityVerifier.SignatureInvalid.selector);
        verifier.consumeAttestation(a, sigBad);
        assertFalse(verifier.usedNonces(a.nonce), "malformed-sig revert marked nonce");

        // (3) Expired revert. Snapshot/restore so the warp does not
        //     leak into the valid retry below.
        uint256 snap = vm.snapshotState();
        bytes memory sigExpired = _signWithKey(a, SIGNER_KEY);
        vm.warp(uint256(a.expiry) + 1);
        vm.expectRevert(abi.encodeWithSelector(IdentityVerifier.AttestationExpired.selector, a.expiry));
        verifier.consumeAttestation(a, sigExpired);
        assertFalse(verifier.usedNonces(a.nonce), "expired revert marked nonce");
        vm.revertToState(snap);

        // (4) Valid retry with the same nonce succeeds.
        bytes memory sigValid = _signWithKey(a, SIGNER_KEY);
        verifier.consumeAttestation(a, sigValid);
        assertTrue(verifier.usedNonces(a.nonce), "valid retry did not mark nonce");
    }

    // -------- Happy-path matrix (todo-35) --------

    /// @dev OZ v5.6.0 limitation pin: the `bytes` overload of
    ///      `ECDSA.tryRecover` accepts only 65-byte signatures and
    ///      surfaces `InvalidSignatureLength` for 64-byte EIP-2098
    ///      compact form — which `consumeAttestation` translates to
    ///      `SignatureInvalid`. The verifier-service signs the
    ///      65-byte form (ethers v6 `signTypedData` default), so this
    ///      is the contracted boundary. Should a future ADR add
    ///      compact support via the `(bytes32 r, bytes32 vs)`
    ///      overload, this test flips from a reject pin to a happy
    ///      path.
    function test_CompactSignatureRejectedUnderOZv5BytesOverload() public {
        IdentityVerifier.Attestation memory a = _defaultAttestation();
        bytes memory sig = _signCompact(a, SIGNER_KEY);
        assertEq(sig.length, 64, "compact sig must be 64 bytes");

        vm.expectRevert(IdentityVerifier.SignatureInvalid.selector);
        verifier.consumeAttestation(a, sig);

        assertFalse(verifier.usedNonces(a.nonce), "rejected compact-sig must not mark nonce");
    }

    /// @dev ADR-003 strict-less expiry decision: `a.expiry < block.timestamp`
    ///      reverts, equality passes. `test_ConsumeRevertsOnExpired`
    ///      pins `expiry + 1` as the reject boundary; this fixture
    ///      pins `expiry == block.timestamp` as the accept boundary.
    ///      A future relaxed `<=` regression would surface here.
    function test_ConsumeAttestationAtExpiryBoundary() public {
        IdentityVerifier.Attestation memory a = _defaultAttestation();
        bytes memory sig = _signWithKey(a, SIGNER_KEY);
        vm.warp(uint256(a.expiry));

        verifier.consumeAttestation(a, sig);

        assertTrue(verifier.usedNonces(a.nonce), "boundary-expiry consume did not mark nonce");
        assertEq(verifier.attestedUntil(a.user), a.expiry, "boundary-expiry consume did not write attestedUntil");
    }

    /// @dev Multi-user isolation: distinct users consuming distinct
    ///      attestations each land in their own `attestedUntil` slot,
    ///      with no cross-pollution. Complements
    ///      `test_DifferentNonceTwiceSucceeds` (same user, two
    ///      nonces) on the orthogonal axis.
    function test_ConsumeAttestationMultipleUsers() public {
        address[3] memory users = [makeAddr("user-1"), makeAddr("user-2"), makeAddr("user-3")];
        bytes32[3] memory nonces = [keccak256("nonce-multi-1"), keccak256("nonce-multi-2"), keccak256("nonce-multi-3")];
        uint64 expiry = uint64(block.timestamp + 1 hours);

        for (uint256 i = 0; i < 3; ++i) {
            IdentityVerifier.Attestation memory a = IdentityVerifier.Attestation({
                user: users[i], credentialHash: keccak256(abi.encode("cred", i)), expiry: expiry, nonce: nonces[i]
            });
            bytes memory sig = _signWithKey(a, SIGNER_KEY);
            verifier.consumeAttestation(a, sig);
        }

        for (uint256 i = 0; i < 3; ++i) {
            assertTrue(verifier.usedNonces(nonces[i]), "nonce not marked for user");
            assertEq(verifier.attestedUntil(users[i]), expiry, "attestedUntil not isolated per user");
        }
    }

    // -------- Role management security (todo-33) --------

    function test_NonAdminCannotGrantSignerRole() public {
        address newSigner = makeAddr("new-signer");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, DEFAULT_ADMIN_ROLE
            )
        );
        vm.prank(stranger);
        verifier.grantRole(SIGNER_ROLE, newSigner);
    }

    function test_NonAdminCannotRevokeSignerRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, DEFAULT_ADMIN_ROLE
            )
        );
        vm.prank(stranger);
        verifier.revokeRole(SIGNER_ROLE, signer);

        // Negative consequence: the existing signer keeps the role.
        assertTrue(verifier.hasRole(SIGNER_ROLE, signer), "unauthorized revoke leaked through");
    }

    /// @dev Renounce-bricks-management pitfall at the DEFAULT_ADMIN level.
    ///      A sole admin renouncing DEFAULT_ADMIN_ROLE strands every future
    ///      role grant or revoke. This is the broader-blast-radius cousin
    ///      of `WhitelistTest.test_RenounceRoleBricksRegistryWhenSoleAdmin`
    ///      — production deployments are expected to seat
    ///      DEFAULT_ADMIN_ROLE in a multisig.
    function test_RenounceDefaultAdminBricksRoleManagement() public {
        vm.prank(admin);
        verifier.renounceRole(DEFAULT_ADMIN_ROLE, admin);
        assertFalse(verifier.hasRole(DEFAULT_ADMIN_ROLE, admin), "renounce did not clear admin role");

        address newSigner = makeAddr("post-renounce-signer");

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, DEFAULT_ADMIN_ROLE)
        );
        vm.prank(admin);
        verifier.grantRole(SIGNER_ROLE, newSigner);
    }

    /// @dev Operational runbook: signer rotation after an
    ///      off-chain verifier-service key compromise. Phase 7
    ///      docs reference this test as the live spec. Steps
    ///      mirror what the multisig will execute on-chain in a
    ///      single Safe batch tx during a real incident.
    function test_SignerRotationFlow() public {
        IdentityVerifier.Attestation memory a = _defaultAttestation();
        bytes memory sigV1 = _signWithKey(a, SIGNER_KEY);

        uint256 signerKeyV2 = uint256(keccak256("identity-verifier-signer-key-v2"));
        address signerV2 = vm.addr(signerKeyV2);

        // Multisig flow: revoke compromised key, grant fresh key.
        vm.startPrank(admin);
        verifier.revokeRole(SIGNER_ROLE, signer);
        verifier.grantRole(SIGNER_ROLE, signerV2);
        vm.stopPrank();

        assertFalse(verifier.hasRole(SIGNER_ROLE, signer), "old signer still trusted");
        assertTrue(verifier.hasRole(SIGNER_ROLE, signerV2), "new signer not trusted");

        // Old key's signature now reverts as UntrustedSigner — the
        // compromised key cannot mint fresh attestations even though
        // any attestation it signed before the revoke remains
        // technically valid until expiry (compromise window).
        vm.expectRevert(abi.encodeWithSelector(IdentityVerifier.UntrustedSigner.selector, signer));
        verifier.consumeAttestation(a, sigV1);

        // Fresh signature from the rotated key succeeds.
        bytes memory sigV2 = _signWithKey(a, signerKeyV2);
        verifier.consumeAttestation(a, sigV2);

        assertTrue(verifier.usedNonces(a.nonce), "rotated-key consume did not mark nonce");
        assertEq(verifier.attestedUntil(a.user), a.expiry, "rotated-key consume did not write attestedUntil");
    }

    // -------- Revert matrix: signature tampering + malleability (todo-36) --------

    /// @dev secp256k1 group order, used to construct the upper-half-order
    ///      malleable counterpart of a canonical signature.
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    /// @dev Message-binding at the consume level: a signature over one
    ///      attestation must not validate a different attestation. The
    ///      signer authorizes a credential for `alice`, but the caller
    ///      submits a copy with a swapped `credentialHash`. The on-chain
    ///      digest changes, recovery yields an unrelated address, and the
    ///      role check rejects it. `test_HashAttestationChangesPerField`
    ///      proves the digest is field-sensitive; this proves the consume
    ///      path actually rejects the mismatch (and never marks the nonce).
    function test_WrongCredentialTypeMismatch() public {
        IdentityVerifier.Attestation memory signed = _defaultAttestation();
        bytes memory sig = _signWithKey(signed, SIGNER_KEY);

        IdentityVerifier.Attestation memory tampered = signed;
        tampered.credentialHash = keccak256("credential-identifier:forged-type");

        bytes32 digest =
            verifier.hashAttestation(tampered.user, tampered.credentialHash, tampered.expiry, tampered.nonce);
        address recovered = ECDSA.recover(digest, sig);
        assertTrue(recovered != signer, "tampered digest must not recover the trusted signer");

        vm.expectRevert(abi.encodeWithSelector(IdentityVerifier.UntrustedSigner.selector, recovered));
        verifier.consumeAttestation(tampered, sig);

        assertFalse(verifier.usedNonces(tampered.nonce), "rejected tampered attestation must not mark nonce");
    }

    /// @dev The attack with teeth: an attacker who captures a valid
    ///      signature tries to extend the attestation's validity window
    ///      by inflating `expiry` before submitting. The digest binds
    ///      `expiry`, so the recovered signer no longer matches and the
    ///      role check rejects it. Pairs with `test_WrongCredentialTypeMismatch`
    ///      on the validity axis rather than the identity axis.
    function test_TamperedExpiryReverts() public {
        IdentityVerifier.Attestation memory signed = _defaultAttestation();
        bytes memory sig = _signWithKey(signed, SIGNER_KEY);

        IdentityVerifier.Attestation memory tampered = signed;
        tampered.expiry = signed.expiry + 365 days; // attacker inflates the window

        bytes32 digest =
            verifier.hashAttestation(tampered.user, tampered.credentialHash, tampered.expiry, tampered.nonce);
        address recovered = ECDSA.recover(digest, sig);
        assertTrue(recovered != signer, "tampered-expiry digest must not recover the trusted signer");

        vm.expectRevert(abi.encodeWithSelector(IdentityVerifier.UntrustedSigner.selector, recovered));
        verifier.consumeAttestation(tampered, sig);

        assertFalse(verifier.usedNonces(tampered.nonce), "rejected tampered-expiry attestation must not mark nonce");
    }

    /// @dev EIP-2 malleability defense. `vm.sign` returns a canonical
    ///      low-`s` signature; its upper-half-order counterpart
    ///      (`s' = N - s`, `v` flipped) recovers the same address via raw
    ///      `ecrecover` but is rejected by `ECDSA.tryRecover` with
    ///      `InvalidSignatureS`, which `consumeAttestation` surfaces as
    ///      `SignatureInvalid`. Code proof for the NatSpec claim that the
    ///      contract rejects high-`s` malleability.
    function test_HighSMalleabilityRejected() public {
        IdentityVerifier.Attestation memory a = _defaultAttestation();
        bytes32 digest = verifier.hashAttestation(a.user, a.credentialHash, a.expiry, a.nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, digest);

        bytes32 sHigh = bytes32(SECP256K1_N - uint256(s));
        uint8 vFlipped = v == 27 ? 28 : 27;
        bytes memory malleable = abi.encodePacked(r, sHigh, vFlipped);

        vm.expectRevert(IdentityVerifier.SignatureInvalid.selector);
        verifier.consumeAttestation(a, malleable);

        assertFalse(verifier.usedNonces(a.nonce), "malleable signature must not mark nonce");
    }

    /// @dev Recovery-failure path, distinct from the length-failure path
    ///      (`test_ConsumeRevertsOnMalformedSignature`). A 65-byte all-zero
    ///      signature passes the length gate, but `ecrecover(digest, 0, 0, 0)`
    ///      returns the zero address, so `ECDSA.tryRecover` reports
    ///      `InvalidSignature` and `consumeAttestation` reverts with
    ///      `SignatureInvalid` — before the role check runs. This pins the
    ///      short-circuit that prevents an `address(0)` recovery from ever
    ///      reaching `hasRole(SIGNER_ROLE, address(0))`.
    function test_ZeroFilledSignatureReverts() public {
        IdentityVerifier.Attestation memory a = _defaultAttestation();
        bytes memory zeroSig = new bytes(65); // length-valid, recovers to address(0)

        vm.expectRevert(IdentityVerifier.SignatureInvalid.selector);
        verifier.consumeAttestation(a, zeroSig);

        assertFalse(verifier.usedNonces(a.nonce), "zero-filled signature must not mark nonce");
    }
}
