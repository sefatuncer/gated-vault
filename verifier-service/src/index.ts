import 'reflect-metadata';
import { pathToFileURL } from 'node:url';

/**
 * verifier-service entrypoint (skeleton, todo-41).
 *
 * The off-chain side of gated-vault: it will accept an OpenID4VP
 * presentation from a holder wallet, validate the Verifiable Credential,
 * and sign an EIP-712 attestation that the on-chain IdentityVerifier
 * consumes inside the deposit gate.
 *
 * This file is intentionally framework-free for now. The Credo TS agent
 * setup lands in todo-42 (did:web) and todo-43 (issuer/verifier), the
 * Fastify OpenID4VP endpoints in todo-44, and the EIP-712 signer in
 * todo-47. `reflect-metadata` is imported here because Credo TS relies on
 * decorator metadata (tsyringe dependency injection, class-transformer);
 * the import must run before any Credo module is loaded.
 */

export const SERVICE_NAME = 'gated-vault-verifier';

export function main(): void {
  // Agent + server wiring is added in later todos.
  console.log(`${SERVICE_NAME} skeleton ready`);
}

// Run only when executed directly (`node dist/index.js`, `tsx src/index.ts`),
// not when imported by a test or another module.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}
