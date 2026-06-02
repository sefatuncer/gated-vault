import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import {
  buildDidDocument,
  didToWellKnownUrl,
  generateEd25519KeyPair,
  ISSUER_DID,
  keyPairFromSeed,
  VERIFIER_DID,
  type Ed25519PublicJwk,
} from '../../src/identity/dids.js';

// Documented test seed for the committed verifier DID document. Test-only:
// the corresponding public key is published in `.well-known/did.json`, so a
// real deployment must NOT reuse this seed.
const VERIFIER_TEST_SEED = Buffer.from('gated-vault-verifier-did-seed-01', 'utf8');

describe('keyPairFromSeed', () => {
  it('is deterministic for a given seed', () => {
    const a = keyPairFromSeed(VERIFIER_TEST_SEED);
    const b = keyPairFromSeed(VERIFIER_TEST_SEED);
    expect(a.publicJwk).toEqual(b.publicJwk);
    expect(a.publicJwk.kty).toBe('OKP');
    expect(a.publicJwk.crv).toBe('Ed25519');
  });

  it('rejects a seed that is not 32 bytes', () => {
    expect(() => keyPairFromSeed(Buffer.alloc(31))).toThrow(/32 bytes/);
    expect(() => keyPairFromSeed(Buffer.alloc(33))).toThrow(/32 bytes/);
  });

  it('derives distinct keys for distinct seeds', () => {
    const a = keyPairFromSeed(Buffer.alloc(32, 1));
    const b = keyPairFromSeed(Buffer.alloc(32, 2));
    expect(a.publicJwk.x).not.toBe(b.publicJwk.x);
  });
});

describe('generateEd25519KeyPair', () => {
  it('produces a fresh OKP/Ed25519 key each call', () => {
    const a = generateEd25519KeyPair();
    const b = generateEd25519KeyPair();
    expect(a.publicJwk.kty).toBe('OKP');
    expect(a.publicJwk.crv).toBe('Ed25519');
    expect(a.publicJwk.x).not.toBe(b.publicJwk.x);
  });
});

describe('didToWellKnownUrl', () => {
  it('maps a bare domain to the well-known path', () => {
    expect(didToWellKnownUrl('did:web:example.com')).toBe(
      'https://example.com/.well-known/did.json',
    );
  });

  it('maps a pathful did to the nested path (no well-known)', () => {
    expect(didToWellKnownUrl('did:web:example.com:org:alice')).toBe(
      'https://example.com/org/alice/did.json',
    );
  });

  it('decodes a percent-encoded port in the host segment', () => {
    expect(didToWellKnownUrl('did:web:localhost%3A3000')).toBe(
      'https://localhost:3000/.well-known/did.json',
    );
  });

  it('rejects a non-did:web identifier', () => {
    expect(() => didToWellKnownUrl('did:key:z6Mk')).toThrow(/not a did:web/);
  });

  it('rejects a malformed did with an empty segment', () => {
    expect(() => didToWellKnownUrl('did:web:example.com::alice')).toThrow(/malformed/);
  });
});

describe('buildDidDocument', () => {
  const publicKeyJwk: Ed25519PublicJwk = keyPairFromSeed(Buffer.alloc(32, 9)).publicJwk;

  it('produces a W3C DID Core document with one JsonWebKey2020 method', () => {
    const doc = buildDidDocument({ did: ISSUER_DID, publicKeyJwk });
    const vmId = `${ISSUER_DID}#key-1`;

    expect(doc.id).toBe(ISSUER_DID);
    expect(doc['@context']).toContain('https://www.w3.org/ns/did/v1');
    expect(doc.verificationMethod).toHaveLength(1);
    expect(doc.verificationMethod[0]).toMatchObject({
      id: vmId,
      type: 'JsonWebKey2020',
      controller: ISSUER_DID,
      publicKeyJwk,
    });
    expect(doc.assertionMethod).toEqual([vmId]);
    expect(doc.authentication).toEqual([vmId]);
  });

  it('honors a custom key id', () => {
    const doc = buildDidDocument({ did: ISSUER_DID, publicKeyJwk, keyId: 'signing' });
    expect(doc.verificationMethod[0].id).toBe(`${ISSUER_DID}#signing`);
  });
});

describe('committed verifier DID document', () => {
  it('matches the document built from the test seed (drift guard)', () => {
    const committed = JSON.parse(
      readFileSync(new URL('../../.well-known/did.json', import.meta.url), 'utf8'),
    );
    const { publicJwk } = keyPairFromSeed(VERIFIER_TEST_SEED);
    const expected = buildDidDocument({ did: VERIFIER_DID, publicKeyJwk: publicJwk });
    expect(committed).toEqual(expected);
  });
});
