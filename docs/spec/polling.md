---
summary: The current rules for when Kvotar asks the providers for quota — the fixed cadence, the extra one-off polls and their caps, what a refused poll (HTTP 429) does, the server-advertised hold, the expired-credential path, recovery, and why a refused poll is never the user's quota running out.
read_when: Changing PollCoordinator's loop, sleeper, wake or re-check paths; PollBackoffPolicy, ResetBoundaryPolicy, JSONLTripwirePolicy, NullWindowExpeditePolicy, TurnBoundaryPolicy, StartupRetryPolicy or FirstPollGracePolicy; Retry-After or 429 handling in ClaudeAccountAdapter or CodexWhamHTTPClient; the Claude prepaid or profile call gating; the credential-expiry gate's effect on cadence; poll_health_events or quota_limit_events writes; settings.poll_cooldown_until; or any user copy that could describe polling.
---

# Polling

## Questions for owner

None.

## Decided

The maintainer ruled on these on 2026-10-04 (STEP_247). The code does not follow them yet; each
has a row in *Known gaps* below, which a later contract closes.

1. **A 429 with no `Retry-After` header is handled like `Retry-After: 0`:** the plain 120 s retry
   and the refused-recently floor, and no stored hold. Reason: a missing header is not a deadline
   the server stated, and only a stated deadline should create a hold that survives a relaunch.
   Today the adapters turn a missing header into 120, so it becomes a stored 120 s hold.
2. **The plain 120 s retry gets positive jitter only:** a random wait of 120–125 s after a
   `Retry-After: 0` refusal (and, by Decided 1, after a refusal with no header). Reason: two Macs on
   one account should not retry in lock-step, and a retry earlier than the roughly 120 s refill
   would likely be refused again. A non-zero wait stated by the server is never altered. Today the
   retry waits exactly 120 s.

## About this page

This page is the specification for polling: how often Kvotar asks each provider for quota, the
extra polls it may add, and what it does when a poll is refused. It replaces the private Baseline
§9.1, §9.2 and §9.3 (except the staleness display rules, which live in
[quota readings](quota-readings.md) and [display semantics](display-semantics.md)) and §9.5's
rules for which table a 429 goes to. Change this page in the same commit as the code it describes.

Why the cadence and the 429 rules are what they are is recorded in
[decision 0003](../decisions/0003-polling-and-rate-limits.md). Why Kvotar never refreshes a token
is [decision 0001](../decisions/0001-never-refresh-a-token.md). How the credential is read is in
[credentials](credentials.md); the provider endpoints, response shapes and request timeouts are in
[Claude account](claude-account.md) and [Codex account](codex-account.md). What a reading means and when
it is stale is [quota readings](quota-readings.md); which state a tool is in is
[state](state.md); what the user sees is [display semantics](display-semantics.md).

## Terms used here

| Term | Meaning on this page |
|---|---|
| Poll | One quota request cycle for one tool, through its account adapter. Claude and Codex poll independently, each on its own loop |
| Base cadence | The steady wait between polls: 120 s ± 5 s jitter |
| Floor | The shortest gap an *automatic* trigger may leave after the last poll: 45 s, or the current rung delay while the tool is "refused recently" |
| Poll refusal (poll 429) | The provider refused **Kvotar's own** quota request with HTTP 429. It says nothing about the user's quota |
| Quota 429 | The **user's** Claude Code or Codex session hit a usage limit, seen in that tool's session log |
| Refused recently | The ladder sits on rung 1 after a `Retry-After: 0` refusal or a repeated countdown; it drops 15 minutes after the last such refusal |
| Hold | A server-advertised cooldown from a non-zero `Retry-After`: a deadline before which no automatic trigger polls |
| Credential expired | The stored Claude access token (the Keychain item) is past its expiry. Kvotar sends no request and waits for Claude Code to refresh it |

## The base cadence

- **120 s ± 5 s jitter, both tools.**
  (`Packages/KvotarCore/Sources/KvotarCore/Polling/PollBackoffPolicy.swift`: `defaultBase`;
  jitter `.random(in: -5...5)` in `App/PollCoordinator.swift`: `runLoop`)
  Reason: the Claude usage endpoint gives an account roughly one success per two minutes, shared
  with every Claude Code process on that account. Faster polling does not make the number fresher;
  it spends the allowance Claude Code also needs. Codex shares the rule so one cadence explains
  both tools.
- **The base is a constant.** Nothing raises it, lowers it, stores it or restores it. A relaunch
  starts at it. Reason: a cadence that remembered past refusals pinned machines at the slowest rate
  for days, and a constant cannot get stuck. (`testSteadyCadenceIsAlwaysTheFixedBase`,
  `testNoSequenceOf429sPermanentlyRaisesTheBase`, `testFreshPolicyStartsAtTheBase`)
- **Clamp: never faster than 45 s, never slower than 300 s** between ordinary polls (`minInterval`,
  `maxInterval`, applied by `clamped`). Neither bound applies to a 429 recovery wait (5 s to
  3,600 s, below) or to the startup network retry (from 15 s); both are bounded one-off waits.
- **One loop, one sleeper per tool.** Every extra poll works by cancelling that tool's current sleep
  (`sleepers[tool]?.cancel()`), so the loop runs the next poll at once. An in-flight poll is never
  cancelled, and two polls to the same tool never overlap. (`PollCoordinator.sleepRespectingHold`)
- **Only one Kvotar process polls.** A PID lock is taken at launch; a second copy does not start
  its poll loops. (`App/AppDelegate.swift`, the `PIDLock` block;
  `Packages/KvotarCore/Sources/KvotarCore/Lifecycle/`; `PIDLockTests`)
- **Kvotar identifies itself.** Every direct HTTP request sends `User-Agent: Kvotar/<version>`,
  and the local `codex app-server` is told `clientInfo.name` "Kvotar" at `initialize`. Never
  another client's name. (`URLSessionFetcher.userAgent`, `CodexHTTPFetcher`,
  `CodexRPCClient`)

## Launch, sleep and wake

- **First poll after launch respects the previous process's poll clock.** The delay is `max(0, 120 s
  − age)`, where `age` is the time since the newest stored poll for that tool; no stored poll, or an
  age of 120 s or more, polls at once; a negative age (clock skew) waits the full 120 s. Reason: a
  relaunch once polled 4 s after the outgoing process and collected more refusals. The restored
  reading is already on screen, so the wait costs nothing. (`PollBackoffPolicy.firstPollDelay`;
  `PollCoordinator.runLoop`; `testFirstPollDelay*`)
- **A restored hold extends that delay** to the hold's deadline (see *The hold* below).
- **Sleep.** After a system sleep, the wake refresh (next bullet) ends the wait. The sleeper's
  `Date` deadline is re-checked only between the 120 s slices of a held sleep, so do not rely on
  it to end an ordinary wait at wake. (`sleepRespectingHold`)
- **Wake.** On `NSWorkspace.didWakeNotification` each tool polls at once, unless it is under a hold
  or its last poll is younger than the floor. (`PollCoordinator.wakeRefresh`; wired in
  `AppDelegate`)
- **Cold poll on Claude.** A Claude poll more than 330 s after the last success makes only the usage
  call; the profile and prepaid calls wait one cadence. The first poll of a launch is never cold
  (the last-success time is kept in memory only), so it fetches everything. Reason: the moment after
  a wake is the most contended moment on a shared credential.
  (`ClaudeAccountAdapter.coldPollThreshold`; `testColdStartFetchesSecondariesThenSteadyState`)
- **Startup network retry.** Until the first success of the launch, a network-shaped failure
  (timeout, connection lost, offline, cannot connect to host, host not found, DNS failure) retries
  after 15 s, 45 s, 120 s, then 300 s, then falls back to the base cadence. It never handles a 429,
  an HTTP status or a decode error. (`StartupRetryPolicy`; `StartupRetryPolicyTests`)

## Extra polls

Each extra poll is a single, automatic poll on a specific event. None of them changes the base
cadence, and each respects the hold (the reset-boundary and empty-window polls follow a success,
which has already cleared it).

| Extra poll | Fires when | Bounds | Code / tests |
|---|---|---|---|
| Reset boundary | After a successful poll, a known reset (five-hour or weekly, whichever is sooner) falls before the next scheduled poll | At `max(reset + 30 s, now + 5 s)`, never sooner than 45 s after this poll; once per boundary | `ResetBoundaryPolicy`; `ResetBoundaryPolicyTests` |
| Session start (JSONL tripwire) | The first *meaningful* local change (surface or helper count changed, burn tier crossed, or a quota 429 in the log) after 8 minutes without one, or the first of the launch. Usually the first turn of a session | 45 s after the last poll (or the restored poll time); a suppressed trip is not deferred; blocked by a hold | `JSONLTripwirePolicy`; `PollCoordinator.handleLocalDelta`; `JSONLTripwirePolicyTests` (`testFloorSuppressionDoesNotConsumeTheTransition`) |
| Turn end (alignment) | 45 s pass with no new local usage after a flush, and the window has a reset time | One between two completed polls; **at most 6 per quota window**; the floor; blocked by a hold; flushes whose newest event is over 120 s old are ignored | `TurnBoundaryPolicy`; `PollCoordinator.handleLocalActivity`, `fireAlignmentPoll`; `TurnBoundaryPolicyTests` |
| Empty window after a gap (Claude only) | A successful poll more than 330 s after the previous success finds the five-hour window null or not started ([quota readings](quota-readings.md)) | One poll, 45 s later, per stretch of empty readings (re-armed only by a populated window); never on a monthly (Enterprise) layout; never on a first-ever poll | `NullWindowExpeditePolicy`; `NullWindowExpeditePolicyTests` |
| Wake | The Mac wakes | The floor; blocked by a hold | `PollCoordinator.wakeRefresh` |

Reasons, one line each:

- **Reset boundary:** the rollover is the one moment a scheduled poll is always late; one request at
  the boundary beats polling faster near it.
- **Session start:** fresh numbers land seconds after a session begins, not up to two minutes later.
- **Turn end:** one poll at the start of a pause makes that pause a clean interval for the
  off-machine estimate. It is measurement precision, not freshness. If it ever adds request
  pressure, lower the cap of 6; never shorten the quiet stretch or weaken the floor.
- **Empty window after a gap:** an empty window right after a sleep is usually the provider not
  having rebuilt it yet; it is worth one quick look, not a faster cadence. Codex and Enterprise
  are excluded because an empty five-hour window is their normal idle shape.
When the reset-boundary poll and the empty-window poll both apply, the sooner one wins.
(`PollCoordinator.runLoop`, the `.success` branch)

**Re-check is a user action, not an extra poll.** The **Re-check** button on the card shown when a
tool is not found polls that tool at once, bypassing the floor and the hold. Reason: an explicit
user action should always take effect. Decision 0003's floor-and-hold rule covers automatic polls
only. (`PollCoordinator.recheck`; `Packages/KvotarUI/Sources/KvotarUI/Views/StatusCards.swift`)

**Opening the popover does not poll.** It refreshes only the local daily report.
(`PollCoordinator.popoverOpened`) There is no general "refresh now" control; Re-check exists only
on the card shown when a tool is not found.

## When a poll is refused (HTTP 429)

The ladder lives in `PollBackoffPolicy.rateLimited`; the adapter reads `Retry-After` and turns a
missing header into 120 (`ClaudeAccountAdapter.checkUsageStatus`;
`Packages/CodexAdapter/Sources/CodexAdapter/CodexWhamHTTPClient.swift`).

| Refusal | Wait before the next poll | Refused-recently flag | Hold |
|---|---|---|---|
| `Retry-After: 0` (the usual Claude refusal) | `retryCadence` = 120 s, every time | Set at once | None; clears any existing hold |
| Non-zero `Retry-After`, first in a row | The advertised value, at least 5 s, at most 600 s | Not set | Until that wait ends |
| Non-zero `Retry-After`, second or later in a row | The advertised value in full, at least 120 s, at most 3,600 s | Set | Until that wait ends |

Constants: `retryCadence` 120, `retryAfterFloor` 5, `retryAfterCap` 600, `retryAfterAbsoluteCap`
3,600, all in `PollBackoffPolicy`. "In a row" is `consecutive429s`, which only a success resets.
(`testRetryAfterZeroWaitsTheRetryCadence`, `testFirst429HonorsRetryAfter`,
`testFirstProbeCappedAtTenMinutes`, `testRepeat429HonorsTheAdvertisedCooldownInFull`,
`testRepeat429StillBoundedByTheAbsoluteCeiling`,
`testZeroRetryAfterEntersTheCadenceRungAndNeverClimbsPastIt`)

A 429 with no `Retry-After` header becomes 120, so today it follows the countdown rows; it is ruled
to follow the `0` row (Decided 1). The 429 wait is not jittered today; it is ruled to wait
120–125 s (Decided 2).

Reasons:

- **`Retry-After: 0` waits 120 s.** On the Claude usage endpoint it means "the account's slot is
  taken this minute", not "retry now". The allowance refills about every 120 s, so a sooner retry
  is wasted and a much later one hands the refills to other callers.
- **A first countdown is capped at 10 minutes.** A one-off huge value once froze the Claude side for
  an hour and turned out to be wrong; the capped probe costs one request.
- **A repeated countdown is honoured in full, up to an hour.** The server has said it twice, and
  probing inside a real cooldown may extend it.

**The refused-recently flag** is ladder rung 1. Since rung 0 and rung 1 are both 120 s, it does not
slow the cadence. It only raises the floor for wake and the turn-end poll to 120 s. It drops one
rung per 15 minutes since the last refusal (`ladderHalfLife` = 900 s), measured on the wall clock.
A success alone does not clear it. (`isElevated`, `steadyDelay`, `decay`;
`testIsElevatedIsKeyedOnTheRungNotTheDelay`, `testRungDecaysOneStepPerHalfLife`,
`testASuccessAloneDoesNotDemoteTheRung`; floor in `PollCoordinator.pollFloor`)

**Other failures never touch the ladder.** Network errors, timeouts, decode errors and other HTTP
statuses keep the current rung and the consecutive count and wait the base cadence (or the startup
retry above). (`PollBackoffPolicy.failed`; `testFailureNeverAdvancesTheLadder`)

**Codex:** any failure of the `codex app-server` call, a 429 included, falls through to the web
endpoint in the same poll. Only a refusal of the web endpoint reaches the ladder. Codex has no early
probe during a hold. (`CodexAccountAdapter.fetchQuotaSnapshotInner`)

### The hold

- **Set** by a non-zero `Retry-After`, to the scheduled retry time; **cleared** by a success, by a
  `Retry-After: 0` refusal (in memory only; see Known gaps) or by a credential rotation; left
  alone by other failures. (`holdUntil`; `testNonZeroRetryAfterSetsTheHoldToTheScheduledProbe`,
  `testZeroRetryAfterSetsNoHoldAndClearsAnExistingOne`, `testNonRateFailureLeavesTheHold`)
- **Binds every automatic trigger.** Wake, session start and turn end do nothing while it is pending
  (a DEBUG log line says so). A held session-start or turn-end trigger is not used up.
  (`PollCoordinator.heldByCooldown`) The user's Re-check still polls.
- **Survives a relaunch.** It is written to `settings` as `poll_cooldown_until.<tool>` (unix
  seconds) and set back to empty on the next success or on a credential rotation. At launch a future
  value is restored, clamped to one hour from now, and delays the first poll.
  (`restorePersistedSnapshots`, `seedHold`; `testSeedHoldPastFutureAndClamped`) This is a
  server-stated deadline with its own expiry, not a learned cadence.
- **One early exit, Claude only: a new token.** While a hold is pending the sleep wakes every 120 s
  (`credentialProbeSlice`) and re-reads the Claude credential, read only, no network. If the token
  differs from the one the last request carried and is not expired, the hold is dropped and Kvotar
  polls at once. With no request made yet this launch (a hold restored at launch), the first re-read
  only records the token. (`ClaudeAccountAdapter.credentialChanged`; `testCredentialChanged*`)
  Reason: the only early recoveries observed followed a token rotation.

Reason for the hold: around each long lockout, wake and local-activity polls each probed into the
cooldown and were refused with the same countdown; a relaunch did the same.

## Claude's secondary calls

The profile call and the prepaid-balance call share the usage endpoint's account. They are kept
off the hot path:

- **Profile:** once per token. (`ClaudeAccountAdapter.fetchProfileIfNeeded`;
  `testProfileFetchedOncePerToken`)
- **Prepaid balance:** only when the profile says Pro or Max, at most one attempt per 15 minutes
  (`prepaidMinInterval` = 900 s), and never again for that token after a 401 or 403. A token change
  reopens the gate. (`refreshPrepaidIfStale`, `fetchPrepaid`; `testTeamProfileNeverCallsPrepaid`,
  `testPrepaidCadenceGateSkipsRefetchInsideWindow`, `testPrepaid403StopsFurtherCallsForTheToken`,
  `testPrepaid401AlsoLatches`, `testTokenChangeReopensThePrepaidGate`) Reason: on other plans the
  call is refused with 403, and every one-hour lockout observed in testing followed such a refusal; with
  usage-only calls none occurred.

A prepaid failure never fails the quota poll. (`testPrepaidFailureDoesNotBlockQuotaPoll`)

## When the Claude credential has lapsed

Kvotar **never refreshes** a token and never triggers anything that would (decision 0001). It only
waits for Claude Code to refresh its own credential. The check before a request is specified in
[credentials — The Claude expiry gate](credentials.md#the-claude-expiry-gate).

- **Before each poll** the credential is read fresh. If it is past its expiry, **no request is
  sent**; the poll ends as "credential expired". (`ClaudeAccountAdapter.fetchQuotaSnapshot`, the
  expiry gate; `testExpiredCredentialGatesPollNoRequestSent`,
  `testExpiredCredentialGatesWithNoRefreshSeam`)
- **The re-read cadence is the base cadence**, 120 s ± 5 s. The next tick after Claude Code
  refreshes the token polls normally. (`PollCoordinator.runLoop`, the `.credentialExpired` branch,
  which calls `failed`)
- **A countdown 429 (a `Retry-After` above 5 s) within 120 s of the token's expiry** is treated as
  credential expired, not as a refusal (clock-skew guard). (`credentialSkewTolerance`,
  `isCredentialShaped429`; `testCountdown429NearExpiryReclassifiedCredentialShaped`,
  `testCountdown429FarFromExpiryStaysRateLimited`)
- **Credential expired never touches the ladder** or the consecutive count, and never sets a hold.
  It writes its own `poll_health_events` row with category `credential_expired`.
  (`testCredentialShapedRejectionDoesNotAdvanceLadder`; `writeCredentialExpiredHealthEvent`)
- **A 401 or 403 on the usage call** re-reads the credential once; if the stored token changed,
  the call is retried once with it. Otherwise the poll fails as "re-auth required" and waits the
  base cadence. (`test401RotationSelfHeals`)

Codex has no expiry gate; its credential reading is in
[credentials](credentials.md#where-each-credential-lives), and its poll failure handling is in
[Codex account](codex-account.md#two-transports-one-reading).

## Recovery

- **A success** resets the consecutive count, clears the hold (and its stored row), ends the
  startup retry window and returns to the base cadence. The refused-recently flag stays until its
  15 minutes pass. (`PollBackoffPolicy.succeeded`; `PollCoordinator.runLoop`)
- **While polls fail**, the last reading stays on screen and the cached state is re-evaluated on
  every failed poll, so the stale threshold and a passed reset (both defined in quota readings)
  still apply. How that looks is for [quota readings](quota-readings.md), [state](state.md) and
  [display semantics](display-semantics.md). (`PollCoordinator.evaluateStaleness`)
- **A first launch that is refused for 10 minutes** (`FirstPollGracePolicy`, 600 s) with nothing
  restored drops the tool to the unavailable (idle) state while polling continues; the first success
  restores it. A restored reading is never wiped this way. (`PollCoordinator.pollOnceInner`;
  `FirstPollGracePolicyTests`)

## A refused poll is not an exhausted quota

Two different 429s, never mixed:

| | Poll refusal | Quota 429 |
|---|---|---|
| Whose request | Kvotar's own quota request | The user's Claude Code or Codex session |
| Seen in | The adapter's HTTP response | The tool's local session log |
| Stored in | `poll_health_events` (90 days) | `quota_limit_events` |
| Effect | The ladder and hold above; the reading freezes | Recorded; nothing reads it today (see [capacity learning](capacity-learning.md#dormant-today)); no cadence change (it can trip the session-start poll) |
| Says about the quota | Nothing | The user reached a limit |

(`PollCoordinator.writePollHealthEvent`, `writeQuota429Events`; `SQLiteStore+PollHealth.swift`,
`SQLiteStore+QuotaLimitEvents.swift`, `SQLiteStore+Retention.swift`)

- A poll refusal is **never** shown as the user being out of quota and never moves a tool toward a
  limit or blocked state. It only freezes the reading, which ages and can go stale (see
  Recovery). Whether the user is blocked comes only from a successful reading (used percent, the
  provider's "limit reached" fields); see [quota readings](quota-readings.md) and
  [state](state.md).
- A quota 429 (a 429 or 529 line in the session log) is recorded only after at least one
  successful poll this launch that carried a used percent for the primary window, because the row needs it.
  (`writeQuota429Events`; `LocalDeltaSignal.quota429Observations`)
- A run of other rejections from one endpoint (standing rejections) is a separate diagnostics
  record; see [diagnostics](diagnostics.md).

## Never in user copy

The user never sees polling mechanics: no cadence, no throttling, no retry, no 429. The banned stems
are one list, `UserCopyRules.pollingWords`
(`Packages/KvotarCore/Sources/KvotarCore/UserCopyRules.swift`), checked by
`ExplanationRegistryTests` and `UserNotificationPresenterTests`. The wording the user sees while
polls fail lives in [display semantics](display-semantics.md); do not restate it here. Changing the
rule or the list needs the maintainer's agreement (AGENTS.md, *The copy rule*).

## Rejected alternatives

Rejected after measurement or incidents; don't re-propose without new evidence.

- **A 60 s base.** Most refusals happened at 60 s and almost none at 120 s, the first cadence
  inside the refill; the measurement is in
  [decision 0003](../decisions/0003-polling-and-rate-limits.md#why).
- **90 s.** Still outside the refill rate.
- **60 s while working, 180 s while idle.** Keeps 60 s exactly where the refusals happen.
- **A cadence that follows activity or the viewer.** Continuous activity-scaled cadence was rejected
  earlier; the turn-end poll is a bounded one-off, not this.
- **A learned, stored base** that 429s raise and successes slowly lower. One brief refusal counted
  three times walked the base to 240 s in 11 s, recovery was practically unreachable, and machines
  sat at 300 s for days.
- **A 5 s first retry after `Retry-After: 0`.** It almost always failed: 5 s is far shorter than the refill.
- **A 300 s rung for repeated `Retry-After: 0`.** Each wait gave several refills to other callers.
- **Using response rate-limit headers as a headroom signal.** They were never present.
- **A follow-up ladder for the empty-window poll.** A second, slower step is slower than simply
  waiting for the next scheduled poll.
- **Widening the stale threshold** ([quota readings](quota-readings.md)) to hide refusal stretches.
  It treats the symptom.
- **Any refresh trigger, of any shape.** Starting `claude doctor` on a lapsed token could replay a
  used refresh token and make Claude Code wipe its own credential. It was removed; never re-add it.

## Known gaps

| Gap | Today | Proposed |
|---|---|---|
| Session-start poll ignores the refused-recently floor | `JSONLTripwirePolicy.deltaArrived` compares only against 45 s. The `PollBackoffPolicy.isElevated` doc comment says this floor exists so a session start cannot poll 45 s after a refusal, as wake and turn end already cannot | Pass `PollCoordinator.pollFloor` into the tripwire, with a test |
| A `Retry-After: 0` refusal leaves the stored hold | It clears the hold in memory, but `runLoop` writes `poll_cooldown_until.<tool>` only when a hold exists and never clears it on this path. A relaunch inside the old deadline restores a hold the previous process had dropped | Clear the row in the `Retry-After: 0` branch, with a test |
| A missing `Retry-After` becomes a stored hold | The adapters turn a missing header into 120, so `PollBackoffPolicy.rateLimited` treats it as a countdown: a stored hold and no refused-recently flag | Decided 1: treat it like `Retry-After: 0` (120 s retry, refused-recently floor, no stored hold), with a test; fix the policy's doc comment |
| The plain 429 retry is not jittered | `runLoop` sleeps exactly `waitSeconds`, 120 s for `Retry-After: 0` | Decided 2: wait a random 120–125 s on the plain retry only; never alter a non-zero server wait; with a test |
| Stale code comments | `NullWindowExpeditePolicy` ("base now fixed at 60s"), `TurnBoundaryPolicy` ("60s base"), `PollCoordinator` (`backoff` "starts at 60s", `wakeRefresh` "300s ladder wait", type doc "persisted/decaying base"), `ClaudeAccountAdapter.credentialChanged` ("60 s credential cadence"), `SQLiteStore+PollHealth.swift` ("7-day retention"); `sleepRespectingHold` (says a system sleep ends the wait at the deadline); `TurnBoundaryPolicy` cites a private polling document that is not public | Fix with the next change to each file |
| `PATTERNS.md` says the poll role includes "proactive slowdown" | That rule was deleted; nothing slows down ahead of a refusal | Remove the words with the next PATTERNS.md edit |
| Polling word in the "already running" copy | `AlreadyRunningView.Conflict.message` says "Only one app polls at a time" (AgentPilot lock) and "Only one instance polls at a time" (unreachable: a second Kvotar hands off and quits, `SecondInstanceAction.decide`). "polls" breaks the copy rule, and no copy test sweeps this view. The rule has no exceptions | A separate contract: reword the AgentPilot sentence (for example "Only one app can run at a time."), update `AlreadyRunningViewTests` and the private old-name audit pattern, delete the unreachable string, and add the view to a copy sweep |
