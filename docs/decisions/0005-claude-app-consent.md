---
summary: The Claude app is a second quota source only after an explicit connection, with silent background reads and a verified account-and-organization binding.
read_when: Changing Claude app detection, Safe Storage access, source selection, connection actions or identity binding.
---

# 0005 — Connect the Claude app only with the user's consent

## Decision

Issue [#26](https://github.com/vladamarkov/kvotar/issues/26) adds the Claude app as a second quota
source. It amends [0002](0002-read-claude-credential-through-security.md) only for this source:
Connect/Retry may read `Claude Safe Storage` with interaction allowed. Every background read
suppresses interaction. The existing Claude Code `security` subprocess is unchanged.

## Why

Desktop-only users have no `Claude Code-credentials` item. The maintainer's Claude app 2.42304.0
kept an encrypted OAuth cache whose selected access token answered the existing quota endpoint.
Its key required a user-authorized macOS prompt. This is a compatibility observation, not a
promise about every app version or chat-only sign-in.

## Accepted behavior

- Connect requires the CLI reader's exit 44, the installed app, and a cache key-name marker in
  its config. Errors and decode failures are not absence. The click rechecks the gate.
- A shared lock serializes interactive and suppressed reads. Background reads save the process
  interaction flag, disable it, read, and restore it; failure to get or disable means no read.
  LAContext/UIFail are additional protection, not the guarantee for file-based Keychain ACLs
  (FB16959400). A failed restoration returns unavailable. Denial is remembered until a click.
- The derived decryption key stays only in process memory. A relaunch or decryption failure
  requires another silent read; that is when a revoked grant is observed. Only macOS stores an
  Always Allow grant. Signing identity, item replacement or grant changes can invalidate it.
- Typed decoding omits refresh credentials. Selection is account-tagged, production-host/client,
  profile-scoped and unexpired; V2 shadows V1, including deletions. Multiple organizations stop
  selection. Client/scope suitability ranks before expiry. A changing config invalidates the read.
- Profile proof binds account and organization before first usage and on candidate changes.
  Existing CLI credentials win only after same-identity verification; expired CLI credentials
  never trigger a new Desktop connection. Changed Desktop identity stops the source until an
  explicit Connect again. The durable binding is a digest, never a token or a key.
- An explicit rebind records one identity-free `account_rebound` history event and clears
  transient forecast/account caches. Existing history is retained with a marker; it is not
  partitioned into separate per-account tables.

## Non-goals

No cookies, session keys, credential or ACL writes, token renewal, own login, multiple organizations,
Claude app local attribution, or connection as a remedy for expired Claude Code credentials.

## Required tests

`ClaudeAppPresenceTests`, `ClaudeAppSourceTests`, `ClaudeAppSuppressionTests`,
`ClaudeAppDisplayTests`, and the existing `KeychainTokenProviderTests` / `NoRefreshNetworkSeamTests`.
The maintainer alone checks actual macOS dialogs with `make run`, and Always Allow persistence with
signed builds. Fixtures establish control flow, not runtime ACL behavior.

## Tradeoffs

Rule 4 gains one explicit-click exception. Rules 1–3 remain unchanged. The process-wide deprecated
switch is necessary for the login Keychain; its lock covers only the actual read. Cached keys mean
revocation is observed on the next key read, not on every poll. Reverting returns Desktop-only users
to the previous not-detected card.

## Status

Accepted, 2026-10-17, issue #26.
