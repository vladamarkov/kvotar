---
summary: How Kvotar reads Codex quota — finding and starting the local `codex app-server`, the `wham/usage` web fallback, what is sent with the token, which payload fields become a reading, the placeholder-reset rule and exactly when its drift clause applies, model allowances, and how plan_type strings (Free, Go, Plus, Pro, Enterprise, Business) are read.
read_when: Changing CodexAccountAdapter (normalize, isUnanchoredWindow, isUnanchoredCandidate, recordRawAnchor, anchorDriftTolerance, additionalLimits, the monthly supplement, applyUsageLimitedSignal), CodexRPCClient or CodexProcessTransportLive (launch arguments, initialize, restarts, timeouts), CodexWhamHTTPClient or CodexURLSessionFetcher (headers, status mapping), CodexRPCResponses or CodexWhamResponses (decoding), CodexBinaryCandidates or DefaultCodexBinaryLocator, or any code that reads a Codex plan_type.
---

# Codex account

## Questions for owner

None.

## Decided

The maintainer ruled on these on 2026-10-04 (STEP_252). The code does not follow them yet; each
has a row in *Known gaps* below, which a later build step closes.

1. **The plan follows `account/read`.** Once `account/read` names a plan, the app-server's
   `rateLimits.planType` and the web `plan_type` only fill an empty one. The cached identity (plan
   and email) is cleared when the account changes. A `business` or `enterprise` plan label never
   hides credits that the data says exist. Reason: the earlier record already chose `account/read`
   as the plan shown; a source disagreement must not flip the badge, write `plan_changed` rows or
   hide data. Caveat: a long-running app-server can itself report an old plan until it restarts
   (see Rejected alternatives). Today the last source to answer wins, identity is never cleared,
   and the Codex credits section appears only for the exact plan `enterprise`.
2. **The monthly supplement also accepts `enterprise_cbp_usage_based` and
   `self_serve_business_usage_based`,** and a refusal of the supplement call is reported to polling
   (or the call is skipped while a hold is pending) before or in the same code step. Reason: the
   badge already treats those strings as Enterprise and Business, and more accounts must not
   repeatedly call an endpoint that is refusing them. Today the gate accepts only `enterprise` and
   `business`, and a refused supplement call is swallowed.

## About this page

This page specifies how Kvotar reads Codex quota. It replaces the private Baseline §8.1 (the app-server as primary
source), §8.2 (the web fallback), the parts of §8.3 (Codex Enterprise behaviour and the
not-started rule) that [quota readings](quota-readings.md) did not take, §8.6 (binary discovery)
and §8.7 (the app-server process lifecycle), and the data parts of the private UI Spec Part 2 §0
(Codex context, the null-window state and plan_type handling). Change this page in the same commit
as the code it describes.

What this page does **not** own:

| Topic | Page |
|---|---|
| What a reading, a window, a null, not-started or expired window, a reset and freshness mean; rule W | [quota-readings.md](quota-readings.md) |
| States, over quota, spend control as a state, the low-allowance shape | [state.md](state.md) |
| Percent left, the source tag, plan badge wording, every user string | [display-semantics.md](display-semantics.md) |
| Cadence, the 429 ladder, holds, `Retry-After`, the refusal record | [polling.md](polling.md) |
| Finding and reading `~/.codex/auth.json` (passive read, never written, never refreshed) | [credentials](credentials.md); [credentials and privacy](../credentials-and-privacy.md) and [decision 0001](../decisions/0001-never-refresh-a-token.md) |
| Credits and the monthly limit as a product | `credits-and-monthly-limits.md` (pending) |
| Codex session logs and its local databases as a source | `local-usage.md` (pending) |
| How readings, plan changes and the email are stored | [storage](storage.md) |

## Terms used here

| Term | Meaning on this page |
|---|---|
| **App-server** | The `codex app-server` child process Kvotar starts from the user's installed Codex and speaks newline-delimited JSON-RPC to over stdin and stdout. The primary transport |
| **Web fallback** | `GET https://chatgpt.com/backend-api/wham/usage`, called directly by Kvotar with the token from `~/.codex/auth.json` |
| **Transport** | Which of the two produced a reading (`QuotaSnapshot.source`: `.appServerRPC` or `.wham`) |
| **Placeholder reset** | A reset the provider computes as "now + width" on every request while no window has started |
| **Placeholder-shaped** | A window at 0 % used, with a known width, whose reset sits within 60 s of exactly one width from the time Kvotar asked (`isUnanchoredCandidate`) |
| **Raw anchor pair** | The previous poll's (time asked, reset reported) pair, kept by the adapter before it drops a placeholder reset (`lastRawAnchor`) |
| **Drift** | How much `reset − time asked` changed between the raw anchor pair and this poll |

## Two transports, one reading

**Each poll asks the app-server first and uses the web endpoint only if that fails.** Any app-server failure (missing binary, failed start, timeout, crash, RPC error, decode failure) falls through in the same poll. A poll takes its windows from one transport. (`CodexAccountAdapter.fetchQuotaSnapshotInner`; test
`CodexAccountAdapterTests.testRPCFailureFallsThroughToWham`) Reason: the app-server is local and needs no token from Kvotar; the web endpoint keeps numbers flowing when it breaks. Refusals are [polling.md](polling.md)'s.

**One exception: the monthly supplement.** If the app-server answers with both windows null, no
monthly limit, and a plan of exactly `enterprise` or `business` (case-insensitive), Kvotar also
calls the web endpoint and takes its monthly limit, spend-control flag, banked resets, credits
balance, rate-limit headers and (if the app-server had none) model allowances. Windows and plan
stay the app-server's; the reading's source becomes `.wham`. If the web call fails for any reason,
a 429 included, or carries no monthly limit, the app-server reading stands and the failure is only
logged. (`supplementMonthlyLimitIfNeeded`, `isPeriodQuotaPlan`, `mergeWhamSupplement`; test
`testRPCNullWindowSupplementsMonthlyLimitFromWham`) Reason: such accounts got window-less app-server replies without the monthly limit the web endpoint carried, which erased the monthly layout. See Decided 2.

**One poll has an 18 s budget** across both legs. Past it both legs are cancelled and the poll fails as an ordinary failure (health unknown). Inside it: app-server
start plus `initialize` 8 s, each app-server call 2 s, and the web request's 10 s idle timeout.
(`overallBudget`, `CodexRPCClient.init` defaults, `CodexURLSessionFetcher.init`; test
`testOverallBudgetBoundsSlowRPCPlusWham`)

**Health:** healthy after any success; a web failure maps to: 401 or 403 → re-auth
required; `auth.json` missing, or unusable ([credentials](credentials.md)) → setup required;
`auth.json` unreadable → unknown; 429 → rate-limited with the wait; anything else → unknown.
App-server failures never set health on their own. Codex has no credential-expiry gate and no
retry after a 401 or 403. (`CodexAccountAdapter.health(for:)`, `CodexWhamHTTPClient.checkStatus`)

## Finding and starting the app-server

**Discovery, first executable wins** (duplicates dropped, order kept):

1. Inside the app bundle that LaunchServices resolves for the bundle id `com.openai.codex`:
   `Contents/Resources/codex`, then `Contents/MacOS/codex`.
2. `/Applications/ChatGPT.app/Contents/Resources/codex`.
3. `/Applications/Codex.app/Contents/Resources/codex` (an older install).
4. `~/.local/bin/codex`, then `~/.codex/packages/standalone/current/bin/codex` (the standalone
   installer).
5. `/opt/homebrew/bin/codex`, then `/usr/local/bin/codex`.
6. `which codex`, run only when nothing above matched.

(`Packages/KvotarCore/Sources/KvotarCore/Adapters/CodexBinaryCandidates.swift`;
`DefaultCodexBinaryLocator.locate`; the bundle lookup is injected by `App/AppDelegate.swift`; tests
`CodexBinaryDiscoveryTests`) Reasons: the binary's path has moved more than once but the bundle id has not, and packages may not import LaunchServices, so the App target resolves it. The standalone paths are literal because a Finder-launched app's `PATH` contains none of them, which also makes `which` weak. `Contents/Frameworks` holds Electron helpers and is not searched. The diagnostics version line uses the same literal list, without the bundle lookup.

**A lookup result is cached for 300 s**, a miss included, and dropped whenever a start fails, so a
Codex update that moves the binary recovers without a relaunch. A miss is logged once per episode, with every path tried. (`CodexRPCClient.resolveBinary`; tests
`testClientCachesDiscoveryAcrossPolls`, `testMissingBinaryIsResolvedOncePerCooldown`) Reason: a lookup per poll spawned a process every two minutes and flooded the log.

**Launch arguments: `-s read-only -a never app-server`.** The sandbox is read-only and the child
never asks for approval. (`CodexProcessTransportLive.launchArguments`; test
`testLaunchArgumentsArePinned`) Reason: Kvotar only reads account data, so read-only cannot be escalated. Codex stopped accepting `-a untrusted` (every start then looked like a timeout); `never` works on old and new versions. The environment is inherited; stdin, stdout and stderr are pipes, and stderr is drained so it cannot stall the child.

**Handshake and poll.** On first use (the first poll, not at launch) Kvotar starts the child and
sends `initialize` with `clientInfo` `{"name": "Kvotar", "version": …}`. Each poll then sends `account/read`, then `account/rateLimits/read`, with empty params. Nothing else is sent. Today the version string is the literal `pre-alpha` (Known gaps).
(`CodexRPCClient.ensureStarted`, `poll`; test
`NoRefreshNetworkSeamTests.testAFullCycleSpeaksOnlyTheQuotaMethodsAndNeverSendsARefreshToken`)

**Persistent process.** The child stays up between polls. A line with an integer `id` resolves the
waiting call (an unknown id is dropped); a line with a `method` and no integer `id` is a
notification, logged at DEBUG and dropped; anything else is dropped. A child that exits fails every
waiting call, and the next poll restarts it and sends `initialize` again. After three start
failures in a row the client reports unavailable (so the poll goes to the web endpoint) until 300 s
after the last failure; then the count starts again, allowing up to three more tries. The child is
terminated when the app quits. A start failure logs one line of the child's stderr (the first non-empty line of its last 2 KB, at most 300 characters). (`handleLine`, `handleTransportClosed`, `restartCooldown`, `PollCoordinator.stop`; tests `CodexRPCClientTests`) Reason: one long-lived child is cheaper than a start per poll; correctness rests on the two reads, never on notifications.

**On the app-server path Kvotar sends no token;** the child uses its own sign-in ([credentials and privacy](../credentials-and-privacy.md#launching-codex)).

## The web fallback

**The request:** `GET https://chatgpt.com/backend-api/wham/usage` with
`Authorization: Bearer <access token>`, `ChatGPT-Account-Id: <account id>` when `auth.json` has
one, and `User-Agent: Kvotar/<version>`. No body and no other header set by Kvotar; an ephemeral
session, so nothing is kept on disk. The token is read fresh from `auth.json` on every call. (`CodexWhamHTTPClient.fetchUsage`,
`CodexURLSessionFetcher`; tests `NoRefreshNetworkSeamTests`,
`CodexWhamHTTPClientTests.testMissingCredentialIsSetupRequired`)

**Status handling:** 2xx decodes; 401 and 403 are re-auth required; 429 is rate-limited with
`Retry-After` (a missing header becomes 120 today, which [polling.md](polling.md) rules on); any
other status is an HTTP error. A 429 also builds the refusal record, with credential headers
dropped and the token redacted from the body (`checkStatus`, `forensicHeaders`, `redactedBody`;
tests `testPoll429UsesRetryAfter`, `testExpiredToken401`).

**`X-RateLimit-Limit`, `-Remaining` and `-Reset`** are read from the web response when present,
carried on the reading and stored with the poll. Absent headers are fine. (`parseRateLimitHeaders`; test
`testRateLimitHeadersCaptured`)

## From payload to reading

| Reading field | App-server (`account/rateLimits/read`, camelCase) | Web fallback (snake_case) |
|---|---|---|
| Primary used % | `rateLimits.primary.usedPercent` | `rate_limit.primary_window.used_percent` |
| Primary reset | `primary.resetsAt` (unix s), unless placeholder | `primary_window.reset_at` (unix s), unless placeholder |
| Primary width | `primary.windowDurationMins` × 60 | `primary_window.limit_window_seconds` |
| Secondary used %, reset, width | `secondary.…`, same keys and units | `secondary_window.…`, same keys and units |
| Over quota (`rateLimitReached`) | `rateLimitReachedType` is non-null; `nil` when both windows are null | `rate_limit.limit_reached` (missing = false); `nil` when `rate_limit` is null |
| Spend control reached | `rateLimits.spendControlReached` | `spend_control.reached` |
| Monthly limit | `rateLimits.individualLimit` | `spend_control.individual_limit` |
| Credits balance | `rateLimits.credits.balance` | `credits.balance` |
| Banked resets | not mapped (`nil`) | `rate_limit_reset_credits.available_count` |
| Model allowances | `rateLimitsByLimitId`, minus the main limit | `additional_rate_limits[]` |
| Email, plan | `account/read` `account.email`, `account.planType` (else `rateLimits.planType`) | `email`, `plan_type` |
| Extra usage | always `.disabled` | always `.disabled` |

(`CodexAccountAdapter.normalize(account:rateLimits:now:)`, `normalize(wham:headers:now:)`)

- **Widths are normalized to seconds** at the adapter, so both transports reach the same verdict. (Tests `testRPCSecondaryWindowWidthIsNormalizedToSeconds`, `testWhamSecondaryWindowWidthIsCarried`)
- **`resetsInSeconds` and `reset_after_seconds` are never read;** the absolute reset is used.
- **A null window stays null.** Both windows null, or `rate_limit: null`, is the healthy idle shape seen on Enterprise; not an error, not over quota
  ([quota readings](quota-readings.md#null-not-started-and-expired-windows)). (Tests
  `testHealthyNullWindowViaRPC`, `testHealthyNullWindowViaWham`)
- **Email and plan are cached** in the adapter and kept when a later poll omits them. A value from any source overwrites it (ruled otherwise: Decided 1). Logs write
  the email as `<redacted>`. (`mergeIdentity`, `logPoll`)
- **The monthly limit** keeps the provider's string amounts and remaining percent; an unparseable
  amount yields no monthly limit at all. (`monthlyLimit(from:)`; test `testMonthlyLimitUnparseableNumericsNormalizeToNil`)

**Only what the app acts on may fail a poll.** Strict: the windows and their three numbers (used %,
width, reset), the web `rate_limit` object and its `limit_reached`, the app-server's `rateLimits`
object, and `account/read`'s `account` object with its `type`, `email` and `planType` (a wrong type there fails the app-server poll, which falls through to the web). Every other field degrades to `nil` on an unexpected shape and the poll still lands.
`rate_limit_reached_type` / `rateLimitReachedType` is read as a string or as an object (its `type`)
on both transports. (tests `testUnexpectedShapesDegradeTheFieldNotThePoll`, `testWindowNumbersRemainStrict`, `testReachedTypeAcceptsStringObjectAndNull`) Reason: twice a secondary field changed shape and discarded every poll, once at the minute the user ran out. A wrong number is worse than none, so the numbers stay strict.

**A third over-quota signal: Codex's own goal database.** If `~/.codex/goals_1.sqlite` has any
`thread_goals` row with status `usage_limited`, the over-quota flag is set to true on either
transport, even on a null-window reading. It only ever turns the flag on; a missing file or table
reads as no signal. How the file is opened is `local-usage.md`'s (pending).
(`applyUsageLimitedSignal`, `CodexSQLiteMetadataReader.hasUsageLimitedGoal`; test
`testUsageLimitedGoalOverridesRateLimitReached`)

**The app-server's blocked shape has never been captured.** Reading a non-null `rateLimitReachedType` as over quota is a working assumption; the web blocked shape was captured and matches.

## Model allowances

**App-server:** every entry of `rateLimitsByLimitId` whose key and `limitId` differ from the main
`rateLimits.limitId`, sorted by key. **Web:** every `additional_rate_limits[]` entry in the
provider's order, windows from its nested `rate_limit` (flat pre-capture fields are a lenient
fallback). The id is the entry's `limitId` (else its key) on the app-server, and `metered_feature`
(else `limit_id`) on the web; the two are the same string, so an allowance keeps its identity
across a transport switch. Each window keeps its own used %, reset and width; a missing field
stays missing. (`additionalLimits`; tests `testRPCAndWhamAgreeOnSparkIdentityAndWindows`, `testRPCMissingModelWindowFieldsStayUnknown`, `testWhamOddModelEntryDegradesWithoutFailingThePoll`)

**Both windows of a model allowance get the two-clause placeholder test only** (below): 0 % used
and a reset one width out drops the reset and keeps the 0 %. No drift clause, because no reset
detection, notification or forecast reads a model window; the worst case is "not started" for one
poll at a real start. (`modelWindow`; test `testRPCSparkFiveHourAnchorSurvivesWhenNotPlaceholderShaped`)

## The placeholder reset

**The provider never says "not started".** While a Codex window is at 0 % used and has not begun,
both transports answer with `reset = time of request + window width`, recomputed on every request.
Taken at face value, every "did the reset move?" check fires: it once produced a reset notification and an invented window-reset row on almost every poll. A window begins with the user's first request, never with a quota read.

**The rule, applied to the main primary window on both transports.** The adapter drops the primary
reset, and keeps the used percent and the width, when all of these hold
(`CodexAccountAdapter.isUnanchoredWindow`):

1. Used percent is exactly 0, the width is known, and a reset is present.
2. The reset is within 60 s (`QuotaSnapshot.resetJitterTolerance`) of exactly one width after the
   time Kvotar asked.
3. **When the previous poll was placeholder-shaped:** drift is at most 5 s
   (`anchorDriftTolerance`). Drift = (previous reset − previous time asked) − (this reset − this
   time asked).

The result is the [not-started shape](quota-readings.md#not-started). The
main secondary window is never tested (see Known gaps). Rule W is ruled to apply to Codex and does
not yet: see [quota readings, Decided 1](quota-readings.md#decided).

**When the drift clause applies — exactly.** The raw anchor pair is recorded after every
normalized poll, from the payload as received, but **only if that reading was placeholder-shaped**
(clauses 1 and 2); otherwise it is cleared (`recordRawAnchor`). So the two-clause test alone
decides:

- on the first poll after launch (the pair is never stored across relaunches);
- after any poll that was not placeholder-shaped: a live window with a fixed reset, a poll above
  0 %, a null window, or a window without a width.

A failed poll does not touch the pair; one slot serves both transports, so a switch between them
keeps it; the monthly supplement does not touch it. (Tests `testFirstPollWithoutAPredecessorFallsBackToTwoClauses`, `testRealAnchorSurvivesTheWindowStart`, `testAnchorDriftToleranceBoundary`, `testUnanchoredToleranceBoundary`)

Reasons:

- **Why drift, not value.** A genuine start also looks like 0 % with a reset one width out, because the first turn's usage has not registered. But a placeholder's `reset − time asked` stays constant across polls, while a real reset's shrinks with the clock. It holds across a long sleep as well as one poll gap (test `testWithdrawnWindowStaysUnanchoredAcrossAnEightyNineMinuteGap`). A required extra clause can only make the rule fire less, so it cannot bring back the storm.
- **Why only a placeholder-shaped predecessor.** Drift only means something if the previous reading could have been a placeholder. Against a withdrawn live window, "drift" is hours, so the withdrawal would read as a new window and a false reset would be recorded. With the pair cleared, the withdrawal poll reads as not started, which the engine's withdrawn-window branch needs
  ([quota readings, Resets](quota-readings.md#resets); test
  `testLiveWindowThenWithdrawalReadsAnchoredThenUnanchored`).
- **The cost, accepted.** On the first poll after launch, or after a non-placeholder poll, a
  genuine start that began less than 60 s before the poll reads as not started for one poll; after
  a placeholder poll, so does one that began less than 5 s before the poll. The adapter keeps one
  pair of state.
- **Why at the adapter.** Reset detection and notifications read the raw reading, so only the
  adapter covers them, the forecast, the display and storage at once (test
  `testUnanchoredPollSequenceFiresNoResetNotifications`).

The rule reads neither plan nor tool; Claude's not-started shape comes from its own payload ([claude account](claude-account.md)).

## Plan types

**The plan is a raw string, never an enum,** stored and passed on as received
([PATTERNS.md](../../PATTERNS.md#naming-conventions-baseline-4)). New values appear without notice.
Sources: app-server `account/read` `account.planType`, else `rateLimits.planType`; web `plan_type`.

**No window rule reads the plan.** Windows come only from what the payload reports
([quota readings](quota-readings.md#limits-and-windows)). Reason: window sizes depend on the plan,
are not documented for all of them, and vary even within one plan: the tests and fixtures hold Go
with one 30-day window, Plus both with one 7-day window and with a five-hour plus a weekly window,
and `prolite` with one 7-day window plus a Spark model allowance.

Code that reads the plan:

| Reader | Effect | Owner |
|---|---|---|
| Monthly supplement gate (`enterprise`, `business`, case-insensitive) | Whether a window-less app-server reply also asks the web endpoint | This page (Decided 2) |
| `QuotaSnapshot.isLowAllowanceShape` | Rate-derived states off | [state.md](state.md) |
| `DisplayFormatter.planDisplayName` | The plan badge | `popover.md` (pending) |
| `DisplayFormatter.codexCreditsSpend` | The Codex credits and spend section (Enterprise only) | `credits-and-monthly-limits.md` (pending) |
| `DisplayFormatter.isOrganizationPlan` | "Organization pays" wording on the value note | `estimated-value.md` (pending) |
| `DiscontinuityDetector` (`plan_changed`, damped by `PlanChangeStability`) | Records a plan change; suppresses `early_reset` in that comparison | [quota-readings.md](quota-readings.md#resets), [storage](storage.md) |

`LimitsDatabaseAdapter` is keyed by plan too, but nothing in the app calls it at runtime today.

## Rejected alternatives

- **Restarting the app-server when the plan changes.** A long-running child once kept the old plan until it restarted; a relaunch heals it, and restarts would add routine churn.
- **Persisting the raw anchor pair across relaunches** to close the first-poll gap. The cost it
  removes is one poll.
- **A threshold on the reset's value.** Every such guard ended up comparing against the poll cadence; replaced by the drift test.

- **Reacting to app-server notifications.** None useful was ever seen.
- **The undocumented `account/usage/read` method.** Not called; per the record its token totals differ from Kvotar's.

## Known gaps

| Gap | Today | Proposed |
|---|---|---|
| `initialize` sends a fixed version | `CodexRPCClient` defaults `appVersion` to `pre-alpha`; `App/AppDelegate.swift` never passes the real one | Pass the bundle's short version, with a test on the sent line |
| A refused supplement call is invisible to polling | `supplementMonthlyLimitIfNeeded` swallows every error, a 429 included: no ladder rung, no hold, no refusal record, so a qualifying idle account keeps calling while refused | Decided 2: pass a supplement 429 to the coordinator as a refusal, or skip the supplement while a hold is pending; with a test. Lands before or with the gate change |
| Plan can flip between sources | `mergeIdentity` lets any source overwrite the cached plan | Decided 1: keep `account/read`'s plan once seen; other sources only fill an empty one; with a test |
| Cached identity is never cleared | `mergeIdentity` only ever sets `cachedEmail` and `cachedPlanType`; nothing in the adapter notices an account change | Decided 1: clear plan and email when the account changes, with a test |
| A plan label can hide credits | `DisplayFormatter.codexCreditsSpend` returns nothing unless the plan is exactly `enterprise`, so a `business` (or variant) account with credits data shows no credits section | Decided 1: decide the section from the data, not the plan string; with a test |
| Monthly supplement is gated on two plan strings | `isPeriodQuotaPlan` misses `enterprise_cbp_usage_based` and `self_serve_business_usage_based` | Decided 2: add both strings, with a test; after or with the refusal fix |
| Credits balance sent as a string reads as missing | `CodexCredits` decodes `balance` only as a number; captured fixtures send `"0"`, which becomes `nil` | Accept a numeric string too, with a fixture; settle its meaning on the credits page |
| The `usage_limited` signal has no time bound | Any such row, however old, sets over quota on every poll; whether Codex clears it is unverified | Check; if it can linger, bound it, for example to goals updated inside the current window |
| The main secondary window is never tested for a placeholder | `normalize` keeps `secondary.resetsAt` as sent, unlike model-allowance windows. No reason is recorded; no not-started main secondary has been captured | Apply the two-clause test to the main secondary, as for model windows, with a test |
| App-server path never carries banked resets | `rateLimitResetCredits` is in the app-server body but not decoded | Decode it, with the existing fixture |
| `account/read` decodes strictly | A wrong type in `account.email`, `planType` or `type` fails the app-server poll | Decode those fields leniently, like the rest |
| The supplemented reading is tagged `.wham` | Windows came from the app-server | Moot once display-semantics Decided 2 lands; otherwise tag by the windows' source |
| Stale code comments | `CodexRPCClient.ClientError.unavailable` promises a "Codex Desktop not installed" UI (withdrawn, never built). `CodexRPCClient.init` says one fresh restart attempt after the cooldown (the count resets). `CodexWhamSeams` says the headers serve "proactive slowdown" (deleted). `normalize(account:rateLimits:)` calls Enterprise the only validated plan | Fix with the next change to each file |

## Code and tests

| What | Where |
|---|---|
| Transport order, normalization, placeholder rule, monthly supplement, model allowances | `Packages/CodexAdapter/Sources/CodexAdapter/CodexAccountAdapter.swift` |
| App-server client, handshake, restarts, timeouts | `Packages/CodexAdapter/Sources/CodexAdapter/CodexRPCClient.swift`, `CodexRPCSeams.swift` (locator), `CodexProcessTransportLive.swift` (launch arguments) |
| Payload shapes and the decoding rule | `Packages/CodexAdapter/Sources/CodexAdapter/CodexRPCResponses.swift`, `CodexWhamResponses.swift` |
| Web request and status mapping | `Packages/CodexAdapter/Sources/CodexAdapter/CodexWhamHTTPClient.swift`, `CodexHTTPFetcher.swift` |
| Binary candidates | `Packages/KvotarCore/Sources/KvotarCore/Adapters/CodexBinaryCandidates.swift` |
| Wiring (bundle lookup, capture, adapter) | `App/AppDelegate.swift` |
| Tests | `Packages/CodexAdapter/Tests/CodexAdapterTests/`: `CodexAccountAdapterTests`, `CodexRPCClientTests`, `CodexWhamHTTPClientTests`, `CodexBinaryDiscoveryTests`, `NoRefreshNetworkSeamTests`; fixtures in `TestFixtures/` |

Checked against the code at a484769 + STEP_252
