---
summary: The current rules for finding and reading the Claude and Codex credentials — where each token lives, how it is read without a dialog, the outcomes of a read, the Claude expiry gate, a rejected token, and what Kvotar never does with a credential.
read_when: Changing KeychainTokenProvider, CodexTokenProvider or CodexAuthFileReader, ClaudeTokenProvider or ClaudeCredential, the credential read or the expiry gate in ClaudeAccountAdapter, the 401/403 re-read, credentialChanged, the setupRequired / credentialUnreadable / reauthRequired / credentialExpired errors, DetectionStatus.classify, or anything that could read, write or prompt for a credential.
---

# Credentials

## Questions for owner

None.

## Decided

The maintainer ruled on these on 2026-10-04 (STEP_249). The code does not follow them yet; each
has a row in *Known gaps* below, which a later build step closes.

1. **An observe-only spike checks what Codex does with its own sign-in inside the
   `codex app-server` child.** It runs only the child and records whether `auth.json` changed (for
   example its modification time, as a changed / not changed flag), never the file's contents or
   any token. It never provokes a refresh: no deliberately expired token, no request that asks for
   one. Reason: Kvotar starts the child, keeps it running and sends it no token or refresh request
   (tested; see *What is never done*), but whether Codex itself renews its token inside the child
   while a Codex session also runs is unobserved; that the child manages the credential at all is
   an inference about Codex ([credentials and privacy](../credentials-and-privacy.md#launching-codex)
   calls it Codex's behaviour). Restarting the child per poll is not a fix: each start is another
   chance for Codex to renew. The ruling changes no safety rule; Kvotar still never refreshes and
   never asks anything to. Today no such observation exists.
2. **A rejected token (401 or 403) gets its own sign-in line, for Claude and Codex,** like the
   expired one. [Decision 0001](../decisions/0001-never-refresh-a-token.md) stays as written.
   Reason: waiting will not fix a rejected token, and the line names the one action that helps.
   Today it has no wording of its own.
3. **A present but undecodable credential takes the "could not look" (idle) path, for both tools,
   never "not set up".** This covers a corrupt `auth.json` and Keychain output that does not
   decode. Reason: the credential is there, so first-run would tell a signed-in user to set up a
   tool they already use. Today both read as absent.

## About this page

This page is the specification for reading credentials. It replaces the private Implementation
Baseline §8.0.1 (Credential source), the credential rows of §5.1 and §5.2 (credential posture,
fallback auth, expired-token behaviour) and the Keychain-sharing row of §5.3, plus the private
revision records on token rotation, the expiry gate and the "could not look" outcome. Baseline §7
has no credential rule; its topics belong to the [Claude account](claude-account.md) page and the
[local usage](local-usage.md) page. Change this page in the same commit as the code.

The safety rules are in [AGENTS.md](../../AGENTS.md#the-four-safety-rules), word for word; this
page changes none of them. Their reasons are
[decision 0001](../decisions/0001-never-refresh-a-token.md) (never refresh) and
[decision 0002](../decisions/0002-read-claude-credential-through-security.md) (read through
`/usr/bin/security`); their tests and static checks are in [safety checks](../safety-checks.md).
The user-facing explanation is [credentials and privacy](../credentials-and-privacy.md).

Neighbours: cadence, holds and the new-token probe are [polling](polling.md); what is sent with
each token is the [Claude account](claude-account.md) and [Codex account](codex-account.md) pages;
what the user sees is [display semantics](display-semantics.md).

## Terms used here

| Term | Meaning on this page |
|---|---|
| Credential | What Kvotar takes from a tool's sign-in: the access token and a few fields beside it. Never the refresh token |
| Credential read | One call to a token provider (`ClaudeTokenProvider` or `CodexTokenProvider`). It reads, never writes, and never shows a dialog |
| Absent | The read worked and the credential is not there. The only outcome that may mean "not set up" |
| Could not look | The read itself failed (the tool would not start, the file would not open). Says nothing about whether the user is signed in |
| Re-auth required | The provider rejected the token with 401 or 403 |
| Credential expired | As defined on [polling](polling.md#terms-used-here) (including a countdown 429 reclassified near expiry) |

## Where each credential lives

### Claude

- **Where:** the macOS Keychain item `Claude Code-credentials`, written by Claude Code. Kvotar
  looks for no credentials file.
- **How:** run `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`, read its
  standard output to the end, discard its standard error. (`KeychainTokenProvider.credential`)
  Reason: decision 0002.
- **What is decoded:** `claudeAiOauth.accessToken`, `subscriptionType` and `expiresAt` (epoch
  milliseconds). The refresh token is in the same output but not in the decoded shape, so it is
  never decoded or kept; only the decoded fields outlive the read. (`ClaudeCredential`) How
  `subscriptionType` feeds the plan is for the claude-account page.
- **Only one place launches `security`,** and only with those arguments. (`make check`;
  `NoRefreshNetworkSeamTests.testTheDefaultAccessorIsUsrBinSecurity`,
  `testAFullCycleReachesOnlyTheQuotaEndpointsAndNeverSendsARefreshToken`)

### Codex

- **Where:** `~/.codex/auth.json`, written by Codex. (`CodexAuthFileReader.defaultPath`)
- **How:** a plain file read. Decoded: `tokens.access_token` and `tokens.account_id`; the refresh
  token is not in the decoded shape. The file is never written.
  (`CodexAuthFileReader.credential`; `NoRefreshNetworkSeamTests.testReadingAuthJSONLeavesItByteIdentical`)
- **Only on the web leg.** The normal path is the local `codex app-server`, which uses Codex's own
  sign-in; Kvotar sends it no token. Kvotar reads `auth.json` only when it calls `wham/usage`: when
  the app-server path fails, or to fill in a missing monthly limit.
  (`CodexWhamHTTPClient.fetchUsage`; `CodexAccountAdapter.fetchViaWham`,
  `supplementMonthlyLimitIfNeeded`) When each leg runs is for the codex-account page.

## The outcomes of a read

Every read ends in one of three outcomes, kept apart on purpose:

| Outcome | Claude | Codex | Error and health |
|---|---|---|---|
| Present | `security` exits 0 and the output decodes | the file opens and decodes | a credential |
| Absent | `security` exits 44 (item not found) | the file does not exist | `setupRequired` |
| Could not look | `security` will not start, or exits with any other code | the file exists but will not open (permissions, no free file handles, I/O) | `credentialUnreadable`; health `unknown` |

A fourth case, **present but undecodable** (either tool), is filed as absent today; it should be
"could not look" (Decided 3). (`KeychainTokenProvider.credential`; `CodexAuthFileReader.credential`;
`ClaudeAccountAdapter.fetchQuotaSnapshot`; `CodexAccountAdapter.health(for:)`;
`KeychainTokenProviderTests`, `CodexAuthFileReaderTests`)

- **Before the tool's first successful poll, absent with no local session logs since launch means
  "not detected".** It is the only input that makes a tool first-run; any other failure leaves it
  detected and idle. After a success, any failure freezes the last reading.
  (`DetectionStatus.classify`, called from `PollCoordinator` only before a success;
  `DetectionStatusTests`; display: [first-run window](first-run-window.md#when-it-opens),
  [display semantics](display-semantics.md#unknown-missing-and-stale))
- **Could not look is never "not set up".** Reason: once, when the app ran out of file handles,
  both reads failed and the session-log watchers stopped too, and the user saw a first-run welcome
  on a Mac where both tools were signed in.
  (`DetectionStatusTests.testCredentialUnreadableIsNeverFirstRunEvenWithNoLocalActivity`)
- **A failed read is never retried another way.** No fallback reader, no direct Keychain call, no
  dialog. The next poll reads again.

## Read fresh, kept in memory only

- **Claude: a fresh read before every poll.** Nothing caches the token between polls, so a token
  Claude Code renewed is used on the next poll. Reason: Claude Code can rotate the token at any
  time. (`ClaudeAccountAdapter.fetchQuotaSnapshot`)
- **Claude: two other reads**, with the same provider: after a 401 or 403 (below), and during a
  [hold](polling.md#the-hold), to notice a new token (`ClaudeAccountAdapter.credentialChanged`,
  called from `PollCoordinator.sleepRespectingHold`). A read that fails or finds nothing is "no
  change". (`testCredentialChangedIsFalseWhenTheReadFails`)
- **Codex: a fresh read on every `wham/usage` call.** No cache.
- **In memory only.** The token (for Claude, also the last one sent, to notice a rotation) is
  never written to the database, a setting, a log or a diagnostics bundle. A response body kept
  for diagnostics has it replaced by `<redacted>` first. (`ClaudeAccountAdapter.redactedBody`, `CodexWhamHTTPClient.redactedBody`;
  `ClaudeAccountAdapterTests.testRateLimited429BodyRedactsBearerToken`) Log lines from a read carry
  the exit code or the error, never the output.

## The Claude expiry gate

Claude Code's access token lasts a few hours and is renewed only while Claude Code runs, so an idle
Mac often holds an expired one.

- **The gate runs after the read and before any request.** If now is at or past `expiresAt`, no
  request is sent; the poll ends as credential expired. (`ClaudeAccountAdapter.isCredentialExpired`;
  `testExpiredCredentialGatesPollNoRequestSent`, `testExpiredCredentialGatesWithNoRefreshSeam`)
  Reason: the provider answers an expired token with a 429 and a long countdown, not a 401, so a
  request would only collect a fake refusal.
- **No safety margin:** the gate never blocks a token the local clock still shows as valid. A clock
  running ahead blocks only for the size of its error.
- **No `expiresAt`, no gate.** An absent or null expiry is never expired; the request goes out.
  (`testAbsentOrFutureExpiryDoesNotGate`)
- **A countdown 429 near expiry** counts as credential expired; that rule and its tests are on
  [polling](polling.md#when-the-claude-credential-has-lapsed).
- **Recovery needs no extra step.** The next read that shows a future expiry polls normally.
  (`testZeroNetworkRecoveryPollsWhenExpiryFlipsFuture`, `testEpisodeEndsOnCredentialHealthNotOnAPoll`)
- **Kvotar waits; it does not act.** Only Claude Code renewing its own token ends the gate.
  Cadence and the ladder: [polling](polling.md#when-the-claude-credential-has-lapsed).
- **Codex has no expiry gate.** Its token is sent as read; a rejected one is re-auth required.

## A rejected token (401 or 403)

- **Claude usage call:** read the credential once more. If the token on disk differs, retry the
  usage call once with it. If the read fails, finds nothing or shows the same token, or the retry
  is rejected again, the poll fails as re-auth required. One retry, never a loop.
  (`ClaudeAccountAdapter.fetchQuotaSnapshot`, `checkUsageStatus`; `test401RotationSelfHeals`,
  `test401SameTokenStillReauths`, `test401PersistsThrowsAfterOneRetry`) Reason: Claude Code can
  rotate the token between Kvotar's read and its request; the retry uses the token Claude Code
  already wrote. It reads; it never renews.
- **Claude profile and prepaid calls:** the claude-account page.
- **Codex `wham/usage`:** re-auth required, no re-read. (`CodexWhamHTTPClient.checkStatus`;
  `CodexWhamHTTPClientTests.testExpiredToken401`, `CodexAccountAdapterTests.testExpiredTokenReauthRequired`)

## What is never done

The rules are in [AGENTS.md](../../AGENTS.md#the-four-safety-rules). In this code they mean:

- **No refresh, by Kvotar or through another program.** No token endpoint is called, and no refresh
  token is decoded or sent. The only `claude` or `codex` launches are the `codex app-server` child
  and the `--version` lines of a diagnostics bundle (`make check` pins the launch sites); none is
  run to renew a sign-in. Kvotar never asks the app-server child to refresh: every line sent to it
  is checked (`NoRefreshNetworkSeamTests.testAFullCycleSpeaksOnlyTheQuotaMethodsAndNeverSendsARefreshToken`).
  What Codex does on its own inside it is for the spike (Decided 1). The expiry gate is the whole answer to an
  expired token. (`NoRefreshNetworkSeamTests`, both adapters)
- **No write.** No Keychain write API, no `security` subcommand but `find-generic-password`, no
  write under `~/.claude/`, `~/.codex/` or to `~/.claude.json`.
  (`CredentialTreesUntouchedTests` in KvotarCore and KvotarCLI; `make check`)
- **No dialog.** The code makes no direct Keychain call and asks for no authorization. A read that
  fails is "could not look", never a prompt. (A locked login keychain is not yet checked; see
  *Known gaps*.)
- **No other source.** No browser cookies and no claude.ai session keys (decision 0002), and no
  API keys (see *Rejected alternatives*).
- **The CLI reads no credential.** `kvotar` never calls a provider ([AGENTS.md](../../AGENTS.md#layout)).

## Files next to the credentials

- **`~/.claude.json`:** read only for the account email, when the profile call fails or has none.
  Not a credential; owned by the claude-account page. (`ClaudeAccountAdapter.readLocalConfigEmail`)
- **Diagnostics:** an ordinary bundle records whether `~/.codex/auth.json` and `~/.claude.json`
  exist, never their contents ([diagnostics](diagnostics.md)). (`DiagnosticsBundle`)

## Rejected alternatives

- **Reading the Keychain item directly, refreshing a token, or asking another program to refresh
  one:** see decisions [0002](../decisions/0002-read-claude-credential-through-security.md) and
  [0001](../decisions/0001-never-refresh-a-token.md).
- **Kvotar's own sign-in** (its own login flow and Keychain item). A large change; it would break
  the never-refresh rule, which has no exceptions (decision 0001); and whether the provider allows
  a third-party app to use its login client is unanswered.
- **Browser cookies or claude.ai session keys.** Fragile and against the read-only posture.
- **Usage or admin API keys.** Only organisation admins can have them.
- **Caching the token between polls.** A rotation would leave Kvotar on a stale token.
- **Treating a failed read as "not set up".** It showed a first-run welcome to signed-in users.

## Known gaps

| Gap | Today | Proposed |
|---|---|---|
| Re-auth required has no wording | A 401/403 sets `reauthRequired`; `DisplayFormatter` forks only on `rateLimited` and `credentialExpired`. The user sees the idle card before a first success; after one, the last reading frozen, then, once stale, "No fresh reading — showing last known". Decision 0001 says the account is shown as needing sign-in | Decided 2: add a sign-in line for Claude and Codex, like the expired one, with tests; decision 0001 stays as written |
| A present but undecodable credential reads as "not set up" | Both providers return `nil` on a decode failure (a corrupt `auth.json`, or Keychain output that does not decode), which becomes `setupRequired` and can show the first-run welcome. This includes a Claude item whose `expiresAt` is present with the wrong type: comments say an "unparseable" expiry decodes to nil and skips the gate, but a wrong-typed value fails the whole decode | Decided 3: throw `credentialUnreadable` on a decode failure in both providers; decode `expiresAt` on its own so a bad value only skips the gate; tests for each |
| Codex's own sign-in inside the child is unobserved | Kvotar never asks the `codex app-server` child to refresh, but whether Codex renews its token inside the long-running child is not known | The observe-only spike (Decided 1): record only whether `auth.json` changed, never its contents or a token, and never provoke a refresh |
| The rotated token after a 401/403 is not expiry-checked | The one retry sends the re-read token without the gate. It sends a request; it never refreshes. Already stated in decision 0001 and the privacy doc | Run the gate on the re-read credential before the retry, with a test |
| The `security` call has no time limit | `waitUntilExit` blocks the Claude adapter until the tool exits; behaviour on a locked login keychain is not recorded | Treat a timeout as "could not look", with a test; check the locked case on a test account. Never add a path that can show a dialog |
| No static check for a direct Keychain read | `make check` bans `SecItemAdd`, `SecItemUpdate` and `SecItemDelete`, not `SecItemCopyMatching`, which decision 0002 forbids | Add it to `scripts/check_rules.sh`, skipping comments or with an exception for the `KeychainTokenProvider` doc comment |
| Expired at launch with nothing restored shows the idle card | Before the first success, with no restored reading, `PollCoordinator` calls `applyUnavailable`, which carries no reason, so the sign-in-expired line does not appear, although decision 0001 says the app shows that the sign-in expired. Read in the code, not checked in the running app | The display-semantics owner decides; likely pass the reason to the idle card, with a test |
| Provider tests miss two paths | No decode-failure test in either provider; the Claude provider test does not assert `expiresAt` | Add with the decode fix above |
| Fixed Codex path | `auth.json` is always read from `~/.codex/`. Codex lets a user move its home folder (`CODEX_HOME`); Kvotar does not follow it. Not checked against a real install | Decide whether to support it; if so, read the variable the way Codex does, with a test |
| The privacy doc reads as if `auth.json` is read on every Codex poll | It is read only on the `wham/usage` leg | One sentence in `docs/credentials-and-privacy.md` with its next edit |
| Stale code comments | Inaccessible Keychain read as absent: `ClaudeTokenProvider.credential`, `AdapterHealth.setupRequired`. A re-auth ask that does not exist: `AdapterHealth.reauthRequired`, `headerVerdict`. Sign-in-expired copy described wrongly: `AdapterHealth.credentialExpired`, the `credentialExpired` catch in `PollCoordinator`. "Unparseable" expiry decodes to nil: `KeychainTokenProvider`, `ClaudeCredential.expiresAt`. A fast clock never blocks: `ClaudeAccountAdapter.credentialSkewTolerance`. A third-party app named as precedent: `KeychainTokenProvider` | Fix with the next change to each file |

## Code and tests

- Claude read: `Packages/ClaudeAdapter/Sources/ClaudeAdapter/KeychainTokenProvider.swift`;
  `ClaudeTokenProvider` and `ClaudeCredential` in `Packages/ClaudeAdapter/Sources/ClaudeAdapter/Seams.swift`.
- Codex read: `Packages/CodexAdapter/Sources/CodexAdapter/CodexTokenProvider.swift`; its use in
  `Packages/CodexAdapter/Sources/CodexAdapter/CodexWhamHTTPClient.swift`; the legs and error
  mapping (`fetchViaWham`, `supplementMonthlyLimitIfNeeded`, `health(for:)`) in
  `Packages/CodexAdapter/Sources/CodexAdapter/CodexAccountAdapter.swift`.
- Gate, 401/403 re-read, `credentialChanged`:
  `Packages/ClaudeAdapter/Sources/ClaudeAdapter/ClaudeAccountAdapter.swift`.
- Outcomes: `AccountAdapterError`, `AdapterHealth` and `DetectionStatus` in
  `Packages/KvotarCore/Sources/KvotarCore/Adapters/AccountAdapter.swift`; the first-run and idle
  paths and `sleepRespectingHold` in `App/PollCoordinator.swift`.
- Tests: `KeychainTokenProviderTests`, `NoRefreshNetworkSeamTests` and the credential tests in
  `ClaudeAccountAdapterTests` (ClaudeAdapter); `CodexAuthFileReaderTests`,
  `NoRefreshNetworkSeamTests`, `CodexWhamHTTPClientTests` (CodexAdapter); `DetectionStatusTests`
  and `CredentialTreesUntouchedTests` (KvotarCore); `CredentialTreesUntouchedTests` (KvotarCLI).
- Static checks: `scripts/check_rules.sh`, described in [safety checks](../safety-checks.md).

Checked against the code at 595b1b9 + STEP_266
