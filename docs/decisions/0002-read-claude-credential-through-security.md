---
summary: The Claude token is read by running /usr/bin/security, never by a direct Keychain call, so no dialog ever appears; credentials are never written.
read_when: Touching KeychainTokenProvider, CodexTokenProvider, or any code that could read or write ~/.claude, ~/.codex or the Keychain.
---

# 0002 — Read the Claude credential through `/usr/bin/security`, never with a dialog

## Decision

Kvotar reads the `Claude Code-credentials` Keychain item by running
`/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`. It never calls
`SecItemCopyMatching` (or any `SecItem*` function) on that item, never shows an authorization dialog,
and never writes, updates or deletes a credential. `~/.codex/auth.json` is read as a plain file and
never written.

## Why

Claude Code creates the item with `/usr/bin/security`, so that tool is the one trusted app on the
item's access rule ("confirm before allowing access"). A read from Kvotar's own process is not the
trusted app: it either shows a password dialog or, with dialogs disabled, fails with
`errSecUserCanceled` (-128), however Kvotar is signed. Running the trusted tool makes the read silent.

A dialog asking for a Keychain password, from a menu-bar app, trains people to type their password
into prompts they did not expect. Kvotar never shows one.

## Accepted behavior

- Exit code 0: decode `claudeAiOauth.accessToken`, `subscriptionType`, `expiresAt`. The refresh token
  is in the same output and is never decoded or kept.
- Exit code 44 (item not found): Claude is not set up on this Mac.
- Any other exit code, or `security` failing to start: "credential unreadable". This is never shown
  as "not set up", because the item may exist.
- The credential is never logged.

## Non-goals

- Supporting a Claude Code version that stores the token elsewhere, by any means that prompts.
- Reading browser cookies or claude.ai session keys. Never.

## Required tests

- `KeychainTokenProviderTests.testSuccessfulReadDecodesTheOAuthBlock`
- `KeychainTokenProviderTests.testItemNotFoundReturnsNil`
- `KeychainTokenProviderTests.testDeniedReadThrowsCredentialUnreadable`
- `KeychainTokenProviderTests.testUnlaunchableSecurityToolThrowsCredentialUnreadable`
- `CodexAuthFileReaderTests` (absent, unreadable, readable)
- The argument-shape, read-only and write-destination checks in [safety-checks.md](../safety-checks.md).

Tests use a scripted fake `security`; they never run the real tool.

## Tradeoffs

- This relies on Claude Code keeping `/usr/bin/security` as the trusted app. If a Claude Code release
  changes that, the read stops being silent, and Kvotar must stop reading rather than prompt.
- Starting a process on every poll costs a little; it is negligible at the poll interval.

## Status

Accepted.
