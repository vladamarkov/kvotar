---
summary: Kvotar never refreshes a Claude or Codex token and never makes another program refresh one; an expired Claude token means no request.
read_when: Touching credential reading, the expired-token path, 401/403 handling, or anything that launches the claude or codex programs.
---

# 0001 — Never refresh a token, and never trigger one

## Decision

Kvotar reads the current access token and nothing else. It never calls a token endpoint, never sends a
refresh token, and never runs another program in a way that could make it refresh (for example
`claude doctor` on an expired sign-in). When the Claude token has expired, Kvotar sends no request and
shows that the sign-in expired.

## Why

A refresh token works once. Claude Code and Kvotar would share one, so a refresh by either can leave
the other holding a token the provider has already consumed. When Claude Code then replays it, the
provider answers `invalid_grant`, and Claude Code clears its own Keychain item. The user has to sign
in again.

This happened. An earlier Kvotar version, on an expired Claude sign-in, ran a `claude` command that
refreshes as a side effect. On some mornings that ended with Claude Code signed out. The delegation
was removed, and this rule was made absolute.

Codex is held to the same rule for the same reason: its sign-in belongs to Codex.

## Accepted behavior

- The Claude token is re-read from the Keychain on every poll; nothing caches it. When Claude Code
  refreshes its own sign-in, the next poll uses the new token.
- Before a Claude request, if the token's expiry has passed, the poll stops with "credential expired".
  No request is sent.
- A 401 or 403 from Claude's usage endpoint is retried once, and only if a re-read shows the token on
  disk has changed (another program rotated it). Otherwise the account is shown as needing sign-in.
  The rotated token's expiry is not checked before that one retry; it is a known gap, and it sends
  a request, never a refresh. A 401 or 403 from the prepaid-credits endpoint stops that call for the
  token instead.
- A Claude 429 with a `Retry-After` above 5 seconds, landing within 2 minutes of the token's known
  expiry, is treated as an expired credential, not as rate pressure. A `Retry-After: 0` refusal never
  is.
- Codex: `~/.codex/auth.json` is read and the token sent as it is, with no expiry check first; a
  rejected token is reported as needing sign-in, never renewed.

## Non-goals

- Keeping the user signed in. That is Claude Code's and Codex's job.
- A "fix my sign-in" button that does anything other than tell the user to open the tool.

## Required tests

- `ClaudeAccountAdapterTests.testExpiredCredentialGatesPollNoRequestSent`
- `ClaudeAccountAdapterTests.testExpiredCredentialGatesWithNoRefreshSeam`
- `ClaudeAccountAdapterTests.testAbsentOrFutureExpiryDoesNotGate`
- `CodexWhamHTTPClientTests.testExpiredToken401`
- The network-seam and static checks for this rule, listed in [safety-checks.md](../safety-checks.md).

## Tradeoffs

- After an overnight expiry, the Claude tab shows "sign-in expired" until the user opens Claude Code.
  That is a worse moment than a silent refresh, and much better than a forced sign-in.
- Kvotar depends on Claude Code storing the token where it does today. If that changes, Kvotar stops
  reading it; it must not work around that by refreshing.

## Status

Accepted. Not open to exceptions.

Checked against the code at 8aebac0.
