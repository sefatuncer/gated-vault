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
}
