# Multi-machine secrets: independent review brief

Status: **independent review pending**. The version 2 protocol remains
experimental. Repository tests, sanitizer runs and this brief are preparation
for review; they are not an independent assessment or cryptographic sign-off.

## Scope and trust boundaries

Review a named source commit and the exact source hashes from
`tests/release/security_evidence.rb`. Cover both successful operations and
failure recovery across the encrypted store, machine-local key backend,
plaintext session cache, generated shell loader, backups and synchronization.
The wire/storage contract is in [config-reference.md](config-reference.md#secrets).

| Boundary | Intended property | Relevant source |
|---|---|---|
| Constants → ciphertext | Value authentication, name binding, nonce generation and run-only handling | `src/secrets_store.odin` |
| Backend → process | Private master key and identity storage; per-data-dir separation | `src/keystore.odin` |
| Synced header → cached key | Explicit first adoption; authenticated recipient and rotation state | `src/secrets_recipients.odin` |
| Recipient encoding → wrapped key | Correct X25519, HKDF and AEAD composition; canonical encodings | `src/age.odin` |
| Encrypted store → shell | Private cache directories/files, invalidation, quoting and limited exposure | `src/secrets_store.odin`, `src/init_generator.odin`, `src/shell.odin` |
| Write/restore → durable state | Locking, backups, atomic replacement and interrupted-operation recovery | `src/atomic_io.odin`, `src/backup.odin` |

Version 2 uses age-formatted X25519 identities and age's recipient derivation,
but wraps a 32-byte wayu data key inside wayu's JSON container. It is not a
standard age file. Compare with the [age specification](https://c2sp.org/age@v1.1.0).
Recovery uses Argon2id with the fixed parameters documented in the config
reference; compare the choice and implementation with [RFC 9106](https://www.rfc-editor.org/rfc/rfc9106.html).

## Questions for the assessor

- Does deterministic recipient-stanza derivation provide the intended
  authentication without unsafe key/nonce reuse or cross-protocol interactions?
- Do adoption, rotation proofs and machine-local recipient/removal history
  enforce the stated trust model through offline periods and concurrent writes?
- Are recovery identity encryption, parameter validation, secret wiping and
  error handling appropriate for the supported platforms and Odin runtime?
- Are v1 → v2 migration, rekey, backup restore and crashes recoverable without
  accepting an unverified key or losing the last decryptable copy?
- Does every generated shell maintain the same private-cache and run-only
  semantics, including logout, shared runtime dirs and sync replacement?

## Known limits to assess, not stronger claims

- A compromised logged-in user or process with its keys can read secrets.
  The file backend does not protect against reading the whole home directory.
- Session caches are plaintext, owner-only files until invalidated or locked.
  A sync replacement preserving an older mtime can leave the old cache in use.
- Replays of individual values under the same data key are not detected.
  Trust before first adoption cannot come from the synced file alone.
- Removed machines may retain old plaintext and keys. A machine that has not
  observed removal can accept a competing signed rotation from an old holder.
  Upstream credentials and a known recovery passphrase need separate rotation.

These limits are already described in the configuration reference. Review
whether their visibility and operational recovery are adequate.

## Evidence and completion criteria

Run `ruby tests/release/security_evidence.rb` from a built checkout. It records
source hashes and runs existing unit and secrets integration tests in temporary
homes. It uses fixture secrets and file/test backends, not production keys.
The unit suite includes external X25519 vectors, parser, pinning, recovery and
rotation checks. CI separately runs AddressSanitizer integration tests on Linux.
CI retains a source-only manifest alongside the unit, integration and TUI
outputs in `test-evidence-<runner>` artifacts. The manifest labels itself as
source metadata; the surrounding job's success determines the test result.

Before removing experimental status, retain a review report with assessor and
date, commit/hashes, reviewed platforms and backends, exclusions, findings and
severity, remediation commits, and assessor verification of remediation. Track
unresolved findings explicitly. A maintainer must approve promotion after that
evidence exists. Report privately through [SECURITY.md](../SECURITY.md).
