---
summary: What Kvotar learns about the size of a quota window, and what it does with it today — the bundled community limit table and its fallbacks, the quota 429 rows recorded from session logs and their 50 % floor, the personal observed ceiling (all built, none read by the app), and the work-per-1% series the History window reads.
read_when: Changing LimitsDatabaseAdapter (loadOnLaunch, ceiling, resolveCeiling, quotaCeilingObservationFloorPct, the hardcoded prior), LimitsModels (LimitsSeed, QuotaCeiling, ConfidenceTier, WindowType), the bundled limits.json; SQLiteStore+QuotaLimitEvents (writeQuotaLimitEvent, readQuotaLimitUtilizations) or what a quota_limit_events row holds; Quota429Observation or LocalDeltaSignal.quota429Observations; WorkPerPercentSeries or HistoryReportReader.workPerPercentSeries; or wiring any of these into a state, forecast, notification or user copy.
---

# Capacity learning

## Questions for owner

None.

## About this page

This page is the specification for what Kvotar learns about how big a quota window is: the
community limit table, the quota 429s seen in session logs, the personal observed ceiling, and the
work-per-1% series. It replaces the private Implementation Baseline §9.4 (Quota 429 —
self-learning ceiling), the limits-database rows of its component table (§10), and the limits
parts of §11.1 (Forecast tiers: the retired Inferred-runway tier) and of §6.5 (Canonical
data-source architecture), which are kept as history. It also replaces the series part of the
private quota-change detection record ("Work per 1 % of window"). Change this page in the same
commit as the code it describes.

IDs such as REV-nn or STEP_nnn in code comments are private record IDs;
[REFERENCES.md](../REFERENCES.md) explains them. The rules here stand without them.

What this page does **not** own:

| Topic | Page |
|---|---|
| When and where a quota 429 is written, how it differs from Kvotar's own refused poll, and that it can trip the session-start poll | [Polling](polling.md#a-refused-poll-is-not-an-exhausted-quota) |
| The `quota_limit_events` table's retention and the `v11` cleanup as a storage exception | [Storage](storage.md#permanent-means-permanent) |
| What a window, a reading and used percent mean | [Quota readings](quota-readings.md#limits-and-windows) |
| Finding and parsing session logs, the backfill, token counting | `local-usage.md` (pending) |
| Pricing and the [Est. token value](product-scope.md#terms-a-newcomer-needs) the series is built from | `estimated-value.md` (pending) |
| Burn, runway and pace (no ceiling enters them) | `forecast.md` (pending) |
| How the History window shows the series | `history.md` (pending) |
| The notification for a window added, removed or resized | `notifications.md` (pending) |
| The Codex plan string the table is keyed by | [Codex account](codex-account.md#plan-types) |

## Why this exists

Providers report used percent and a reset time, never how much work a window holds
([quota readings](quota-readings.md#limits-and-windows)). Two ideas tried to learn the size
anyway: a ceiling (the used percent at which a window actually stops the user) and a rate (how
much local work moves a window by one percent). The first is dormant; the second is live as
evidence only.

## Dormant today

**Nothing in the app reads a ceiling.** Say so in any change that touches this code.

- **No runtime caller of `LimitsDatabaseAdapter`.** The app does not load the seed at launch; its
  only consumer, the Inferred-runway forecast tier, was retired, and the forecast engine takes no
  limits input. The adapter stays in Core for the resolver and its tests.
  (`App/AppDelegate.swift` launch comment; `ForecastEngine.init` doc; no other caller outside
  `LimitsDatabaseAdapterTests`)
- **No reader of `quota_limit_events`.** `readQuotaLimitUtilizations` is called only by tests,
  and nothing in the app or the CLI interprets the rows. The CLI's `kvotar import` copies the table,
  with every other table of a saved bundle, into its separate analysis database, and the
  [saved bundle](diagnostics.md#save-diagnostics) carries it only as part of the whole-database
  copy (extended diagnostics capture on). Copied, interpreted by nothing.
  (`SQLiteStore+QuotaLimitEvents.swift`; `AnalysisStore` in `Packages/KvotarCLI`; tests
  `SQLiteStoreQuotaLimitEventsTests`,
  `SQLiteStorePollHealthTests.testReadQuotaLimitUtilizationsFiltersByToolWindowAndPlan`)
- **Quota 429 rows are still written**, and never used. Polling owns when
  ([polling](polling.md#a-refused-poll-is-not-an-exhausted-quota)).

The maintainer ruled on 2026-10-04 that this code stays dormant: whether to keep, wire or remove
it is decided later, and wiring needs a real quota 429 capture first (see Known gaps). The rules below describe what the
code does when called, so a later step starts from the truth.

## The community limit table

**What it is.** A table of window ceilings, as a used percent, per tool, plan and window
(`five_hour`, `weekly`). It was meant as the fallback when a live reading is missing.
(`LimitsSeed`, `LimitsSeed.WindowCeilings`, `QuotaCeiling`)

**Where values come from, in order** (`LimitsDatabaseAdapter.loadOnLaunch`):

1. **A remote file.** A stub: it logs that no remote is configured and returns nothing. It never
   makes a network request. (`fetchRemote`)
2. **The bundled seed**, `Packages/KvotarCore/Sources/KvotarCore/Resources/limits.json`, inside the
   Core package. (`loadBundledSeed`; test `testLoadsBundledSeed`)
3. **A hardcoded prior** in Swift, used when the bundled file is missing or does not decode.
   (`hardcodedPrior`; test `testFallsBackToHardcodedPriorWhenBundleMissingSeed`)

The result is cached once per adapter; a second load does nothing (test `testLoadIsIdempotent`).

**Every value today is 100** — "the window stops at 100 % used". The seed and the prior hold the
same plans (Claude `max`, `pro`; Codex `pro`, `plus`) with 100 for both windows, and any plan not
listed gets 100 too (`hardcodedWindowCeilings`). So the table holds no observed figure yet.

**A lookup is tagged with where it came from.** `ceiling(tool:planType:window:)` returns
`community` when the cached seed came from the remote or the bundle and lists the plan, and
`hardcodedPrior` otherwise, including before a load. The plan key is the raw provider string,
never an enum ([PATTERNS.md](../../PATTERNS.md#naming-conventions-baseline-4)). (Tests
`testCeilingReturnsCommunityTierForKnownPlan`, `testCeilingFallsBackToHardcodedPriorForUnknownPlan`)

## The quota 429 row

A `quota_limit_events` row is one moment the **user's** Claude Code or Codex session was refused
for a usage limit, seen in that tool's session log, together with how much of the window was used
at the time. Its purpose is to be the input to the personal ceiling. It is never Kvotar's own
refused poll ([polling](polling.md#a-refused-poll-is-not-an-exhausted-quota)).

**What a row holds:** tool, the moment (for Claude, the log line's time, falling back to when
Kvotar read the line; for Codex, always when Kvotar read it, because its error line carries no
time Kvotar parses), the used percent, a window type, the session file's
**base name** only, and the plan string (empty when the reading had none). The same tool, file and
moment are stored once; for Codex that moment is the read time, so the key cannot tell one
refusal read twice from two refusals read in the same second. (`writeQuotaLimitEvent`, `INSERT OR IGNORE`; migration `v1` unique key;
test `testDuplicateObservationIgnored`)

**The detector is a guess.** No real quota 429 line from either tool has been captured. A Claude
line counts when it is flagged as an API error; a Codex line when it is an error event; and in
both, the raw line mentions a usage or rate limit, "limit reached", 429 or 529. The scan runs on
the raw line so the message is never decoded. A server overload or a non-quota limit therefore
counts too. (`Quota429Observation.lineContainsQuotaLimitMarker`; the parsers' `detectQuota429`;
tests `BurnTierTrackerTests.testQuotaLimitMarkerMatches`,
`testQuotaLimitMarkerRejectsOrdinaryErrors`) How the parsers read the logs is `local-usage.md`'s
(pending).

**The used percent comes from the last successful poll of this launch**, the primary window's.
Reason: the log line carries no used percent. Without such a poll nothing is recorded, because a
row without the percent would be meaningless as a ceiling. (`PollCoordinator.writeQuota429Events`;
when it is written: [polling](polling.md#a-refused-poll-is-not-an-exhausted-quota))

**The backfill never records quota 429s.** It would pair a past refusal with today's used percent.
(`JSONLBackfillReader` type doc; test
`ClaudeLocalAdapterBackfillTests.testBackfillEmitsNoDeltaSignalsAndQueuesNoQuota429s`)

### The 50 % observation floor

**A row below 50 % used is not written**; the discard is logged with the value and the file's base
name. Reason: a refusal at 5 % cannot be a window running out, the detector already marks lines it
should not, the resolver takes the *minimum*, and the table is permanent. Together, one bad row
would pin the ceiling forever. That happened once: a single false low row among readings near
100 % became the learned ceiling.
(`LimitsDatabaseAdapter.quotaCeilingObservationFloorPct`, checked in
`SQLiteStore.writeQuotaLimitEvent`, the one write path; tests `testCeilingObservationFloorIsFifty`,
`testFloorDiscardsImplausibleObservations`, `testFloorAcceptsPlausibleObservations`)

**Why 50.** The false readings seen sat far below half, the real ones near 100 %; 50 is the round
number furthest from both groups. Cost: a plan whose real ceiling is under 50 % would never be learned. It is
tunable, but from real quota 429 evidence, not by lowering it to admit unexplained low readings.

**Keep the floor and the minimum together.** The minimum is safe only because the floor guards the
write. Relaxing the floor reopens the defect in the resolver, not at the write.

**Rows written before the floor** were deleted once by migration `v11_quota_ceiling_floor`, against
the literal 50.0, so tuning the constant never changes what that migration did. That deletion as a
storage exception is [storage](storage.md#permanent-means-permanent)'s. (Test
`testV11MigrationDeletesSubFloorRows`)

## The personal ceiling

**What it is.** The lowest used percent at which a quota 429 was recorded, for one tool, window
type and plan. (`LimitsDatabaseAdapter.resolveCeiling`, pure)

- **Three observations or more:** the personal ceiling wins over the community value.
- **Fewer than three:** the community value is used. Reason: one or two refusals are too little
  to override the table. (Tests `testResolveCeilingUsesCommunityBelowThreeObservations`,
  `testResolveCeilingUsesLowestPersonalAtThreeOrMore`, `testResolveCeilingEmptyObservations`,
  `testResolveCeilingAfterSubFloorCleanupUsesSurvivingMinimum`,
  `testResolveCeilingFallsBackToCommunityWhenCleanupDropsBelowThree`)
- **A plan change starts over** without deleting anything: the reader filters by the current plan
  string. (`readQuotaLimitUtilizations`; tests `testReadFiltersByPlanType`,
  `SQLiteStorePollHealthTests.testReadQuotaLimitUtilizationsFiltersByToolWindowAndPlan`)

None of this runs in the app today ([Dormant today](#dormant-today)). The ceiling was once meant
to tighten the at-risk warning; that was never built, and the at-risk rule uses fixed values
([state](state.md)).

## The work-per-1% series

**What it is for.** A provider can shrink a window without saying so, and the reading cannot show
it: the same work just uses more percent. The series measures, per window cycle, how much local
work moved the window by one percent. A real shrink shows as a step down that moves every model
together. It is **evidence, not a verdict**: no threshold, no state, no notice reads it.
(`WorkPerPercentSeries` type doc)

**Inputs, read only:** the hourly poll summaries (`history_rollups`) and the hourly local token
totals per model, priced through the History reader's one pricing engine, joined by UTC hour; plus
the `discontinuity_events` of seven kinds as timeline markers (window added, removed, resized,
early reset, withdrawn, monthly limit changed, plan changed). The period starts at the later of the
report start and the first polling evidence. The newest hours (up to about two) are not
summarised yet, so the series lags by that much. (`HistoryReportReader.workPerPercentSeries`,
`markerEventTypes`; test
`HistoryReportReaderTests.testWorkPerPercentSeriesIsPopulatedFromRollupsLocalWorkAndMarkers`)

**How a point is computed** (`WorkPerPercentSeries.compute`, pure):

- **A sample is the interval between two consecutive summary rows of one cycle**, not an hour.
  Its rise is how far the hour's highest used percent passed the running high-water mark (never
  negative); its work is every hour of local work in between. Reason: the summaries have gaps (the
  app was not running) while the local record is complete, so an hourly join would pile a gap's
  rise onto one hour. (Tests `testSingleCycleRiseAndDollarsPerPercent`,
  `testGapBetweenRollupRowsCarriesEveryHoursWork`)
- **A cycle's first row only seeds the mark.** That drops the hour holding a reset, which mixes
  two cycles and cannot be split at this grain. Two reset times within 60 s are one cycle. A row
  where the window is null is skipped. (Tests
  `testResetInsideAnHourSplitsCyclesAndDropsTheBoundaryInterval`,
  `testAnchorJitterWithinToleranceIsOneCycle`, `testNullSlotRowsAreSkippedNotCounted`)
- **Per model:** an interval where one model holds at least 90 % of the priced work gives its whole
  rise to that model; mixed intervals count only toward the all-models rate. `coverage` is the
  share of the rise the per-model rates stand on. (`dominantShare`; test
  `testDominantIntervalAttributionAndCoverage`)
- **Unexplained share:** the share of the rise in intervals with no local work, and none in the
  hour before (session logs land after the request). That rise came from somewhere this Mac cannot
  see. (Test `testUnexplainedShareCountsRiseWithNoLocalWorkInIntervalOrHourBefore`)
- **Cross-window ratio:** the weekly rise over the primary rise across the same span, when both
  moved. (Test `testCrossWindowRatioIsWeeklyOverFiveHour`)
- **Each point** carries the rise, the Est. token value of the work and its tokens, the per-model
  rates, the two shares and the ratio; value per 1 % and tokens per 1 % are derived from them.
- **Grouping:** windows shorter than a day (Claude's five-hour) are regrouped per local calendar
  day; longer ones stay one point per cycle. A cycle is complete when its reset has passed or a
  later cycle replaced it; a day point, when the day has ended. Claude's primary width is five hours; Codex's is the width the latest
  reading reports, and none if it has none. (Tests `testFiveHourCyclesRollUpPerLocalDay`,
  `testCodexWidthIsTheReportedOneAndSupersededCyclesAreComplete`,
  `testCodexWithoutAReportedWidthHasNone`, `testMarkersPassThroughSorted`)

Fixtures pin the three stories the series must tell apart: every model steps together, one model
steps, and a drop that is only unexplained use. (Tests `testRateStepAllModels`,
`testRateStepOneModel`, `testRateStepUnexplained`)

**Who reads it.** Only the History window, through `HistoryReport.ToolReport.workPerPercent`; which
cycles it shows and how is `history.md`'s (pending). **No notice reads the series**, and no copy
says the allowance shrank. A window that is added, removed or resized is a recorded fact with its
own notification, which does not use this series (`notifications.md`, pending).

## Rejected alternatives

- **Raw tokens per 1 % as the signal.** Cannot tell a change of model or cache mix from a cut; it
  stays on each point as a secondary figure.
- **A least-squares fit for the per-model rates.** Fits on this data were unstable; the
  dominant-interval rule replaced it.
- **A verdict that states a new window size.** The provider never reports one; copy never states
  a size.
- **A notice before the series has been seen flat.** Wrongly accusing a provider is the failure
  the series exists to avoid; the notice was never built.
- **Reading other sites' limit pages.** Not done; the series uses only this Mac's records.
- **Taking the minimum of every recorded refusal with no floor.** One false low reading pinned
  the ceiling; the floor and the `v11` cleanup replaced it.

## Known gaps

| Gap | Today | Proposed fix |
|---|---|---|
| The ceiling is dormant | Seed, resolver and quota 429 rows are built and tested; nothing in the app reads them, and the rows keep being written | Deferred by the maintainer's ruling (2026-10-04). Later choose: keep as is (no work, rows keep piling up), wire it (only after a real quota 429 capture from each tool), or remove the adapter, seed and write path (table and rows stay) |
| [Polling](polling.md#a-refused-poll-is-not-an-exhausted-quota) misdescribes the quota 429 row twice | The "Effect" row of its "Poll refusal vs Quota 429" table says a quota 429 "feeds the learned ceiling", a consumer that does not exist; the bullet below the table says the row needs a poll "that carried a five-hour used percent", but the code takes the primary window's used percent whatever its width | A follow-up step changes that cell to "Recorded; nothing reads it today (see [capacity learning](capacity-learning.md#dormant-today)); no cadence change (it can trip the session-start poll)", and in the bullet changes "a five-hour used percent" to "a used percent for the primary window" |
| Every row is labelled five-hour | `writeQuota429Events` writes `five_hour` with the primary window's used percent, whatever that window is. On a Codex account whose primary is seven days or 30 days the label is wrong. The log line has no window | Before any wiring: store the primary's width (or name it by width, as [quota readings](quota-readings.md#limits-and-windows) does), or record nothing when the primary is not five hours |
| The detector is unverified | Any rate-limit-shaped error line counts; a server overload is recorded as a limit | Capture a real quota 429 line from each tool, then narrow `lineContainsQuotaLimitMarker` with fixtures |
| The table holds no observed value | Every entry is 100, yet a bundled hit is tagged `community`; the adapter doc calls the seed "community-observed values" | Settle with the deferred keep / wire / remove choice; if kept, fix the doc and tag |
| Stale code comments | `LimitsDatabaseAdapter` type doc and `SQLiteStore+QuotaLimitEvents.swift` header say `ForecastEngine` feeds or reads the ceiling; `LimitsDatabaseAdapter` and `LimitsSeed` tie the remote stub to a release stage; `PATTERNS.md` says the adapter is "read by `ForecastEngine`"; the `LocalDeltaSignal.quota429Observations` doc says it "feeds" the table as if the table were used; `WorkPerPercentSeries` says "the notice that reads it is a later, gated step"; the `PollCoordinator.writeQuota429Events` doc calls the table "the self-learning ceiling's input"; a `SQLiteStoreQuotaLimitEventsTests` header comment names a reader "that feeds `resolveCeiling`". [Storage](storage.md#permanent-means-permanent)'s `v11` row reads as if the learned ceiling were live | Fix with the next change to each file; `PATTERNS.md` with its next edit; the storage row in the same follow-up as the polling correction |

## Code and tests

Under `Packages/KvotarCore/Sources/KvotarCore/`: `Limits/LimitsDatabaseAdapter.swift`,
`Limits/LimitsModels.swift`, the seed (named above), `Storage/SQLiteStore+QuotaLimitEvents.swift`,
`Storage/SQLiteStore+Migrations.swift` (`v1` table, `v11_quota_ceiling_floor`),
`Adapters/LocalAdapter.swift` (`LocalDeltaSignal.quota429Observations`, `Quota429Observation`),
`Adapters/JSONLBackfillReader.swift`, `History/WorkPerPercentSeries.swift`,
`History/HistoryReportReader.swift` (`workPerPercentSeries`), `History/HistoryReport.swift`
(`workPerPercent`). Detectors: `ClaudeJSONLParser.detectQuota429`,
`CodexJSONLParser.detectQuota429`. The write: `App/PollCoordinator.swift`
(`writeQuota429Events`). The launch comment: `App/AppDelegate.swift`.

Tests in `Packages/KvotarCore/Tests/KvotarCoreTests/`: `LimitsDatabaseAdapterTests`,
`SQLiteStoreQuotaLimitEventsTests`, `SQLiteStorePollHealthTests` (the two
`readQuotaLimitUtilizations` tests), `WorkPerPercentSeriesTests`, `HistoryReportReaderTests`,
`BurnTierTrackerTests` (the marker); in the adapters, `ClaudeLocalAdapterWatcherTests` and
`CodexLocalAdapterWatcherTests` (`testQuota429ObservationEmittedFromTokenlessFlush`) and
`ClaudeLocalAdapterBackfillTests`.

Checked against the code at c824a6e + STEP_262
