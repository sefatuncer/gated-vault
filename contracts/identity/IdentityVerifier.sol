// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title  IdentityVerifier
/// @author Sefa Tunçer
/// @notice On-chain consumer of EIP-712 attestations issued by the
///         off-chain verifier-service. Pairs with `GatedVault._deposit`
///         in Phase 3 (todo-33+) to replace the v0.2.0 Whitelist gate
///         with a credential-bound attestation gate.
/// @dev    Skeleton (todo-30): inherits OZ `EIP712` for the domain
///         separator + `_hashTypedDataV4`, and `AccessControl` for
///         `SIGNER_ROLE` membership. The attestation consumption
///         flow (`consumeAttestation`, ECDSA recovery, nonce
///         marking) lands in todo-31 + todo-32; the type hash is
///         already pinned here because the EIP-712 domain string
///         and the message shape are frozen by ADR-003
///         (`research/notes/2026-05-11-adr-003-eip712-attestation.md`).
///         AccessControl supplies the role-management plumbing
///         (`grantRole`, `revokeRole`, `RoleGranted`,
///         `RoleRevoked`); we do not duplicate it with a parallel
///         `trustedVerifiers` mapping or a custom `VerifierTrusted`
///         event.
contract IdentityVerifier is EIP712, AccessControl {
    // -------- Types --------

    /// @notice Off-chain attestation produced by the verifier-service operator.
    /// @dev    Field order mirrors `ATTESTATION_TYPEHASH`. Re-ordering
    ///         fields without re-pinning the type hash would break the
    ///         off-chain signer; the CI gate (todo-34) catches drift.
    /// @param  user            Share recipient that the attestation gates.
    /// @param  credentialHash  `keccak256` of the off-chain credential identifier.
    /// @param  expiry          UNIX timestamp; rejected when `expiry < block.timestamp`.
    /// @param  nonce           Single-use; tracked in `usedNonces`.
    struct Attestation {
        address user;
        bytes32 credentialHash;
        uint64 expiry;
        bytes32 nonce;
    }

    // -------- Roles --------

    /// @notice Role authorized to sign attestations consumed by this contract.
    /// @dev    Granted by `DEFAULT_ADMIN_ROLE` post-deploy. The off-chain
    ///         verifier-service operational key sits here; admin
    ///         (multisig / timelock in production) can revoke + regrant
    ///         on key compromise without redeploying the contract.
    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER_ROLE");

    // -------- EIP-712 type pinning (ADR-003) --------

    /// @notice EIP-712 type hash for the Attestation struct.
    /// @dev    Pinned literal; a CI gate (todo-34) reconstructs the
    ///         type string from a test fixture and asserts equality
    ///         against this constant. Any whitespace drift between
    ///         the off-chain TypeScript signer and this constant
    ///         surfaces in CI, not in production. Public so the
    ///         off-chain side can read the canonical value from the
    ///         deployed contract instead of duplicating the string.
    bytes32 public constant ATTESTATION_TYPEHASH =
        keccak256("Attestation(address user,bytes32 credentialHash,uint64 expiry,bytes32 nonce)");

    // -------- Replay state --------

    /// @notice Records spent attestation nonces.
    /// @dev    Single-use enforcement layer of the four-layer replay
    ///         protection (chainId + verifyingContract + nonce +
    ///         expiry) defined in ADR-003. Once an attestation is
    ///         consumed in `consumeAttestation` (todo-32), the nonce
    ///         is marked here and the same signed message cannot be
    ///         re-submitted.
    mapping(bytes32 nonce => bool used) public usedNonces;

    /// @notice Latest attestation expiry recorded for a given user.
    /// @dev    Written by `consumeAttestation` (todo-32); read by the
    ///         downstream `GatedVault._deposit` hook (todo-33) to
    ///         gate the share recipient. Zero means "no valid
    ///         attestation recorded"; a non-zero value past
    ///         `block.timestamp` means the user is currently gated
    ///         through.
    mapping(address user => uint64 expiry) public attestedUntil;

    // -------- Errors --------

    /// @notice Reverts when the attestation has already passed its expiry.
    /// @param  expiry The expiry timestamp carried by the rejected attestation.
    error AttestationExpired(uint64 expiry);

    /// @notice Reverts when an attestation nonce has already been spent.
    /// @param  nonce The nonce that was found in `usedNonces`.
    error AttestationReplayed(bytes32 nonce);

    /// @notice Reverts when the recovered signer does not hold `SIGNER_ROLE`.
    /// @param  recovered The address `ECDSA.tryRecover` returned, or
    ///                   the zero address if recovery itself failed.
    error UntrustedSigner(address recovered);

    /// @notice Reverts when the signature cannot be parsed by
    ///         `ECDSA.tryRecover` (length, malleability, format).
    error SignatureInvalid();

    // -------- Events --------

    /// @notice Emitted whenever an attestation is successfully consumed.
    /// @dev    Off-chain indexers track this event to build the
    ///         attested-user set; `nonce` is indexed so anti-replay
    ///         monitors can detect the same nonce being submitted
    ///         twice (the second attempt reverts, but the event
    ///         indexing keeps the audit trail).
    /// @param  user    The address that the attestation gates through.
    /// @param  nonce   The single-use nonce carried by the attestation.
    /// @param  expiry  UNIX timestamp after which the attestation is stale.
    event AttestationConsumed(address indexed user, bytes32 indexed nonce, uint64 expiry);

    // -------- Constructor --------

    /// @notice Wire the EIP-712 domain and seed the role hierarchy.
    /// @dev    The domain string + version pin into the constructor
    ///         arguments of `EIP712`. `SIGNER_ROLE` is intentionally
    ///         NOT granted at deploy time — the verifier-service
    ///         operational EOA may not be known when the contract
    ///         ships, especially in a multi-chain deploy
    ///         (Phase 9). Admin assigns it post-deploy via
    ///         `grantRole(SIGNER_ROLE, ...)`.
    /// @param  admin Initial holder of `DEFAULT_ADMIN_ROLE`. Production
    ///               deployments are expected to set this to a
    ///               timelock / multisig.
    constructor(address admin) EIP712("GatedVault.IdentityVerifier", "1") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // -------- EIP-712 hashing helpers --------

    /// @notice Compute the EIP-712 digest for an Attestation message.
    /// @dev    Public view so off-chain TypeScript clients
    ///         (verifier-service) can read the canonical digest via
    ///         `eth_call` instead of re-implementing the struct
    ///         layout. The digest is
    ///         `keccak256("\x19\x01" || domainSeparator || structHash)`
    ///         where
    ///         `structHash = keccak256(abi.encode(ATTESTATION_TYPEHASH, ...))`.
    ///         The domain separator is fork-aware (OZ `EIP712` caches
    ///         per chainId + address and rebuilds when either
    ///         changes).
    /// @param  user            Share recipient gated by `GatedVault._deposit`.
    /// @param  credentialHash  `keccak256` of the off-chain credential identifier.
    /// @param  expiry          UNIX timestamp after which the attestation is stale.
    /// @param  nonce           Single-use; recorded in `usedNonces` on consume.
    /// @return digest          Typed-data digest to be ECDSA-signed off-chain.
    function hashAttestation(
        address user,
        bytes32 credentialHash,
        uint64 expiry,
        bytes32 nonce
    )
        external
        view
        returns (bytes32 digest)
    {
        bytes32 structHash = keccak256(abi.encode(ATTESTATION_TYPEHASH, user, credentialHash, expiry, nonce));
        digest = _hashTypedDataV4(structHash);
    }

    // -------- Attestation consumption --------

    /// @notice Verify and consume an EIP-712 Attestation signed by a
    ///         trusted SIGNER_ROLE holder.
    /// @dev    Check order is fail-fast (cheapest first, most
    ///         expensive last): `expiry` (no SLOAD) → `usedNonces`
    ///         (1 SLOAD) → `keccak + _hashTypedDataV4` (~600 gas) →
    ///         `ECDSA.tryRecover` (~3k, ecrecover precompile + length
    ///         parse) → `hasRole` (1 SLOAD). A stale or replayed
    ///         attestation never reaches the signature recovery path.
    ///         `tryRecover` rejects high-`s` malleability and accepts
    ///         both 65-byte standard and 64-byte EIP-2098 compact
    ///         signatures; a malformed signature surfaces as
    ///         `SignatureInvalid` rather than `UntrustedSigner` so the
    ///         failure class is unambiguous downstream. State writes
    ///         (`usedNonces`, `attestedUntil`) happen before the
    ///         event emit; the function has no external calls, so
    ///         ReentrancyGuard is not required.
    /// @param  a   Calldata Attestation; field order must match
    ///             `ATTESTATION_TYPEHASH`.
    /// @param  sig 65-byte (r||s||v) or 64-byte EIP-2098 compact
    ///             signature over the typed-data digest.
    function consumeAttestation(Attestation calldata a, bytes calldata sig) external {
        if (a.expiry < block.timestamp) revert AttestationExpired(a.expiry);
        if (usedNonces[a.nonce]) revert AttestationReplayed(a.nonce);

        bytes32 structHash = keccak256(abi.encode(ATTESTATION_TYPEHASH, a.user, a.credentialHash, a.expiry, a.nonce));
        bytes32 digest = _hashTypedDataV4(structHash);

        // slither-disable-next-line unused-return
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, sig);
        if (err != ECDSA.RecoverError.NoError) revert SignatureInvalid();
        if (!hasRole(SIGNER_ROLE, signer)) revert UntrustedSigner(signer);

        usedNonces[a.nonce] = true;
        attestedUntil[a.user] = a.expiry;

        emit AttestationConsumed(a.user, a.nonce, a.expiry);
    }
}
