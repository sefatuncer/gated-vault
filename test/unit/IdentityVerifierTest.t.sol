// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
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

    function setUp() public {
        verifier = new IdentityVerifier(admin);
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
        address signer = makeAddr("signer");

        vm.prank(admin);
        verifier.grantRole(SIGNER_ROLE, signer);

        assertTrue(verifier.hasRole(SIGNER_ROLE, signer), "grant did not stick");
    }

    function test_AdminCanRevokeSignerRole() public {
        address signer = makeAddr("signer");

        vm.startPrank(admin);
        verifier.grantRole(SIGNER_ROLE, signer);
        verifier.revokeRole(SIGNER_ROLE, signer);
        vm.stopPrank();

        assertFalse(verifier.hasRole(SIGNER_ROLE, signer), "revoke did not stick");
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
}
