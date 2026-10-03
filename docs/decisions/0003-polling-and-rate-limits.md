---
summary: How often Kvotar asks the providers, what it does on a 429, how it identifies itself, and why none of it appears in the UI.
read_when: Changing poll timing, retry or 429 handling, request headers, a new endpoint, or any user-facing text about freshness or connection state.
---

# 0003 — Polling and rate limits

## Decision

- **One fixed cadence: 120 seconds ± 5 seconds of jitter, for both tools.** It is never raised or
  lowered by past events, never stored, and a relaunch starts at it again.
- Steady polling is never faster than 45 seconds or slower than 5 minutes.
- A few one-off extra polls are allowed, each bounded and each respecting the 45-second floor and any
  hold below. Examples: one just after a known reset time; at most six per quota window when a local
  work turn ends; when local activity starts.
- Every direct request to a provider says who it is: `User-Agent: Kvotar/<version>`. The local
  `codex app-server` is told Kvotar's name in `initialize`. Kvotar never imitates another client.
- The user never sees polling mechanics. No "throttled", "backing off", "rate limited", "poll",
  "retry" or "cadence" in UI copy.

## Why

The Claude usage endpoint gives an account roughly one successful call per two minutes, shared with
every Claude Code process on that account, plus a small reserve. Measured with Claude Code in normal
use: at a 60-second cadence 35 of 90 calls were refused; at 120 seconds, 1 of 44. Faster polling
does not make the numbers fresher; it spends the allowance Claude Code also needs.

A cadence that remembered past refusals pinned machines at the slowest rate for days. A constant
cannot get stuck.

An honest User-Agent keeps Kvotar visible as itself in the provider's logs. Pretending to be Claude
Code to get past a limit would risk a block for the user.

Polling words in the UI describe Kvotar's plumbing, not the user's quota. They worry people about the
wrong thing.

## Accepted behavior

When a provider answers **429**:

- **`Retry-After: 0`** (the usual Claude refusal): wait 120 seconds, the allowance's refill time. Mark
  the tool as "refused recently" in memory; the mark drops one step per 15 quiet minutes. A success
  alone does not clear it.
- **A non-zero `Retry-After`, first time:** wait that long, but at least 5 seconds and at most 10
  minutes. This wait is a hold: wake-ups and extra polls respect it, and it survives a relaunch.
  While a Claude hold is pending, Kvotar re-reads the credential every 120 seconds (read only) and
  probes early only if the token has changed and is not expired. Codex has no early probe.
- **Refused again with a non-zero `Retry-After`:** wait at least 120 seconds, and honor the
  advertised value in full up to one hour.
- A Claude 429 that looks like an expired token (see [0001](0001-never-refresh-a-token.md)) is a
  credential problem, not rate pressure, and never touches this ladder.
- Network errors, timeouts and 5xx never advance the ladder.
- Codex: a refused `app-server` call falls through to the web endpoint first.

Two different 429s are never mixed: a refusal of **Kvotar's own call** is stored in
`poll_health_events`; a refusal the **user's session** hit (seen in Claude Code's or Codex's logs) is
stored in `quota_limit_events`. One says nothing about the other.

Only one Kvotar process polls at a time (a PID lock).

In the UI, a reading shows its age (`· 3m ago`), amber once it is four minutes old. During a
refusal the last numbers stay on screen; once they are too old to trust, the empty-window form
reads "Reconnecting…", and a recorded hard block keeps its own message.

## Non-goals

- Polling faster to look more "real time".
- Using response rate-limit headers as a signal (when measured, they carried nothing usable).
- Any user setting for the cadence.

## Required tests

- `PollBackoffPolicyTests` — notably `testSteadyCadenceIsAlwaysTheFixedBase`,
  `testNoSequenceOf429sPermanentlyRaisesTheBase`, `testRetryAfterZeroWaitsTheRetryCadence`,
  `testFirstProbeCappedAtTenMinutes`, `testRepeat429HonorsTheAdvertisedCooldownInFull`,
  `testCredentialShapedRejectionDoesNotAdvanceLadder`, `testTheBaseIsNotFasterThanTheRefillCadence`.
- The banned-word tests over UI copy: `ExplanationRegistryTests` and `UserNotificationPresenterTests`,
  both reading the one list `UserCopyRules.pollingWords`.

## Tradeoffs

- The Claude number can be up to about two minutes old between polls. The extra one-off polls exist
  for the moments that matter (a reset, the end of a turn).
- An account under heavy use from several Claude Code sessions can still see occasional refusals.
  Kvotar waits rather than competes.

## Status

Accepted. Changing any number here needs approval and measurement on a real account first.

Checked against the code at 8aebac0.
