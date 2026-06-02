import { describe, expect, it } from 'vitest';
import { SERVICE_NAME, main } from '../src/index.js';

describe('verifier-service skeleton', () => {
  it('exposes a stable service name', () => {
    expect(SERVICE_NAME).toBe('gated-vault-verifier');
  });

  it('main runs without throwing', () => {
    expect(() => main()).not.toThrow();
  });
});
