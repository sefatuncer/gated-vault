import {
  createPrivateKey,
  createPublicKey,
  generateKeyPairSync,
  type KeyObject,
} from 'node:crypto';

/**
 * did:web identity primitives for the issuer and verifier (todo-42).
 *
 * Keys are Ed25519 and verification methods are `JsonWebKey2020` with a
 * `publicKeyJwk`, which lines up with the JWT VC / SD-JWT VC path
 * (ADR-002) and avoids multibase/multicodec encoding. These SSI-layer
 * keys are distinct from the on-chain EIP-712 signer (a secp256k1 key
 * that holds `SIGNER_ROLE`, wired in todo-47): different algorithm,
 * different purpose, never shared.
 *
 * did:web over did:indy / did:key is ADR-004.
 */

/** JWK public key, OKP/Ed25519 shape. */
export interface Ed25519PublicJwk {
  kty: 'OKP';
  crv: 'Ed25519';
  x: string;
}

/** A W3C DID Core verification method (JsonWebKey2020 variant). */
export interface VerificationMethod {
  id: string;
  type: 'JsonWebKey2020';
  controller: string;
  publicKeyJwk: Ed25519PublicJwk;
}

/** A minimal W3C DID Core document for a did:web identity. */
export interface DidDocument {
  '@context': string[];
  id: string;
  verificationMethod: VerificationMethod[];
  assertionMethod: string[];
  authentication: string[];
}

/** Mock issuer DID. `.example` is RFC 2606 reserved; production swaps a real domain. */
export const ISSUER_DID = 'did:web:gated-vault-issuer.example';

/** Mock verifier DID served at this service's `/.well-known/did.json`. */
export const VERIFIER_DID = 'did:web:gated-vault-verifier.example';

const DID_CONTEXT = [
  'https://www.w3.org/ns/did/v1',
  'https://w3id.org/security/suites/jws-2020/v1',
];

// PKCS8 DER prefix for a raw 32-byte Ed25519 private seed. Concatenated with
// the seed it forms a key Node's `crypto` can import, which lets us derive a
// deterministic keypair from a seed (Node's generateKeyPairSync takes no seed).
const ED25519_PKCS8_PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex');

function toPublicJwk(publicKey: KeyObject): Ed25519PublicJwk {
  const jwk = publicKey.export({ format: 'jwk' }) as { kty?: string; crv?: string; x?: string };
  if (jwk.kty !== 'OKP' || jwk.crv !== 'Ed25519' || typeof jwk.x !== 'string') {
    throw new Error('expected an Ed25519 (OKP) public key');
  }
  return { kty: 'OKP', crv: 'Ed25519', x: jwk.x };
}

/** Generate a fresh random Ed25519 keypair. */
export function generateEd25519KeyPair(): { publicJwk: Ed25519PublicJwk; privateKey: KeyObject } {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  return { publicJwk: toPublicJwk(publicKey), privateKey };
}

/**
 * Derive a deterministic Ed25519 keypair from a 32-byte seed. Used for
 * reproducible test identities and the committed static DID document; a real
 * deployment derives from a securely generated key kept out of the repo.
 */
export function keyPairFromSeed(seed: Buffer): {
  publicJwk: Ed25519PublicJwk;
  privateKey: KeyObject;
} {
  if (seed.length !== 32) {
    throw new Error(`Ed25519 seed must be 32 bytes, got ${seed.length}`);
  }
  const der = Buffer.concat([ED25519_PKCS8_PREFIX, seed]);
  const privateKey = createPrivateKey({ key: der, format: 'der', type: 'pkcs8' });
  const publicKey = createPublicKey(privateKey);
  return { publicJwk: toPublicJwk(publicKey), privateKey };
}

/**
 * Resolve a did:web identifier to the URL its DID document is served from,
 * per the did:web method spec.
 *
 * - `did:web:example.com` -> `https://example.com/.well-known/did.json`
 * - `did:web:example.com:org:alice` -> `https://example.com/org/alice/did.json`
 * - the host segment may carry a percent-encoded port (`localhost%3A3000`).
 */
export function didToWellKnownUrl(did: string): string {
  const prefix = 'did:web:';
  if (!did.startsWith(prefix)) {
    throw new Error(`not a did:web identifier: ${did}`);
  }
  const segments = did.slice(prefix.length).split(':');
  if (segments.some((s) => s.length === 0)) {
    throw new Error(`malformed did:web identifier: ${did}`);
  }
  const host = decodeURIComponent(segments[0]);
  if (segments.length === 1) {
    return `https://${host}/.well-known/did.json`;
  }
  const path = segments.slice(1).map(decodeURIComponent).join('/');
  return `https://${host}/${path}/did.json`;
}

/**
 * Build a W3C DID Core document for a did:web identity. The single
 * verification method is referenced by both `assertionMethod` (issuer signs
 * credentials) and `authentication` (holder/verifier proves control).
 */
export function buildDidDocument(params: {
  did: string;
  publicKeyJwk: Ed25519PublicJwk;
  keyId?: string;
}): DidDocument {
  const keyId = params.keyId ?? 'key-1';
  const vmId = `${params.did}#${keyId}`;
  return {
    '@context': [...DID_CONTEXT],
    id: params.did,
    verificationMethod: [
      {
        id: vmId,
        type: 'JsonWebKey2020',
        controller: params.did,
        publicKeyJwk: params.publicKeyJwk,
      },
    ],
    assertionMethod: [vmId],
    authentication: [vmId],
  };
}
