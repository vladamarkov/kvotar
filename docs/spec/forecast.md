---
summary: How Kvotar estimates a quota window's future — the burn buffer and what it may claim, cold start, the forecast tiers, the runway per tool, the blended rate behind Claude's five-hour runway, the pace clock and its 2 % grace, the poll-pair deltas, the shadow outputs and the forecast log that records them for grading.
read_when: Changing ForecastEngine, Forecast, ForecastTier, ShadowForecast, ShadowPolicy, ShadowTables, ShadowTablesReader, ForecastLogRecorder or ForecastLogEntry; QuotaSnapshot.paceExceeded / paceElapsedPct / paceGraceFraction / primaryWindowLength, or the elapsed share longLimitAssessments computes for a weekly; BurnTierTracker; SQLiteStore.writeForecastLog / forecastLogWindowExposure / readForecastSeedSamples; the forecast, shadow-table and forecast_log wiring in App/PollCoordinator.swift; how burn, runway or pace is measured.
---

# Forecast

## Questions for owner

None.

## Decided

The maintainer ruled on this on 2026-10-04 (STEP_265). The code does not follow it yet; it has a
row in *Known gaps* below, which a later contract closes.

1. **Delete the partial-average flag.** Remove `Forecast.isEstimate` and the comments that describe
   a `~est.` label for it. Reason: no surface draws it, and the popover's own evidence gate already
   hides an early rate. Today the flag is true for 2–9 buffered samples, and its only reader is a
   fallback for test fixtures that carry no burn span (`DisplayFormatter.burnHasDisplayEvidence`).

## About this page

This page is the specification for window forecasts: what Kvotar measures about how fast a quota
window is being used, and what it may conclude from that. It replaces the private Implementation
Baseline §11 (Forecast engine baseline) with §11.1 (Forecast tiers), §11.2 (Claude full runway),
§11.2a (Burn resolution), §11.3 (Codex full runway for windowed plans) — except the long-limit
tier table, which [state](state.md#long-limits-as-states) already replaced — §11.4 (Cold start
behaviour) and §11.5 (Shadow outputs), and the private UI Spec §3 and Part 2 §3 (Runway
calculation) and the data parts of §0.4 and §2.2a (the runway verdict). Change this page in the
same commit as the code it describes.

IDs such as REV-nn or STEP_nnn in code comments are private record IDs;
[REFERENCES.md](../REFERENCES.md) explains them. The rules here stand without them.

What this page does **not** own:

| Topic | Page |
|---|---|
| What a reading, a window, a width, a reset and staleness mean; the five-hour and seven-day fallbacks | [Quota readings](quota-readings.md) |
| The states that read the runway, the pace clock and the deltas; their thresholds; the long-limit tiers (`LongLimitAssessment`) | [State](state.md) |
| When polls happen, including the session-start poll a burn-tier crossing can trigger | [Polling](polling.md#extra-polls) |
| The `forecast_log` table's place in the database and its retention | [Storage](storage.md) |
| Percent left, rounding, the runway's number form | [Display semantics](display-semantics.md) |
| The verdict's words, the burn figure and its display gate, the verdict's anatomy, the menu-bar runway slot | [account summary](account-summary.md), [explanations](explanations.md), [menu bar](menu-bar.md) |
| Which notifications use the runway or a delta | [notifications](notifications.md) |
| The monthly spend rate and the monthly forecast | [Credits and monthly limits](credits-and-monthly-limits.md) |
| The off-machine (Elsewhere) estimate | [Local usage](local-usage.md) |
| The personal observed ceiling; it does not feed the forecast | [Capacity learning](capacity-learning.md) |
| Which windows count as completed and observed (`QuotaWindowOutcomes`) | [History window](history.md) |

## What is forecast

The engine forecasts **one window per tool: the primary window**, whatever its width — a
five-hour window, or a seven-day primary on a weekly-only Codex plan. A secondary (weekly) window
gets no burn rate and no runway; it gets only the pace clock's elapsed share, which the long-limit
tiers on [state](state.md#long-limits-as-states) read (see *The pace clock*). The monthly pool has
its own rate, owned by [credits and monthly limits](credits-and-monthly-limits.md).

The engine is a pure reporter: it records samples and returns a `Forecast`. It never polls, never
writes to the database and holds no app state. (`Forecast/ForecastEngine.swift`: `ForecastEngine`)

Every reader takes the same `Forecast` value, so the state engine, the popover, the menu bar, the
notifications and the forecast log move together when the rate changes.

## The burn buffer

A **sample** is one successful poll's primary used percent and its time. Each tool has its own
buffer, in memory, oldest first. A poll with no primary used percent (a null window) adds no sample.
(`ForecastEngine.record`; test `ForecastEngineTests.testNullWindowPollDoesNotPolluteBuffer`,
`testBuffersAreIndependentPerTool`)

**The burn rate is a two-point rate:** the rise from the oldest to the newest sample, divided by
the time between them, in percentage points per minute. A fall clamps to 0. It is `nil` with fewer
than two samples or a zero span. (`ForecastEngine.burnRatePerMin`)

**A zero rise is unknown, not zero, until it spans the zero-proof.** Both providers report used
percent in whole points, so a flat reading over *T* minutes only bounds the burn below one point
per *T*. A flat span shorter than the proof gives `nil`; at or past it, a measured 0; any rise gives
a rate at any span. Reason: zero is a claim (the popover's calm verdict rests on it), and a short flat span can hide
a steady burn that has not yet moved the whole-point reading. Unknown burn is never shown as calm. (`ForecastEngine.zeroBurnResolvableSpan`; tests
`testFlatShortSpanReportsUnknownBurnNotZero`, `testFlatLongSpanEarnsZeroBurn`,
`testAnyRiseIsReportedRegardlessOfSpan`)

**Samples age out one by one after an hour; a gap never wipes the buffer.** Every `record` call
first drops samples older than `sampleMaxAge` (3,600 s), including a call for a null-window poll.
A short gap (a missed poll, a short sleep) keeps its anchor, because the account's rise across a gap
is exact and the window burns in wall time whether or not the app watched. An overnight gap ages
everything out to a cold start. The sweep runs before the null-window check because ageing by
windowed polls instead of by time once froze the buffer and re-served one old rate for over an
hour. (`sampleMaxAge`; tests `testShortSleepGapKeepsAnchor`, `testSamplesOlderThanMaxAgeAreDropped`,
`testNullWindowRunAgesTheBufferOut`, `testShortNullRunKeepsTheBuffer`) The sweep runs only in
`record`: `forecast(for:)`, which the local-change and poll-failure paths call without a new
sample, reads the buffer as it is, so between polls it can hold samples past the hour.

**The buffer is cleared when the window changes:** when the used percent falls, or when the
reset moves later by more than 60 s. Those samples belong to another window. It is also cleared
when, after a live success, the app first switches to the stale render, so stale samples never seed
the rate after recovery. After a launch the restore has already registered the stale render, so a
run of failed polls before the first success never clears the seeded buffer (see *Rows by
evaluation path*).
(`ForecastEngine.record`, `reset(tool:)`; `PollCoordinator.evaluateStaleness`; tests
`testWindowResetClearsBufferAndRestartsCleanly`, `testResetsAtAdvanceClearsBuffer`,
`testResetsAtJitterDoesNotClearBuffer`, `testResetClearsBufferForTool`)

**How much the buffer keeps depends on the window's width.** One point of a week is a much larger
claim than one point of five hours, so a window of a day or wider (`longWindowFrom`, 86,400 s)
keeps an hour of evidence. The trim drops the oldest sample only while the buffer is over its count
cap **and** what stays still spans the retention floor, so the cap can never make a zero
unprovable. (`ForecastEngine.bufferPolicy(windowLength:)`, `BufferPolicy`)

| Window width | Count cap | Zero-proof span | Retention floor |
|---|---|---|---|
| Under one day (`shortWindowBuffer`) | 10 | 600 s | 660 s |
| One day or wider (`longWindowBuffer`) | 60 | 3,000 s | 3,060 s |

- The width is `QuotaSnapshot.primaryWindowLength` (reported width, else five hours). A width that
  changes is re-capped on the next poll. (`testWidthChangeRecapsTheBufferOnTheNextPoll`)
- At the 120 s base cadence ([polling](polling.md#the-base-cadence)) the short buffer holds 10
  samples, about 18 minutes; code and this page call its rate **the 18-minute rate**. A flat
  meter still proves zero after about ten minutes, because the proof is a span rule.
  (`testBufferCapsAtTenSamplesAtTwoMinuteCadence`, `testFlatMeterProvesZeroBurnAtBaseCadence`)
- The long zero-proof is 3,000 s, not 3,600 s: ageing at 3,600 s means the span can never quite
  reach an hour, so a 3,600 s proof would leave an idle weekly unresolved forever. A flat 50
  minutes bounds a weekly's burn below about twice its even pace, not strictly at zero; that weaker
  zero reaches only the burn figure, because a long window's popover header uses the pace clock.
  (`testWeeklyBufferSpansTheProofAtEveryLegalCadence`, `testWeeklyFlatSpanOverTheProofEarnsZeroBurn`)

**At launch the buffer is seeded from the last hour of saved polls.** `PollCoordinator` reads the
`poll_snapshots` rows with a primary used percent from the last `seedLookback` (= `sampleMaxAge`),
and `seed` replays them through the same ageing, clearing and trim rules; future and expired rows
are rejected. Reason: a restart must not throw away valid evidence. The launch-restored reading
itself stays stale ([quota readings](quota-readings.md#fresh-and-stale-readings)).
(`ForecastEngine.seed`; `SQLiteStore.readForecastSeedSamples`;
`PollCoordinator.restorePersistedSnapshots`; tests `testSeedRestoresRecentSameWindowEvidence`,
`testSeedKeepsOnlyThePostResetSegment`, `testSeedRejectsExpiredAndFutureRows`)

## Cold start and the forecast tiers

`pollCount` is the number of samples in the buffer now, not the number of polls since launch, so
ageing, clearing and null-window polls all lower or hold it.

| Samples | Phase | What the forecast carries |
|---|---|---|
| 0–1 | Cold start | No burn rate, no runway. The pace clock still works (see *The pace clock*); how the popover words this is the [account summary](account-summary.md#verdict-lines-outside-the-monthly-family)'s |
| 2–9 | Partial | A rate and a runway where they resolve; `isEstimate` is true (to be deleted, Decided 1) |
| 10 or more | Full | Same formula; `isEstimate` false. The engine logs "Burn rate fully initialised" once |

The thresholds are the same on every width: what the buffer holds is the width policy's business,
how many samples make an average is not. (`ForecastEngine.bufferSize`; tests
`testColdStartZeroToOnePollShowsNoRunway`, `testTwoToNinePollsMarkedEstimate`,
`testTenPollsRemovesEstimateLabel`, `testEstimateLabelStillClearsAtTenPollsOnAWeeklyWindow`)

With fewer than two samples no rate-derived state can fire; which states still can is on
[state](state.md#what-is-not-inferred-from-incomplete-evidence).

`ForecastTier` says which kind of forecast the reading supports. It is chosen from the reading,
not set by the user. (`Forecast/Forecast.swift`: `ForecastTier`)

| Tier | When `forecast(for:)` returns it |
|---|---|
| `fullRunway` | A populated primary window with a used percent, not the low-allowance shape — including cold start and near-zero burn, where the runway is still `nil` |
| `creditBased` | A null primary window. No rate, no runway |
| `unknown` | The low-allowance shape, or no primary used percent; also the hand-built placeholders on the launch-restore path and when no cached reading exists |

Only `fullRunway` is read today: the money glyph's time-to-100 % needs it (`MoneyModel.etaTo100Minutes` in `State/MoneyState.swift`,
[credits and monthly limits](credits-and-monthly-limits.md)). Nothing tells `creditBased` from `unknown` (Known gaps).

## Runway

```text
runway_minutes = (100 − primary used %) ÷ rate
```

`rate` is `Forecast.burnRatePerMin`, chosen per tool below. The runway is `nil` whenever the rate
is `nil` or at most `nearZeroBurnPerMin` (0.001 %/min): a near-zero burn means the reset comes
first, and a runway would be meaningless. It is never negative. (`ForecastEngine.forecast(for:)`;
tests `ForecastEngineTests.testNearZeroBurnSuppressesRunway`, `testNullWindowSuspendsRunway`)

| Reading | Rate the runway divides by |
|---|---|
| Claude, primary narrower than a day | The blended rate (next section), or the 18-minute rate where the blend has no value |
| Codex, primary narrower than a day | The 18-minute rate |
| Any primary of a day or wider (a weekly-only Codex plan) | The buffer's rate under the long policy. The blend never applies |
| Null primary window | None: no rate, no runway (tier `creditBased`) |
| Codex low-allowance shape (defined on [state](state.md#what-is-not-inferred-from-incomplete-evidence)) | None: no rate, no runway, even with a full buffer. Samples keep landing; only the output is suppressed |

Why the low-allowance shape has no rate: one turn can move that meter by a fifth of the allowance,
so any average describes nothing that will happen next. (`QuotaSnapshot.isLowAllowanceShape`;
`LowAllowanceShapeTests.testForecastProducesNoBurnAndNoRunwayOnTheShape`)

Two more numbers ride on the `Forecast`:

- `burnSpanMinutes` — the time span of the rate actually used: the buffer's span when the chosen
  rate equals the 18-minute rate (including a blend that comes out equal to it), the trailing
  hour's otherwise. `nil` wherever the rate is. The verdict
  anatomy labels its burn row with it. (`testForecastCarriesTheBurnSpanItWasMeasuredOver`,
  `testForecastBurnSpanIsNilWhereverBurnIs`; `BlendDrivesRateTests.testSpanIsTheHourRingsWhenBlended`)
- `shortBurnRatePerMin` — always the 18-minute rate, whichever rate was used. Only the forecast log
  reads it.

The runway's readers: At risk and Elevated on [state](state.md#the-states); the exhaustion
decision shared by the popover and the menu bar (`DisplayFormatter.exhaustionRunwayMinutes`, which
also needs the pace clock — [account summary](account-summary.md#verdict-lines-outside-the-monthly-family)); the At-risk notification and its re-arm
([notifications](notifications.md)). The popover's evidence gate for showing the burn figure
(`DisplayFormatter.burnHasDisplayEvidence`) is stricter than the engine and belongs to the
[account summary](account-summary.md#header-facts).

## The blended rate (Claude's five-hour runway)

Two rates are measured over two sample rings:

- the **18-minute rate**, over the trimmed buffer above;
- the **trailing-hour rate**, the same two-point rule and the same zero-proof over a second,
  **untrimmed** ring: every sample inside `sampleMaxAge`, no count cap. It takes the same appends,
  ageing and clears as the buffer. On a window of a day or wider the two rings hold the same
  samples. (`ForecastEngine.rawBuffers`; tests `ShadowForecastTests.testRawRingKeepsWhatTheCountTrimDiscards`,
  `testRawRingAgesOnANullWindowPollToo`, `testRawRingClearsOnRolloverWithTheBuffer`, `testSeedFillsBothRings`)

**The account state** at an evaluation: *burning* if the used percent rose by at least 1 point
(`riseThreshold`) since the sample nearest 10 minutes ago; else *paused* if it rose by 1 point
since the sample nearest 30 minutes ago; else *quiet*. A neighbour counts only within 180 s
(`originMatchTolerance`) of the wanted instant, and both neighbours are required even for
*burning*, so the live path classifies the same population the tables were trained on. The newest
sample must also be at most 180 s old. If any of this fails the state is **unknown**, never
*quiet*: "we did not look" is not "nothing happened". (`ForecastEngine.accountState`; tests
`testBurningWhenTheAccountMovedInTheLastTenMinutes`, `testPausedWhenItMovedInThirtyMinutesButNotTen`,
`testQuietWhenNothingMovedInThirtyMinutes`, `testNilWhenAccountStateIsUnknown`,
`testNilWhenTheNewestReadingIsStale`)

```text
blend = alpha[state] · rate_18min + (1 − alpha[state]) · rate_hour
      = whichever rate exists, if only one does
      = no value, if neither resolves
```

`alpha` is the weight on the 18-minute rate, from the shadow tables (below). The blend has **no
value** when neither rate resolves, with fewer than two buffered samples, an unknown account state, a null window, no used
percent, the low-allowance shape, or a primary a day or wider. (`ForecastEngine.blendRates`)

**Which rate Claude's five-hour runway divides by:**

| Condition | Rate |
|---|---|
| The blend has no value | The 18-minute rate, unchanged |
| Primary used below 75 % | The blend |
| Primary used at or above 75 % (`StateEngine.atRiskUtilFloor`) | The faster of the blend and the 18-minute rate |

Reasons: the blend is calmer by design, because the trailing hour smooths a burst; near the top of
a window calm is the wrong error, so the faster rate wins from the At-risk floor up. The floor
reuses At risk's own constant, so no new number was added. Codex keeps the 18-minute rate on every
width. This is one branch in `forecast(for:)`; the code comments call it the revert target. (Tests
`BlendDrivesRateTests.testBelowTheFloorTheBlendIsChosen`,
`testAtTheFloorTheShortRateWinsWhenItIsFaster`, `testAtTheFloorTheBlendWinsWhenItIsFaster`,
`testUnderThirtyMinutesOfRingTheShortRateIsUsed`, `testAStaleNewestReadingUsesTheShortRate`,
`testBothRatesUnresolvedStaysUnmeasured`, `testCodexFiveHourKeepsTheShortRate`,
`testCodexSevenDayKeepsItsOwnRate`)

**One derivation, one table set, one instant.** `blendRates` feeds both the runway and the shadow
row, and `PollCoordinator` hands the same tables and the same time to both, so the blend in the log
is the blend the runway used, even if a table rebuild lands in between. (`PollCoordinator.pollOnceInner`,
`handleLocalDelta`)

## The pace clock

The pace clock compares how much of a window's quota is used with how much of its calendar has
passed. It needs no buffer, so it works from the first poll and across restarts.
(`Adapters/AccountAdapter.swift`: `QuotaSnapshot.paceElapsedPct`, `paceExceeded`)

```text
elapsed % = (width − seconds to reset) ÷ width × 100          width = primaryWindowLength
pace exceeded = elapsed % ≥ 2   AND   used % > elapsed %
```

- **`paceElapsedPct`** is `nil` without a used percent and a reset (a null or not-started window).
  It is not clamped: past the reset it reads over 100. Callers that display it clamp.
- **`paceExceeded`** is `nil` where `paceElapsedPct` is (no pace claim at all), `false` inside the
  grace, then `used > elapsed` with no points slack.
- **The 2 % grace** (`QuotaSnapshot.paceGraceFraction` = 0.02 of the width: about 6 minutes of
  five hours, about 3.4 hours of a week). Any use at a window's open is ahead of a straight-line
  schedule, so without the grace every window's first session would read over pace. It is a time
  grace rather than a points slack because, on a replay, a points slack hid most genuine warnings
  while the grace hides only the window-open ones.
- **The width is `primaryWindowLength`, never the raw reported width,** so Claude (which reports
  none) paces against five hours instead of never pacing.

(Tests `QuotaSnapshotPaceClockTests`: `testElapsedIsTheCalendarShareOfTheWindow`,
`testElapsedIsNilWithoutAPopulatedAnchoredWindow`, `testExceededReadsTheSameHand`,
`testElapsedFollowsTheReportedWidth`; `StateEngineTests.testElevatedSilentInsideWindowOpenGrace`)

**Why the clock exists.** The burn buffer spans minutes. Against a seven-day window, "runway
shorter than the time to reset" is true for almost any burst, so a short burst early in a week
could read as "won't make it". A runway may be computed from minutes of evidence, but a verdict
against a whole window also needs the calendar to agree.

**Readers.** Elevated on [state](state.md#the-states) (`StateEngine.classify`); the exhaustion
decision (`DisplayFormatter.exhaustionRunwayMinutes`); the verdict, its anatomy and the long-window
hero ([account summary](account-summary.md), [explanations](explanations.md)); and the weekly notification ladder for a
seven-day primary (`QuotaSnapshot.weeklyForNotifications`, [notifications](notifications.md)). Which
states are pace-gated, and why, is on [state](state.md#the-states). State and display
read this one derivation; never fork it.

**The pace inputs of the long-limit tiers.** The tiers themselves are
[state](state.md#long-limits-as-states)'s; this page owns the elapsed share they read:

- A **secondary (weekly) window**: the same formula against the secondary's reset, with width
  `secondaryWindowSeconds`, else seven days (`secondaryWindowFallbackSeconds`). Computed inline
  in `QuotaSnapshot.longLimitAssessments`, unclamped. (`LongLimitAssessmentTests.testClaudeWeeklyWithNoReportedWidthUsesSevenDays`,
  `testCodexWeeklyPacesAgainstTheReportedWidth`, `testUnanchoredLimitYieldsNoAssessment`)
- A **seven-day primary**, for the notification ladder only: `paceElapsedPct`.
- The **2 % grace** is the same `paceGraceFraction`. (`LongLimitAssessmentTests.testTheGraceIsInclusiveAtItsEdge`)
- The monthly pool's elapsed share comes from its calendar cycle
  (`MonthlyLimit.elapsedPctInCycle`) and is [credits and monthly limits](credits-and-monthly-limits.md)'s.

## Poll-pair deltas

The buffer also answers three narrower questions for other engines. Each reads the trimmed buffer.

| Function | Answers | Read by |
|---|---|---|
| `utilDeltaLast2Polls(for:withinSeconds:now:)` with `fastBurnMaxPollGap` (300 s) | The rise between the last two samples, only if they are at most 300 s apart **and** the newer is at most 300 s old. Clamped at 0 | Fast burn spike ([state](state.md#the-states)) and the fast-burn notification ([notifications](notifications.md)) |
| `utilDeltaLast2Polls(for:)` | The same rise, unbounded. Clamped at 0 | Off-machine burn ([state](state.md#the-states)) and the off-machine notification ([notifications](notifications.md)) |
| `utilDelta(for:overSeconds: 120)` | The rise across the samples inside the last 120 s; `nil` unless two fall inside | The Codex multi-surface notification ([notifications](notifications.md)) |

Why the fast-burn pair is bounded by poll gap, not by a wall clock: two samples inside 120 s
almost never exist at the 120 s cadence, so the old wall-clock test barely fired. Measuring between
the two polls the app has is cadence-independent; the bound keeps it a measurement, and the
recency half stops a later local-file evaluation from re-asserting an hour-old spike. 300 s is two
and a half base ticks: the 120 s cadence always qualifies and one missed poll usually does.
(Tests `testFastBurnDeltaAtTheBaseCadence`, `testFastBurnDeltaNilBeyondTheGap`,
`testFastBurnDeltaNilOnAStalePair`, `testFastBurnDeltaNilAcrossAReset`,
`testUtilDeltaLast2PollsUsesMostRecentPair`, `testUtilDeltaOverWindow`)

`burnWindow(for:)` (the buffer's span and rise) has no production caller (Known gaps).

## Local burn-tier crossings

The local adapters keep a `BurnTierTracker` per tool: input plus output tokens from the session
logs over a rolling 120 s, sorted into four tiers — under 100, 100 to 1,000, 1,000 to 3,000, and
3,000 or more tokens a minute. Only a **crossing** matters, in either direction, checked at each
log flush; the tier is never displayed and never enters the runway. A crossing makes the local
change *meaningful*: it re-runs state classification as a `jsonl_delta`
([state](state.md#when-state-is-evaluated)) and can trigger the session-start poll
([polling](polling.md#extra-polls)). The thresholds are fixed and provisional: the adapter has no
plan context to scale them. (`Adapters/LocalAdapter.swift`: `BurnTierTracker`, `LocalDeltaSignal`;
`ClaudeLocalAdapter.emitDelta`, `CodexLocalAdapter.emitDelta`; tests `BurnTierTrackerTests`:
`testCrossingUpFiresOnce`, `testNoCrossingWhileIdle`, `testCrossingDownFiresWhenWindowDrains`,
`testIntermediateTierBoundaries`)

## Shadow outputs

Beside the runway, the engine computes the blend, a probability and a range on every poll and every local-change
evaluation that holds a reading. They are written to the forecast log and **rendered nowhere, gate
nothing and notify nothing**, except the blend, which drives Claude's five-hour runway as above.
(`Forecast/ShadowForecast.swift`: `ShadowForecast`; `ForecastEngine.shadow`)

| Output | Meaning |
|---|---|
| `blendRate` | The blend above, %/min. Logged for both tools; used only on Claude |
| `riseProbability` | The chance the primary used percent rises at least 1 point in the next 30 minutes (`riseHorizon`) |
| `riseP10`, `riseP90` | The 10th and 90th percentile of that 30-minute rise, in points |
| `version` | `ShadowPolicy.version`, the generation of the rule that produced the row |

**`Forecast` has no shadow member, on purpose.** The state engine, the display and the notification
engine all take a `Forecast`, so the type keeps the probability and the range away from every
surface. (`ShadowForecastTests.testShippedForecastHasNoShadowMember`)

**No row where the rule can say nothing.** The shadow is `nil` exactly where the blend has no
value (see the list above), so it never claims a number where the product refuses one, and covers
short windows only. A `nil` shadow is itself a record: "the app had no second opinion here". Nothing
is carried forward from an earlier evaluation. (`testNilOnColdStart`, `testNilOnNullWindow`,
`testNilOnLongWindow`)

**The probability and the range** for an account state:

```text
probability = (k · prior[state] + hits[state]) ÷ (k + n[state])        k = 20 (shrinkageK)
range       = weighted 10th / 90th percentiles of the state's own 30-minute rises (weight 1 each)
              mixed with the prior's 20 representative rises (total weight k)
```

At `n = 0` both are exactly the prior; a heavy user's own history overtakes it smoothly. There is
no switch at a number of windows. (`ShadowTables.probability`, `riseRange`; tests
`ShadowTablesTests.testProbabilityIsTheShippedPriorAtZeroObservations`,
`testProbabilityConvergesToTheCellRateWithEnoughOwnHistory`, `testRangeIsThePriorsAtZeroObservations`)

**`alpha` for a state** is the grid value in {0, 0.25, 0.5, 0.75, 1} with the lowest mean absolute
error between the blend's predicted 30-minute rise and the observed one, over origins where both
rates resolved. A state with fewer than 30 such origins (`alphaMinCell`) uses the all-state fit,
and below that the prior's. A five-point grid keeps the choice legible and cannot overfit a small
cell. (`ShadowTablesReader.bestAlpha`, `ShadowTables.alpha`; tests
`testAlphaPicksTheGridWeightThatMinimisesError`, `testAlphaIsNilBelowThirtyFittableOrigins`,
`testAlphaFallsBackFromCellToAllStateToPrior`)

**The prior** (`ShadowTables.prior`) is a fixed table in the code: a probability and an alpha per
state, an all-state alpha and twenty representative rises. It was derived once, offline, from one
account's Claude five-hour history, and both tools use it until they have their own. Its values are
pinned by `ShadowTablesTests.testShippedPriorIsExactlyWhatWasDerived` and
`ShadowTablesReplayTests`. Read it as a placeholder, not a measured fact about other users.

**The tables are recounted, never stored.** `ShadowTablesReader.build` counts them in memory from
`quota_series` and the forecast log's exposure rows over the last 30 days (`trainingLookback`). A
stored probability would go stale the day the rule changed; the raw series never does
([storage](storage.md#store-observations-not-conclusions)). `PollCoordinator` rebuilds a tool's
tables on that tool's first successful poll of the process and whenever the primary reset anchor
moves by more than 60 s (including a window opening after a build made during a null window). The
rebuild runs in the background and is never waited on; until it lands, a tool reads
`ShadowTables.empty`, which is the prior alone. A failed read keeps the previous tables rather than
falling back to the prior, because that would silently change what is logged.
(`PollCoordinator.refreshShadowTables`, `refreshShadowTablesIfWindowMoved`)

**Which windows may teach the tables** (`ShadowTablesReader.isEligible`, `windowOrigins`):

- **Completed, with an observed ending:** the limit was reached, or a poll landed within 900 s
  (`windowCloseTolerance`) of the reset. An unwatched ending is a floor, not an outcome.
- **Short:** a known width under one day. An unknown width is excluded, not guessed.
- **Recorded by a build that could record warnings:** some log row for the window has a
  `displayed_state`. Before that column existed every warning stamp is empty because it could not
  be written, not because no warning was shown.
- At least three polls in the window.

**Which moments in a window are origins:** at least 300 s apart (`originSpacing`), because polls
two minutes apart are one stretch of work seen twice; **before the first warning** shown in that
window, because what follows a warning is partly the user's reaction to the app; and with a
sample near 10 and 30 minutes before (for the state) and near 30 minutes after (for the outcome),
each within 180 s. The rates at each origin are replayed through the same trim, ageing and
zero-proof as the live buffer, so training and live use describe the same quantity. (Tests
`ShadowTablesTests`: `testAWindowNobodyWatchedCloseTeachesNothing`,
`testAWindowFromABuildWithoutTheExposureColumnTeachesNothing`, `testTheCurrentWindowTeachesNothing`,
`testALongWindowTeachesNothing`, `testAWindowOfUnknownWidthTeachesNothing`,
`testOriginsAreSpacedAtLeastFiveMinutesApart`, `testPostWarningOriginsAreExcluded`,
`testAGapWithNoThirtyMinuteNeighbourYieldsNoOrigin`)

Every constant of the rule is in `ShadowPolicy`, so a grader can name the exact rule that ran.
None is learned at runtime; only the counts are.

## The forecast log

`forecast_log` is the record a later grader compares with what happened. The app writes it and
reads it back only for the warning-exposure fold above; it never serves a stored forecast back to a
surface. Its place in the database and its permanent retention are on
[storage](storage.md#tables-by-purpose). (`Forecast/ForecastLogRecorder.swift`;
`Storage/SQLiteStore+ForecastLog.swift`)

**When a row is written.** After every state evaluation — poll, local change, poll failure and
launch restore — `ForecastLogRecorder.entry` writes a row if this tool's last row is at least 300 s
old (`sampleInterval`, trigger `sample`) or the evaluation changed the state (trigger
`state_change`, which bypasses the clock and also resets it). The clock is in memory, so a relaunch
may write a duplicate first row; that is harmless. A failed write is logged as a warning and never
blocks the evaluation. (`PollCoordinator.logForecast`; tests
`ForecastLogRecorderTests.testSamplingClockOneRowPer300sWindow`, `testToolsSampleIndependently`,
`testStateChangeBypassesClock`, `testStateChangeAdvancesSampleClock`)

**What a row records:**

| Column | Value |
|---|---|
| `tool`, `computed_at` | The tool and the evaluation time |
| `primary_used_pct`, `secondary_used_pct`, `primary_resets_at` | From the reading the evaluation used; `NULL` with no reading |
| `burn_rate_pct_per_min` | Always the 18-minute rate, unrounded. `NULL` = unmeasured; `0` = a measured zero |
| `eta_to_100` | `computed_at` + the runway that was used (so on Claude's five-hour window, from the blend). `NULL` when there is no runway — itself a gradable claim that nothing was burning |
| `forecast_tier` | The cold-start phase from `pollCount`: `cold_start` (0–1), `partial` (2–9), `full` (10+). Not `ForecastTier` |
| `trigger` | `sample` or `state_change` |
| `app_version` | Marketing version and build, plus the channel on a non-release build, so engine generations can be separated |
| `displayed_state` | The state the evaluation resolved to after the de-escalation hold ([state](state.md#calming-down-the-de-escalation-hold)) |
| `warning_first_shown_at` | The first time a warning-tier state was shown in the current primary-window instance (below) |
| `shadow_version`, `blend_rate_pct_per_min`, `rise_probability`, `rise_p10_pct`, `rise_p90_pct` | The shadow outputs; all five `NULL` together when there is no shadow |

(Tests `testColdStartRowHasNullEtaAndColdStartTier`, `testNearZeroBurnRowHasNullEtaPartialTier`,
`testFullTierEtaDerivation`, `testBurnColumnKeepsTheShortRateWhenTheBlendWasChosen`,
`testDisplayedStateIsTheEvaluationState`, `testAppVersionFormatting`;
`SQLiteStoreForecastLogTests.testWriteForecastLogRoundTrips`, `testQuantizedBurnLandsUnrounded`,
`testANilShadowWritesFiveNulls`, `testAShadowWritesAllFiveColumns`)

Why both rates are on every row: a grader can compare the 18-minute rate and the blend on identical
inputs, whichever one the runway used.

Why the shown state is recorded: users slow down when warned, so a prediction made while a warning
was on screen must be graded separately. It is a fact about what the user saw, which no later
threshold can recompute and `state_transitions` loses after 90 days. The verdict's wording is not
recorded: it is a derived conclusion that goes stale when the copy changes.

**Rows by evaluation path.** Only the poll and local-change paths attach a shadow.

- **Poll failure.** Every failed poll, inside or past the 10-minute staleness limit
  ([quota readings](quota-readings.md#fresh-and-stale-readings)), recomputes a full `Forecast` from
  the cached reading and the current buffer, with no new sample and no ageing, and hands it to the
  state engine and the log. Its row therefore carries an 18-minute rate and an `eta_to_100` from the
  cached reading; only the shadow is withheld. The buffer is cleared only **after** that row is
  written, and only on the first switch to the stale render after a live success, so the row for
  the transition into stale (a `state_change`) carries the old rate too. After a launch the restore
  has already registered the stale render, so the seeded buffer is never cleared during failures
  before the first success, and every 300 s such rows carry the seeded rate.
  (`PollCoordinator.evaluateStaleness`, `restorePersistedSnapshots`)
- **Launch restore.** A hand-built placeholder: no rate, no runway, `cold_start`.

The shadow is withheld on the poll-failure path because pairing it with a reading the app may
already call stale would give a grader a pair it cannot grade; the same objection applies to that
row's rate and `eta_to_100`, which are logged anyway. No column says which path wrote a row. On
screen nothing of this is shown: a stale reading is displayed without a forecast. (Known gaps)

**The warning-exposure latch.** `ForecastLogRecorder` watches every evaluation, row or no row. The
first time a warning-tier state (`AppState.warningStates`, on [state](state.md#severity)) is shown
inside a primary-window instance, it stamps that time. Calming down does not clear the stamp and a
worse warning does not replace it. The instance ends when the reset anchor moves more than 60 s in
either direction (an early reset or plan change can move it earlier) or the remembered anchor has
passed (Claude's post-reset reading carries no reset to move); the next instance never inherits the
stamp. With no anchor, nothing is stamped. The latch is in memory, so after a relaunch the stamp is
a lower bound: whether a warning was shown stays right, its duration reads short.
(`ForecastLogRecorder.observeExposure`; tests `testFirstWarningDisplayStampsThatInstant`,
`testStampSurvivesTheStateCalmingDown`, `testAWorseWarningKeepsTheFirstInstant`,
`testStampClearsWhenTheAnchorAdvances`, `testStampClearsWhenTheRememberedAnchorHasPassed`,
`testARolloverInsideASilentGapIsNotInherited`, `testAWarningWithNoKnownWindowStampsNothing`)

**The one runtime reader.** `SQLiteStore.forecastLogWindowExposure` folds rows into one entry per
`primary_resets_at` over a half-open period: whether any row has a `displayed_state`, and the
earliest warning stamp. It reads no prediction column. (Tests
`testWindowExposureFoldsRowsPerAnchorAndKeepsTheEarliestWarning`,
`testWindowExposureReportsAPreV24RowAsUnrecorded`, `testWindowExposureSkipsRowsWithNoWindowAnchor`)

The `kvotar` CLI ships a starter query that checks each logged `eta_to_100` against `quota_series`
(`Packages/KvotarCLI/Sources/KvotarCLI/StarterQueries.swift`; [CLI](cli.md)).

## Rejected alternatives

- **Wipe the buffer after a 10-minute poll gap.** It threw away a valid anchor on every short sleep
  and read 0 burn for up to ten polls. Replaced by per-sample ageing.
- **Age the buffer only on polls that carry a window.** A null-window run froze it and re-served
  one rate for over an hour, and wrote measurements the app never made into the log.
- **A 3,600 s zero-proof on long windows.** Unreachable under the 3,600 s age cap. Also rejected:
  a strictly earned zero on a weekly, which would need over five hours flat.
- **A smaller count cap at the 120 s base.** The longer memory (about 18 minutes) was accepted;
  retention and cold start stay separate questions.
- **A points slack for the pace clock.** It hid most genuine warnings; the time grace hides only
  window-open noise.
- **The blend alone near the top of a window.** It warns later than the 18-minute rate there; the
  faster of the two wins from 75 % used.
- **Fast burn measured inside a 120 s wall clock.** Almost never had two samples at the 120 s
  cadence. Replaced by the bounded poll pair.
- **The inferred-runway tier** (local burn against a capacity prior). It fired only on a reading
  shape that no longer exists, and its runway was never shown.
- **Local activity as an input to the account state.** Not used: it added little, and session-log
  timestamps can arrive late, so a replay could see work the app had not yet seen.
- **Stored shadow tables, and a switch to the prior below a number of windows.** Recounting keeps
  stored conclusions out of the database; the k-weighted prior has no cliff.

## Known gaps

| Gap | Today | Proposed fix |
|---|---|---|
| Partial-average flag unused | `isEstimate` has no surface; read only by a fixture fallback in `burnHasDisplayEvidence` | (Decided 1) Delete `isEstimate`, its `~est.` comments and the fixture fallback's use of it, adjusting the fixtures and tests that set it |
| `ForecastTier` mostly unread | Only `fullRunway` is read (`MoneyModel.etaTo100Minutes` in `State/MoneyState.swift`); nothing tells `creditBased` from `unknown`, and `creditBased` no longer means "local burn, no quota denominator" | Collapse to a boolean "runway applies", or document the two remaining values as unread, with the next change to `Forecast.swift` |
| `burnWindow(for:)` has no caller | Its comment says the off-machine estimator measures over it; nothing in the app calls it, only tests | Delete it and its tests, or wire it, with the next change to `ForecastEngine` |
| Multi-surface delta needs two samples in 120 s | `utilDelta(overSeconds: 120)` is the Codex multi-surface notification's input; at the 120 s cadence the previous sample is often just outside the window — the coupling fast burn dropped | Measure between the last two polls with a bound, like `fastBurnMaxPollGap`; the rule itself is [notifications](notifications.md)'s |
| Poll-failure rows log a forecast from a cached reading | Every failed poll logs `burn_rate_pct_per_min` and `eta_to_100` computed from the cached reading and an un-aged buffer, past the staleness limit too; the buffer is cleared after the log write, and never during failures right after a launch. Rows from poll, local-change, poll-failure and restore paths share `trigger` = `sample` / `state_change`, so a grader cannot separate them; a missing shadow is ambiguous | Write `NULL` burn and eta on the poll-failure path (or clear the buffer when the restore registers the stale render); and add the evaluation trigger (`StateTrigger`) as a column in a new migration ([storage](storage.md#rules-for-a-new-migration)), `NULL` on old rows |
| Stale comments | `Forecast` and `ForecastEngine.record` say a null-window poll counts toward cold start (it adds no sample, and `pollCount` is the sample count); `utilDelta` says it powers fast burn; `Forecast.isEstimate` names a `~est.` label | Fix with the next change to each file |
| Five-hour fallback and 60 s tolerance copies | `seed` and `ShadowTablesReader` use `?? 18_000`; `ForecastEngine.resetJitterTolerance` is its own 60 | Already on [quota readings](quota-readings.md#known-gaps); fix there |

## Code and tests

Under `Packages/KvotarCore/Sources/KvotarCore/`: `Forecast/Forecast.swift`,
`Forecast/ForecastEngine.swift`, `Forecast/ForecastLogRecorder.swift`,
`Forecast/ShadowForecast.swift`, `Forecast/ShadowPolicy.swift`, `Forecast/ShadowTables.swift`,
`Forecast/ShadowTablesReader.swift`, `Adapters/AccountAdapter.swift` (`QuotaSnapshot`:
`primaryWindowLength`, `paceGraceFraction`, `paceElapsedPct`, `paceExceeded`,
`longLimitAssessments`), `Adapters/LocalAdapter.swift` (`BurnTierTracker`),
`Storage/SQLiteStore+ForecastLog.swift`, `Storage/SQLiteStore+Poll.swift`
(`readForecastSeedSamples`). Wiring: `App/PollCoordinator.swift` (`restorePersistedSnapshots`,
`pollOnceInner`, `evaluateStaleness`, `handleLocalDelta`, `logForecast`, `refreshShadowTables`).
The windows the tables learn from: `History/QuotaWindowOutcomes.swift`.

Tests in `Packages/KvotarCore/Tests/KvotarCoreTests/`: `ForecastEngineTests`,
`BlendDrivesRateTests`, `ShadowForecastTests`, `ShadowTablesTests`, `ShadowTablesReplayTests`,
`ForecastLogRecorderTests`, `SQLiteStoreForecastLogTests`, `QuotaSnapshotPaceClockTests`,
`LongLimitAssessmentTests` (the pace inputs), `BurnTierTrackerTests`, `LowAllowanceShapeTests`
(no rate on the shape), `StateEngineTests` (the grace).
