---
summary: The current rules for the History window — how it opens and lives, the typed arrivals from other surfaces, its four modes (Weekly recap, Explore quota, Explore usage, Hard blocks) with their copy and evidence rules, the 30-day report it reads, and the quota-window outcome fold that History and the forecast's shadow tables share.
read_when: Changing HistoryWindowController, HistoryViewModel, HistoryDestination, HistoryExperience, HistoryDisplay (any HistoryDisplay*.swift file), HistoryWeeks, the views under Views/History; HistoryReport, HistoryReportReader, QuotaWindowOutcomes, QuotaWindowOutcome, WeeklyLimitOutcome, or the History reads in SQLiteStore+History.swift (limitHits, watchingSince, the hourly reads); what a Hard blocks row is made of; the work-per-1% display gate (windowChangeSummary, qualifyingCycles); or any History copy.
---

# History window

## Questions for owner

1. **What should count as a recorded block?** Today *Hard blocks* records **only Over quota**:
   it reads the `over_quota` rows of `notification_events`, and a row exists only while the
   **Over quota** notification group is on (see *Hard blocks depend on the Over quota
   notifications*). The same rows feed the mode's rows, consequence card, hour chart and pattern
   note, the day strip's block dot, the block rows in an Explore usage day, Explore quota's
   `Recorded block` link, the recap's block lead and its *Next week* action, and the "is this
   tool blank" test. Two things are open:
   - **Spend control.** On [state](state.md#the-states) a Hard block is Over quota **or** Spend
     control; a Spend control entry shows in History only as a critical observation in an
     Explore usage day, labelled with the state name `Spend control` (which meets the open term
     difference over Spend control as a condition versus a state,
     [credits and monthly limits](credits-and-monthly-limits.md#spend-control-as-a-condition)).
     List spend-control blocks too, or rename the mode?
   - **An independent record.** Keep reading notification rows (no work; the page states the
     dependency), or read blocks from a record the switch does not touch, such as
     `state_transitions` entries into Over quota (kept 90 days) or readings at 100 % in
     `quota_series` (permanent)? Either new source changes what counts as one block and needs
     its own fixtures.
2. **Whole dollars in the recap and in the work-per-1% row.** The recap rounds an Est. token
   value of $10 or more to whole dollars (`$40`, `Together about $40`), and the allowance panel's
   figure row reads `$<low> – $<high> of work per 1%` in whole dollars. Neither form is on
   [display semantics](display-semantics.md#rounding-and-number-forms), which lists only
   `$12.00`. Record both forms there, or change the code to `$12.00` everywhere? (One of the five
   open term differences; not settled here.)

## Decided

The maintainer ruled on this on 2026-10-04. The code does not follow it yet; its row in *Known
gaps* below names the change.

1. **Rewrite the out-of-date weekly-exhaustion coverage copy.** The Hard blocks coverage note
   says *Weekly-only exhaustion may not appear*. That was true when the state engine read only
   the five-hour window; it now enters Over quota on a spent weekly too
   ([state](state.md#the-states)), so a spent weekly reaches the same notification path. The
   clause, and the `ToolReport.limitBlocks` doc that says such a block "cannot" be recorded, are
   to be rewritten. (Whether a weekly block shows the right reset is a separate, unverified gap;
   see *Known gaps*.)

## About this page

This page is the specification for the History window. It replaces the private UI Spec Part 3 §6
(History window, §6.0 to §6.5) and the approved History contract summary at the top of that
document; the private History decision records still in force (the weekly recap and Explore quota
record, the recap-says-the-numbers record, the limit hits and account changes record with its open
question and its parked period picker, the still-valid parts of the three-mode History experience
record, and the honesty rules of the first History dashboard record); the display gate of the
private quota-change evidence record; and the History parts of the private Implementation
Baseline §15.2 (Navigation and sizing) and §17.1 (the reader notes on `state_transitions` and
`quota_series`). Those are kept as history. Change this page in the same commit as the code it
describes.

IDs such as REV-nn, D-nn or STEP_nnn in code comments are private record IDs;
[REFERENCES.md](../REFERENCES.md) explains them. The rules here stand without them.

Words used here: a **quota window** is the five-hour or weekly (or other provider-reported)
refill period ([quota readings](quota-readings.md#limits-and-windows)). The **History window** is
the standalone window this page describes; it is not the app window
([app lifecycle](app-lifecycle.md#when-the-app-window-opens-and-closes)). *Local activity*,
*Elsewhere* and *Est. token value* are as defined in
[product scope](product-scope.md#terms-a-newcomer-needs).

What this page does **not** own:

| Topic | Page |
|---|---|
| The **History…** menu item | [Menu actions](menu-actions.md#item-details) |
| The popover's `History · last 30 days` footer link and the `N more projects ›` row | [popover](popover.md) |
| Closing the popover or the app window before History opens | [App lifecycle](app-lifecycle.md#when-the-app-window-opens-and-closes) |
| The `% used` exception for the quota chart, colours (`HistoryTheme`), unknown and known-empty wording, number forms | [Display semantics](display-semantics.md) |
| Which state a reading is in, critical states, Over quota and Spend control | [State](state.md) |
| Whether an `over_quota` row is written (group switch, caps, block episodes) | [notifications](notifications.md) |
| Token counting, `DisplayedTokens`, project grouping (`ProjectGrouping`), local days | [Local usage](local-usage.md) |
| Prices, the fallback price and the meaning of `≈`, the not-a-bill line | [Estimated value](estimated-value.md) |
| The work-per-1% series and its math | [Capacity learning](capacity-learning.md#the-work-per-1-series) |
| What the shadow tables do with the fold's windows | [Forecast](forecast.md#shadow-outputs) |
| Tables, what writes them and how long they are kept | [Storage](storage.md#tables-by-purpose) |
| Hover-card timings and grammar shared with the day strip | [explanations](explanations.md) |

## Why it exists

The popover answers "am I safe right now". History answers what happened over the last 30 days:
what mattered last week, how the provider's quota windows ended, where local work went, and what
happened when access stopped. It reads two kinds of evidence with different reach, and keeps them
apart: the local token records, which are permanent and backfilled, and the poll-side records,
which exist only from the day Kvotar started watching.

## Opening and living

- **One window per process, created on first open.** `AppDelegate` builds one
  `HistoryWindowController` at launch; the `NSWindow` itself is made on the first `show`.
  Every later open brings the same window forward. (`App/HistoryWindowController.swift`:
  `show`, `makeWindow`; `App/AppDelegate.swift`, the History block of the launch wiring)
- **Chrome.** Titled `History`; titled, closable, minimisable and resizable; default content size
  860 × 640 pt, minimum content size 560 × 420 pt; centred on first open, then its frame is remembered under
  the autosave name `Kvotar.History`. Why the default width: wide enough for the two-column
  layouts to appear on first open; the minimum still lays out in one column. (`makeWindow`;
  `HistoryView` repeats the minimum)
- **Kvotar stays an accessory app.** The controller never changes the activation policy; it calls
  `NSApp.activate(ignoringOtherApps:)` and makes the window key. Reason: a regular policy would
  grow a Dock icon and an app menu for a window that needs neither. (type comment, `show`)
- **Closing hides it.** `isReleasedWhenClosed` is false, so the next `show` reuses the same
  window with a fresh report. Reason: releasing on close would leave the controller holding a
  freed window. Polling is unaffected.
- **Every open reloads, and so does every focus.** `show` resets the view (`prepareForOpen`), then
  reloads. `windowDidBecomeKey` only reloads. Reason: a first-launch window fills in as the launch
  backfill lands rows, and re-focusing an open window must keep the reader's place and any
  destination it was sent to. (`show`, `windowDidBecomeKey`)
- **Loading never blanks the window.** A reload already running absorbs a second request. A
  reload that returns no report keeps the previous screen. Before the first report the body reads
  `Reading local records…` while loading and `No local records yet.` otherwise; the report is
  missing only when the app has no database. A small progress spinner sits in the header while
  loading. (`HistoryViewModel.reload`; `HistoryView.body`; `PollCoordinator.historyReport`;
  test `HistoryViewModelSelectionTests.testReloadWithANilReportKeepsThePriorExperience`)
- **One pricing path.** The report is built through the attribution engine's own pricing engine,
  so History and the popover cannot disagree about a dollar
  ([estimated value](estimated-value.md#spans-and-where-each-figure-shows);
  `AttributionEngine.historyReport`).
- **Keys.** Esc drops a day or hour hover card (`HistoryView`, `onExitCommand`). The quota chart
  takes ← and → (see *Explore quota*). The controller installs no ⌘W or ⌘Q handling (see Known
  gaps).

## Arriving with a destination

Two doors open the window in its **ordinary opening**: the **History…** item of the right-click
menu (or its `⋯` twin in the app window) and the popover's footer link. Both pass no destination. Ordinary opening means: Weekly recap, the newest
completed week, every mode's provider control reset to `All`, no scope banner, no pinned quota
window, no hover card. (`HistoryViewModel.prepareForOpen`;
`MenuBarController.onOpenHistory`, `AppViewModel.openHistory`; tests
`HistoryViewModelDestinationTests.testNoDestinationKeepsTheOrdinaryOpening`,
`HistoryViewModelNavigationTests.testOpeningResetsEveryModesProvider`)

A link that needs more passes a typed `HistoryDestination`: a mode, an optional provider, an
optional scope (a local day, or a completed Monday–Sunday week), an optional focus, and an
optional banner string. Nothing is a URL and nothing is parsed on arrival. Reason: a string the
receiver parses can drift from the link that built it. (`Model/HistoryDestination.swift`)

| Producer | Destination | On arrival |
|---|---|---|
| Popover `N more projects ›` | Explore usage, that provider, the local day the section described, a `projects` focus, no banner | That day is selected; the day's project rows are what the popover's overflow pointed at |
| A recap evidence link | The mode holding the evidence, the provider where the fact is one provider's, the exact week, a banner | The banner shows; the mode still shows all 30 days |
| A quota window's `Recorded block` link | Hard blocks, that provider, a banner naming the window | The banner shows; no week is scoped |

- **The day is captured at click time and matched by calendar day.** A midnight between the
  click and the load cannot move the target, and the oldest column, which starts mid-day, still
  matches. A day the page does not have falls back to the page's own default.
  (`HistoryDestination.projects`, `AppViewModel.openProjectHistory`,
  `HistoryViewModel.selectedEntry`; tests
  `HistoryViewModelDestinationTests.testTheDayIsMatchedByCalendarDayNotByInstant`,
  `testAForeignDateFallsBackToTheInitialSelection`, `testProviderIsAppliedBeforeTheDay`)
- **The provider is set before the day**, because changing the provider clears the day selection.
- **Weekly recap is never a link target.** A recap link always points out of the recap at the
  evidence behind a claim.
- **Inside the window, links navigate without reopening.** `navigate(to:)` applies the
  destination and remembers the recap week the reader was on. (test
  `HistoryViewModelNavigationTests.testAnEvidenceLinkOpensItsModeWithARemovableBanner`)
- **The banner** reads `From weekly recap · <provider> · <span>` (provider only when the link
  has one) or `From quota window · <provider> · <span>`. It is built beside the link, so the two
  cannot drift. It carries `Back to weekly recap`, which returns to the recap week the link came
  from, and a clear button (`Clear scope`), which drops the banner and keeps the provider.
  (`HistoryDisplay.recapLink`, `quotaBlockLink`; `ScopeBannerView`;
  `HistoryViewModel.clearScope`, `backToWeeklyRecap`; test
  `testBackToWeeklyRecapReturnsToTheWeekTheLinkCameFrom`)
- **A scope moves attention; it never re-bases a figure.** A week scope dims quota points outside
  the week and pins the first window inside it, selects the newest active day of that week on
  Explore usage, and highlights event rows inside the week. Every sentence still describes all
  30 days. A scope without a week narrows nothing. The reader's own selection beats the scope.
  (`resolvedQuotaPoint`, `selectedEntry`; tests `testAScopedWeekPinsTheFirstQuotaWindowInsideIt`,
  `testAScopedWeekSelectsADayInsideItOnExploreUsage`, `testAScopeWithoutAWeekNarrowsNothing`,
  `testTheReadersOwnSelectionOutranksTheScope`)
- **An ordinary open after a destination resets it.** (test
  `HistoryViewModelDestinationTests.testAnOrdinaryOpenAfterADestinationResetsIt`)

## Four modes, one report

- **Modes, in order:** `Weekly recap | Explore quota | Explore usage | Hard blocks`, as an
  underline tab row under the title. Weekly recap is the ordinary-open default. Each mode has a
  fixed subtitle under the title (`Weekly recaps and the evidence behind them`, `Explore
  provider-reported quota history`, `Explore recorded local activity`, `Investigate recorded
  interruptions`), and the three evidence modes add a grounding sentence under the mode name.
  (`HistoryExperience.Mode`: `label`, `windowSubtitle`, `evidenceSubtitle`; test
  `HistoryExperienceContractTests.testModeLabelsAreTheDecidedNames`)
- **A provider control on the evidence modes only.** `All | Claude | Codex` (`All`, then one per
  tool in report order), one selection **per mode**: choosing Codex while investigating a block
  does not re-scope Explore usage. Weekly recap has no provider control; it is cross-provider by
  construction, its payload lives once at the root. (`HistoryViewModel.provider`; tests
  `HistoryViewModelNavigationTests.testEachEvidenceModeKeepsItsOwnProvider`,
  `HistoryExperienceContractTests.testRecapIsCrossProviderAndLivesAtTheRoot`)
- **Switching is instant and stored nowhere.** One report builds every mode × provider payload
  up front (`HistoryDisplay.experience`), so a control change reads memory, never the database.
  Changing the provider clears the day and point selection; changing the mode releases a pinned
  quota window; either change drops any hover card and scrolls to the top. Nothing is persisted across opens.
  (`HistoryViewModel`; `HistoryView.content`; tests
  `HistoryViewModelSelectionTests.testProviderChangeClearsTheDaySelectionAndModeChangeKeepsIt`,
  `HistoryViewModelNavigationTests.testChangingModeOrProviderReleasesThePinnedWindow`)
- **SwiftUI computes nothing.** Every string, grouping, total, empty state, chart fraction and
  destination comes typed from `HistoryExperience`; a view multiplies a supplied 0–1 fraction by
  a size and nothing more. Reason: the window cannot then format a figure differently from the
  model its tests pin. (`HistoryExperience` type comment)
- **Header.** Title `History`; the evidence modes carry the eyebrow
  `Last 30 days · <start> – <end>`. (`HistoryScreen.Header`)
- **Footer, always:** `Local Claude Code and Codex records on this Mac · evidence horizons vary ·
  prices v<version> (<date>)`; `prices v<version>` when the table has no date, and no prices
  part when no table stamp loaded.
  (`HistoryDisplay.experienceFooter`; tests `testFooterNamesTheRecordsTheHorizonsAndThePrices`,
  `testFooterWithoutAPricingStampOmitsTheSegment`)
- **Not-a-bill line.** Wherever an Est. token value is visible, `Priced at published API rates
  for each model. Not a bill.` sits with it (`HistoryDisplay.pricingNote`, `recapNotABill`;
  [estimated value](estimated-value.md#the-value-note)).
- **Empty.** When no tool has local work, watching history, account changes, blocks or a
  work-per-1% series, the body reads `No local Claude Code or Codex activity in the last 30
  days yet.`; the mode tabs stay, the provider control is not shown. A tool watched but locally idle is **not** empty: its quota
  and block evidence still show. (`HistoryDisplay.isBlank`, `emptyReportMessage`; tests
  `testEmptyReportKeepsControlsAndSaysSoOnce`, `testAWatchedButIdleToolIsNotBlank`)

### Rules every mode keeps

- **`All` is not a third provider.** No token, session or model figure is ever summed across
  Claude and Codex; the render model has no field for a combined token total. Sessions and
  threads keep their own nouns. A combined Est. token value may appear once, subordinate, only
  when both providers have work. When only one provider has work, `All` drops the provider tags.
  Reason: the two tools count tokens differently
  ([local usage](local-usage.md#counting-tokens)). (tests
  `HistoryExperienceContractTests.testNoCombinedTokenFigureAppearsAnywhereOnAll`,
  `HistoryExperienceExploreTests.testProviderTotalsAreSeparateAndOnlyDollarsCombine`)
- **Each provider keeps its own scale.** On `All`, every local-activity bar (day strip, weekly
  rows, hour chart, ranked-row tracks) is a share of that provider's own busiest bucket. Fractions
  are geometry, never a cross-provider comparison. (`experienceDayStrip`, `providerWeekly`,
  `experienceHourChart`; tests `testAllStripNormalisesEachProviderAgainstItsOwnBusiestDay`,
  `testChartNormalisesEachProviderAgainstItsOwnBusiestHour`)
- **Known empty is not unknown.** A day or week with no work reads `No activity` (and `$0.00`);
  `—` means not recorded or not derivable; an absent group is omitted, never a row of dashes.
  ([display semantics](display-semantics.md#unknown-missing-and-stale); test
  `HistoryExperienceExploreTests.testUnknownOptionalValuesStayAbsentOrDashed`)
- **No polling words, no stated allowance size, no accusation.** Copy never says `steady`, never
  states how big an allowance is, and never claims a provider cut it. The polling-word copy rule
  belongs to [display semantics](display-semantics.md#the-copy-rule-no-polling-words); History's sweep
  is its own list (test `HistoryExperienceChartTests.testNoPayloadEverSaysSteadyOrNamesPollingInternals`).
- **Retired words.** `Est. API value`, `Explore days`, `Cost` and `No typical block time yet`
  never render. (test `testNoRenderedStringUsesRetiredVocabulary`)
- **Recap prose is recomputed on every open and never stored.**

## The 30-day report

`HistoryReportReader.report(now:calendar:)` builds one `HistoryReport`: a period of exactly
30 × 24 hours ending now, and one `ToolReport` per tool (Claude, then Codex), plus the pricing
table stamp. (`History/HistoryReportReader.swift`; `History/HistoryReport.swift`:
`periodDays = 30`)

- **Never throws.** A failed read empties that part of that tool's section; the window degrades
  to fewer rows, never a blank page, and never invents a zero or a project. (type comment; test
  `HistoryReportReaderTests.testEmptyCorpusYieldsEmptyReportNotZeros`)
- **Calendar time, never plan windows, for local work.** Reset times exist only in poll data and
  cannot be rebuilt for the past, so local work is bucketed by local calendar day and by 7-day
  span. Reason: a window-aligned report would show nothing from before install, which is what the
  backfill exists to show. (`HistoryReport` type comment)
- **Two horizons, never equated.** Local token records are permanent and backfilled
  ([local usage](local-usage.md)); they can fill the whole 30 days on a new install. Poll-side
  records (quota windows, blocks, account changes, critical observations, the work-per-1% series)
  start at `watchingSince`, the oldest `history_rollups` hour for the tool, and are absent until
  the first rollup exists. To History a `history_rollups` row is one tool-hour of poll readings
  (lowest, highest and last used percent, and the last reset), kept permanently: its oldest hour
  dates the watching, and its primary resets give a block its lockout (see *Hard blocks*). The
  work-per-1% series also reads it ([capacity learning](capacity-learning.md#the-work-per-1-series));
  what writes the table and how long it is kept is [storage](storage.md#the-retention-job)'s. `notification_events` and `state_transitions` are also deleted after
  90 days ([storage](storage.md#the-retention-job)); the 30-day period sits inside that.
  (`SQLiteStore.watchingSince`)
- **Local work reads one table.** Every local figure comes from `local_usage_events` joined to
  `local_sessions`, not from `session_summaries`. Reason: a summary exists only after a session
  has been idle 24 hours, so the latest day would disagree with the totals beside it.
  (`Storage/SQLiteStore+History.swift`, file comment)
- **31 day slots.** The period starts at an arbitrary time of day, so it touches 31 local days;
  the oldest is a sliver, clipped at the period start and marked partial. A day with no work is
  present with zeros. An hourly row lands in the day its hour starts in (exact in whole-hour
  zones, up to an hour of skew in half-hour zones, never a lost token). Day sums equal the period
  total by construction. (`dayBuckets`; tests
  `testDaysCoverEveryLocalDayOfThePeriodOldestFirstWithAClippedFirstDay`,
  `testDaySumsEqualThePeriodTotal`, `testTheSameEventBucketsIntoADifferentDayInADifferentZone`)
- **Five 7-day buckets.** Walking back from now: four full weeks and a two-day remainder marked
  partial. The busiest-week comparison skips the partial one. (`weekBuckets`; tests
  `testWeekBucketsAreFourFullWeeksPlusOnePartialNewestFirst`,
  `testBusiestCompleteWeekIgnoresThePartialBucket`)
- **Projects and sessions.** Project rows are grouped with `ProjectGrouping` before the top-5 cut;
  a day's project rows group against the provider-wide path set, the same basis the popover's
  daily report uses, so the two lists agree row for row
  ([local usage](local-usage.md#todays-local-report)). Top sessions are priced per event model.
  (tests `testReaderGroupsProjectRowsBeforeTruncationAndLabelsSessionsTheSameWay`,
  `testDayProjectRowsGroupOnTheProviderWidePathSet`,
  `testTopSessionsPricePerEventModelAndTruncateToLimit`)
- **Per-model values.** Each model row is priced on its own; a day's value is the sum of its
  rows, and a day row priced at the fallback rate is flagged for the recap's `≈`. Repricing runs
  on every open against today's table. (tests
  `testDayModelValuesAlignWithTheirTotalsAndSumToTheDayValue`,
  `testDayModelValuesMarkFallbackPricing`)
- **Account changes** are the `discontinuity_events` of five kinds (`plan_changed`,
  `window_added`, `window_removed`, `window_width_changed`, `early_reset`). Plan rows are collapsed
  on the way out by `PlanChangeStability.settled`: a pair of plan names trading places three times
  or more is two sources disagreeing, not an account changing. Stored rows are untouched.
  (`accountChanges`; test `testAccountChangesCarryWindowFactsAndCollapseAFlappingPlanPair`)
- **Critical observations** are `state_transitions` entries into At risk, Bad timing, Over quota
  or Spend control: an instant and the stored utilization, never an interval, and never why.
  (`SQLiteStore.criticalStateEntries`; test `testCriticalObservationsAreTypedBoundedAndOldestFirst`)
- **Quota windows and weekly limits** come from the fold below. The work-per-1% series is built by
  [capacity learning](capacity-learning.md#the-work-per-1-series) over
  `[max(period start, watchingSince), now)`.
- `evidenceFrom` (the tool's oldest local event) is computed but read only by a dead helper (see
  Known gaps).

## The quota-window outcome fold

`QuotaWindowOutcomes.compute` folds `quota_series` readings into one `QuotaWindowOutcome` per
provider-reported window. It is pure: no store, no clock, no copy. History reads it for Explore
quota and the recap's weekly lines; the forecast's shadow tables read it to choose the windows
they learn from ([forecast](forecast.md#shadow-outputs); `ShadowTablesReader`).
(`History/QuotaWindowOutcomes.swift`)

- **A window is its reset anchor.** Readings are grouped by the reset time the provider attributed
  them to, not by runs of polls. Two anchors within 60 s are one window, and a group may span at
  most 120 s from its first anchor. Reason: the endpoint wobbles its reset by a second or so, and
  twins interleave in time; the cap stops a drift of one-second steps from swallowing the next
  window. It is the same ±60 s span `SQLiteStore.quotaSeries(resetsAtNear:)` selects. The
  window's reset is the latest anchor in the group. (`anchorJitterTolerance`, `groupedByAnchor`; tests
  `testAnchorWobbleGroupsAsOneWindow`, `testTwoDistinctAdjacentResetsDoNotMerge`,
  `testGroupingDoesNotChainBeyondTheSelectableSpan`, `testIdentityIsProviderScoped`)
- **No window is invented.** A stretch the provider reported nothing for produces no outcome, never
  a 0 % window. (tests `testUnobservedStretchProducesNoWindowAndNoZero`,
  `testEmptySeriesProducesNoWindows`)
- **Width, and why it can be trusted** (`WidthEvidence`), in order: the newest reading in the group
  that stored a width (`recorded`); for Claude, the provider's fixed field width, five hours for
  the primary and seven days for the weekly (`providerContract`); for Codex, a recorded
  `window_width_changed` boundary on the matching side (`recordedChange`); otherwise `unknown`.
  Never from a plan name, a neighbouring window or today's snapshot. A Codex group read across a
  width change, or with conflicting boundaries, stays unknown. An unknown width means an unknown
  start. (`resolvedWidth`; tests `testWidthComesFromTheNewestRowThatCarriesOne`,
  `testClaudeLegacyWidthComesFromProviderContract`,
  `testCodexLegacyWidthsComeFromRecordedChangeBoundary`,
  `testUnprovenLegacyCodexWidthNeverInheritsANeighboursWidth`,
  `testMalformedWidthChangeDoesNotInventCodexWidth`,
  `testRecordedWidthWinsOverAConflictingChangeBoundary`)
- **How it ended** (`Ending`): `earlyReset` or `withdrawn` (from `early_reset`,
  `window_demolished` or `window_removed` events), else `reachedReset`. A break is matched to the
  window it ended by the anchor it names (`window_removed`: the window read last before it).
  It counts only if it is more than 60 s before the scheduled reset and not before the window's
  last reading. Reason: a natural reset logged a few seconds late is not an early end, and a
  window dropped and then restored under the same anchor was not ended by the drop. `endedAt` is
  the break's time for an early end, else the reset. (`breaksByGroup`, `ending`; tests
  `testEarlyResetRecordedOnTheNextPollEndsTheOldWindow`,
  `testDemolitionJustAfterTheScheduledResetIsANormalReset`,
  `testRemovalGoesToTheWindowReadLastBeforeIt`,
  `testADropFollowedByMoreReadingsOfTheSameAnchorEndsNothing`,
  `testBreakNamingAnotherAnchorIsIgnored`)
- **How much was watched** (`Completion`):

  | Completion | When | What the high water means |
  |---|---|---|
  | `current` | `endedAt` has not passed | The reading so far. Excluded from every completed count, median and comparison |
  | `completedFull` | Ended, and seen at 100 % or more, or the last reading within the tolerance of the end | The ending value |
  | `completedPartial` | Ended, last reading earlier than that | A lower bound only |

  The tolerance is two base poll ticks, the same age at which the freshness stamp turns amber
  (`fullObservationTolerance` = `PollBackoffPolicy.freshnessAmberAge`;
  [display semantics](display-semantics.md#fresh-and-stale)). Reason: one number for "we should
  have heard by now". A reading at 100 % is an ending however early watching stopped, because
  utilization only rises inside a window. (tests `testCompletedFullWhenObservedInsideTheTolerance`,
  `testCompletedPartialWhenObservationStoppedEarly`,
  `testHundredPercentIsCompleteHoweverEarlyWatchingStopped`, `testToleranceIsTwoBasePollTicks`,
  `testOpenWindowIsCurrentAndKeepsItsRunningReading`)
- **Hit the limit** is the first reading at or above 100 %, from the provider's readings, not from
  any notification. `lastReadingGap` is how long before `endedAt` the last reading came.
- **Weekly limits** (`WeeklyLimitOutcome`, `HistoryReportReader.weeklyLimits`): the overall
  weekly is the secondary window folded with the seven-day contract and only the `weekly` breaks,
  plus any main window that is itself seven days wide (a Codex plan whose only window is weekly),
  taken as already folded. Each model allowance's seven-day window is folded per limit and slot,
  with no early ends (none are recorded for model allowances). Five-hour model windows and monthly
  limits are left out. Overall and model limits are separate entries, never summed; on a shared
  reset the overall sorts first. (tests in `HistoryReportWeeklyLimitsTests`, among them
  `testCodexSevenDayMainWindowIsTheOverallWeekly`, `testFiveHourWindowsAreNotWeeklyLimits`,
  `testOnlyWeeklyBreaksEndTheSecondary`, `testCodexWithdrawnWeeklyIsDatedWhenItEnded`)

## Weekly recap

Answers: *what mattered in the last completed week, and is there one useful change to make next
week?* A reading column, not a dashboard. (`Model/HistoryDisplay+Recap.swift`)

**Not the popover's idle recap.** The popover's "idle recap" is the last ended five-hour window
shown on an empty window ([local usage](local-usage.md#from-requests-to-figures)). History's
*Weekly recap* is a completed calendar week. Same word, different things.

- **Which weeks.** Completed local **Monday–Sunday** weeks that intersect the 30-day period, newest
  first; the newest is `Last completed week`, older ones `Week of <date>`; older and newer arrows
  walk them and stop at the ends. The current week never appears; the exclusion is in the week
  list, not a filter. Monday is pinned whatever the locale says, and every boundary comes from
  calendar arithmetic, so a week across a clock change still ends at local midnight. A week only
  partly inside the period is **clipped**. With no completed week the mode reads `No completed
  week yet. The recap covers Monday to Sunday, and appears once a week has finished.`
  (`Model/HistoryWeeks.swift`; tests in `HistoryWeeksTests`,
  `HistoryExperienceRecapTests.testCurrentWeekEvidenceReachesNoRecap`,
  `testNoCompletedWeekYieldsTheEmptyState`)
- **Coverage note.** A clipped week says `Only part of this week is inside the 30-day horizon, so
  week totals are not shown.` and withholds every whole-week conclusion (the table, the pattern
  and calm leads, the day and project observations, and comparisons against it). A week that
  began before `watchingSince` says `Kvotar began watching <date>, so part of this week has no
  poll evidence.` (`recapCoverage`; tests `testAClippedWeekWithholdsWholeWeekConclusions`,
  `testAWeekAfterAClippedWeekCarriesNoComparison`,
  `testAWatchingDateInsideTheWeekIsNamedBesideTheConclusion`)
- **Five blocks, in order, each omitted when empty** (no empty heading):
  1. **The lead.** First supported rung wins:

     | Rung | Eyebrow | When | Example |
     |---|---|---|---|
     | 1 | `Capacity outcome` | A recorded hard block in the week | `Claude ran out of its window once.` / `Work stopped 3 times — Claude 2 times, Codex 1 time.`, then the known lockout or `…the lockout is unknown.` |
     | 2 | `Allowance change` | A plan change, or a window added, removed or re-widened | `Codex recorded plan changed · plus → pro.` + `One recorded change this week.` |
     | 3 | `Work pattern` | A provider's tokens moved 5 % or more against its own previous complete week | `Local token use fell 40% on Claude and 20% on Codex.`; a move of 50 % or more adds a line naming the previous week's figure |
     | 4 | `Week in review` | Otherwise | Per-provider tokens and active days; `Nothing was blocked and no allowance change was recorded.` on a quiet week; `Nothing was recorded this week.` (plus ` Kvotar has been watching since <date>.` once watching began) when no other rung applies — which includes a clipped week with work but no block or change (see Known gaps) |

     An early reset never leads: on an account whose weekly resets early often it would lead
     every recap; it is said on its weekly line instead. (`recapLeadOrder`, `recapBlockRung`,
     `recapAllowanceRung`, `recapPatternRung`, `recapCalmRung`; tests
     `testRungOneAHardBlockLeadsWithItsKnownConsequence`,
     `testABlockWithNoRecoveredResetStillLeadsAndSaysTheLockoutIsUnknown`,
     `testRungTwoAStructuralAllowanceChangeLeadsWhenNothingBlocked`,
     `testAnEarlyResetNeverLeadsAndIsNoLongerAnObservation`,
     `testThePatternLeadCarriesEachProvidersPercent`, `testAHeavyPreviousWeekNamesItsTwoBiggestDays`)
  2. **This week.** One column per provider with local work; rows `Tokens`, `Est. token value`,
     `Active days`. A cell compares against the provider's own previous week only when that week
     is wholly inside the period (`↓40% vs 12.4M`, `↑12%`, `±0%`). Under it once: `Together about
     $40 · Priced at published API rates for each model. Not a bill.` (the note alone with one
     column). A value cell carries `≈` when any of that week's work was priced at the fallback
     rate, with `<Provider> includes models priced at a fallback rate.` beneath. Values of $10 or
     more are whole dollars (Questions for owner, item 2). (`recapTable`, `recapDollars`; tests
     `testTheTableCarriesTokensValueAndActiveDaysPerProvider`,
     `testOneProviderGetsOneColumnAndNoCombinedLine`)
  3. **Weekly limits that reset `<span>`.** One line per weekly limit instance that ended in the
     week (by `endedAt`): `Claude · <date>` → `43% used`, or `reached the limit`. `overall` is added
     only when a model line stands beside it. A window that ended early says `(reset early)` and is
     dated when it ended. A line whose last reading came more than 1 hour before the end gets `*`
     and a footnote `Last reading <N h | N days> before the reset — final use may be a little
     higher.` — never `at least`. Reason: 1 hour, not the fold's 240 s, because the stricter number
     would star almost every line on a reading surface. Monthly spend and credit limits stay out of
     the recap by the maintainer's ruling; the block is about weekly limits only.
     (`recapLimitLines`, `recapLastReadingGapLimit`; tests
     `testWeeklyLimitLinesNameTheLimitTheDateAndTheUse`,
     `testAnEarlyEndedWeeklyIsDatedWhenItEnded`, `testAReachedLimitSaysSoInsteadOfANumber`)
  4. **Observations, at most two**, in order: an allowance change the lead did not take; a model
     weekly 10 points or more above its overall at the same reset, else the fullest weekly at 80 %
     or more; one day with 40 % or more of a provider's value (when it had more than one active
     day); one named project with half or more of a provider's tokens. The last two are withheld
     on a clipped week. (`recapObservations`, `RecapWeek.maxObservations`; tests
     `testAtMostTwoObservationsAndNoFactIsSaidTwice`,
     `testADayCarryingTheWeekAndATopProjectAreObserved`)
  5. **Next week** — one action, **only when the week recorded a hard block**: who ran out and how
     often, then `The reset clock for the current window is on the menu bar before a long run.`
     and the known lockout. Reason: a block is the one outcome that names a change worth making;
     anything softer would be advice the evidence does not carry. (`recapAction`; tests
     `testACalmWeekCarriesNoAction`, `testAHighEndingWindowAloneStillCarriesNoAction`,
     `testABlockedWeekCarriesExactlyOneAction`)
- **Evidence links.** Each block and observation may carry one link: `See the blocks` and
  `See allowance history` → Hard blocks; `See the days` → Explore usage; `See the windows` →
  Explore quota. Scoped to the week, and to a provider only when the fact is one provider's.
  (`recapLink`; tests `testEveryEvidenceLinkCarriesItsModeProviderWeekAndRemovableBanner`,
  `testACrossProviderInsightIsNotScopedToOneProvider`)
- **No notification, badge or unread state.** The recap exists only when History is open.

## Explore quota

Answers: *how did the provider-reported quota windows end?* Provider readings, not local work.
(`Model/HistoryDisplay+Quota.swift`; `Views/History/HistoryQuotaChart.swift`)

- **Main account window only.** The page says `Main account window history. Secondary, monthly and
  model allowances are shown live in the popover and have no recorded history here.` The chart
  plots the primary window's outcomes (`quotaWindows`) whatever their width, so a monthly
  primary appears here; the secondary weekly and model allowances reach only the recap.
- **`% used`, 100 % at the top.** The one retrospective exception to "the number says what is
  left" is defined on [display semantics](display-semantics.md#by-surface); every value is labelled.
- **One section per provider.** On `All` they stack, Claude then Codex, full width, never side by
  side and never on one axis or one sentence. The title names the width (`Claude · 5-hour
  windows`) or, when widths differ or are unknown, `Claude · main account window`. A provider
  that reported no window has no section. With none at all: `Quota history starts as Kvotar
  observes provider windows on this Mac. Earlier windows cannot be recovered.` (tests
  `testAllStacksOneSectionPerProvider`, `testAFreshInstallSaysEarlierWindowsCannotBeRecovered`)
- **One factual sentence per section**, counting completed windows only: `2 of 7 completed
  windows hit the limit.` or `None of the 7 completed windows hit the limit.`, plus `One more
  ended above 80% used.` when it applies; `No completed window recorded yet.` when none. Below 3
  completed windows: `Not enough completed windows to show a pattern yet.`, and the points are
  still drawn. No advice, no pattern language. (`quotaSummary`, `quotaPatternFloor`; tests
  `testTheSummaryCountsOnlyCompletedWindows`, `testSparseHistoryStillDrawsItsPointsAndSaysSo`)
- **One point per window.** `Ended at N% used` (seen to the end), `Reached at least N% used ·
  Partial` (a lower bound, drawn hollow), `So far N% used` (the open window, dashed, in no
  count). Hitting the limit is its own mark, never colour alone. A point's horizontal place is its
  reset across the period. (`quotaPoint`; tests `testPointCopyDistinguishesEndedLowerBoundAndSoFar`,
  `testHitLimitIsItsOwnFlagNotAColour`)
- **Segments.** Points join into a line only within a run. A run breaks, and names why, when the
  previous window ended early (`Reset early`) or was withdrawn (`Withdrawn by the provider`), when
  the width changed (`Window width changed`), or when windows overlap or the gap between them
  could hide a whole same-width window (`Gap in observation`). A shorter idle pause does not
  break a run. Windows with no known width stay one group of separate points, never joined,
  because nothing shows they abut. One note per section says when earlier widths were recovered
  or left unknown. (`quotaSegments`, `quotaBreak`; tests `testAGapBreaksTheSegment`,
  `testShortIdlePauseDoesNotBecomeAMissingHistoryGap`,
  `testWindowsWithNoRecordedWidthAreGroupedButNeverJoined`,
  `testRecoveredLegacyWidthsJoinAndCarryOneEvidenceNote`)
- **Selecting a point** (click, or ← / → on the chart, which is one keyboard stop) pins a detail
  below the charts: title `<provider> · <span>` (the reset alone when the start is unknown);
  rows `Width`, `Used`, `Coverage` (`Seen to the reset`, `Seen at the limit`, `Last seen <span>
  before the reset`, `Partly observed`, `Open now`, with the reading count), `Reset` (with `reset early` or
  `withdrawn by the provider` where so), and `Local work that day | those days` with the note
  `Local work is shown for context. It does not prove what moved the window.` A fact with no
  value is omitted. A block recorded inside the window adds a `Recorded block · <date>, <time>`
  link to Hard blocks. Before a selection: `Select a window to see how it ended.` (`quotaDetail`,
  `quotaBlockLink`; tests `testTheDetailCarriesWidthUsedCoverageAndReset`,
  `testLocalWorkIsLabelledAsContextNotCause`, `testARecordedBlockInsideTheWindowBecomesATypedLink`)
- **Spoken values** name provider, width, span, outcome, a hit limit and an early ending, as plain
  text. (`quotaAccessibility`)

## Explore usage

Answers: *how did local usage break down?* Three grains under an underline control, one at a
time: `By day` (the default), `By week`, `30-day breakdown`.
(`HistoryDisplay+Experience.swift`: `explorePage`; `HistoryModeViews.swift`: `ExploreModeView`)

- **By day.** A 31-column strip, oldest first, with a dot under a day a quota window was blocked
  and a diamond on a day the account or its windows changed; ticks on the report's own week
  starts; a footer `Busiest day <date> · <tokens>` per provider. The newest day with work is
  selected first, else today. Hovering a column peeks a card; a click or arrow key selects it.
  (`experienceDayStrip`; tests in `HistoryExperienceChartTests`, `HistoryDayHoverTests`,
  `HistoryExperienceExploreTests.testInitialSelectionIsTheNewestDayWithActivity`)
- **The selected day** shows, per provider with work: displayed tokens, Est. token value,
  sessions or threads, model rows (tokens only) and project rows; on `All` with both providers,
  one combined value. Then the day's blocks, critical observations (`At risk · 3:34 pm` → `8%
  left`, `—` where no figure was stored) and account changes, merged by time with provider tags
  on `All`. Status `Partial day` on the sliver, `No activity` on an empty day. Once per detail:
  `Warnings are shown only when Kvotar recorded them; no warning here does not guarantee
  headroom.` (`dayDetail`, `observationRow`; tests `testSelectedDayCarriesEveryRecordedFact`,
  `testEvidenceSentenceAppearsOncePerDayDetail`)
- **By week.** Per provider: `<provider> total` (tokens · value, sessions or threads), then the
  five buckets newest first with tokens, value, a bar against that provider's busiest week, and
  `Partial week` on the clipped one. (`providerTotals`, `providerWeekly`; test
  `testWeekRowsCarryTokensValueOwnScaleAndPartialNote`)
- **30-day breakdown.** `Projects`, `Models` (per provider, tokens and value) and `Largest work`
  (sessions and threads: `<date> · <project>` → tokens · value; the session id is never shown).
  On `All` the projects and largest-work lists merge, keep 3 rows, and carry provider tags only
  when both providers contribute. No day input exists, so selecting a day cannot change it.
  (`breakdown`, `allRankedRowLimit`; test `testBreakdownIsThirtyDayGrainAndNeverCrossesTheDayModels`)

## Hard blocks

Answers: *what happened when access stopped?* (`hardBlocksPage`)

### Hard blocks depend on the Over quota notifications

A recorded block is an `over_quota` row of `notification_events`, read by `SQLiteStore.limitHits`.
Nothing else in History records a block. The notification engine drops a switched-off group
before it fires, writing no row, so **with Notify me ▸ Over quota switched off, Hard blocks stays
empty**: `No recorded hard blocks in the last 30 days.`, no consequence card, hour chart or
pattern note; no day-strip dots and no block rows in an Explore usage day; no `Recorded block`
link in an Explore quota detail; no block lead and no *Next week* action in the recap; and a tool
with nothing else recorded counts as blank (`isBlank` reads `limitHitCount`). Blocks while the switch was off never appear later. A row is
written before delivery, so a denied macOS permission or Focus does not have this effect; only the
switch does. How many rows a block writes (one per window, one per block episode) is
[notifications](notifications.md)'s rule. Explore quota is unaffected: its `hit the limit` comes from the
provider's readings. (`SQLiteStore+History.swift`: `limitHits`; `NotificationEngine.evaluateCycle`,
`fire`; `NotificationGroup`; test `NotificationGroupTests.testOverQuotaDisabledDropsOverQuota`.
Whether History should keep its own record: Questions for owner, item 1.)

### A block is a window, a clock and a lockout

- **Row:** `<date> · <width> · <time>` → `locked out 3h 25m`, newest first. The width and the
  duration drop out together when unknown; an unknown lockout reads `—` in the warn hue, never
  zero. (`blockRow`; test `HistoryExperienceHardBlocksTests.testUnknownLockoutRowIsFlaggedWarnAndKeepsTheDash`)
- **The reset is derived, never guessed.** The block row stores the instant and a window key; the
  reset comes from the primary window's last reset in the `history_rollups` hours. Rules
  (`HistoryReportReader.limitBlock`): candidates come from the fired hour and the hour before,
  keeping only resets at or after the block, and the earliest wins; if the primary dropped inside
  the fired hour and the candidate is not inside that hour, the value was overwritten and the
  reset is unknown; the width (`reset − window key`) must be positive and at least the lockout,
  else both go unknown; a missing rollup hour keeps the row and drops the duration. The width is
  rounded to the minute. (tests `testABlockThatOutlivesItsHourReadsTheResetFromThatHour`,
  `testABlockOnTheDoorstepTakesTheResetFromThePreviousHour`,
  `testARolledOverHourWithNoCandidateInsideItYieldsNoDuration`,
  `testAWindowKeyThatContradictsItsResetLosesBothFacts`,
  `testAMissingRollupHourKeepsTheBlockAndOmitsTheDuration`, `testTheDerivedWidthIsRoundedToTheMinute`)
- **Conclusion and Known consequence.** `3 recorded blocks · last Aug 17.` (per provider on `All`:
  `Claude 2 blocks · Codex 1 block · last Aug 17.`), beside `Known consequence`: the total known
  lockout, with the denominator named — `2 of 3 resets recovered. Longest 3h 25m on Aug 12.`,
  `All 3 resets recovered. Longest 3h 25m on Aug 12.` (the `Longest` sentence follows whenever
  more than one block has a known lockout), or `Unknown` with `No reset could be recovered.`
  With one block: `The reset was recovered.` or `Unknown` with `The reset could not be
  recovered.` No card without blocks. (`blocksConclusion`, `blockConsequence`; tests in `HistoryExperienceHardBlocksTests`)
- **Activity by hour.** 24 local-clock bars of displayed tokens with every block drawn as its own
  mark, shown only when a block's window is 6 hours wide or less and there is work to draw.
  Reason: a seven-day lockout is not about the hour it began. The caption describes only what is
  drawn (`Every block landed in the afternoon, though you work hardest in the evening.`).
  (`experienceHourChart`, `hourCaption`, `shortWindowSeconds`; tests
  `testChartStaysGatedOnAShortBlockingWindow`, `testEveryBlockIsItsOwnMarkAndTheCaptionDescribesTheDrawing`)
- **Pattern note.** `Most often 2–6 pm` only with 12 or more blocks and more than half of them in
  one 4-hour band, hours only, never weekdays; below that, `Not enough recorded blocks to call a
  typical time.` (`claimedRhythm`, `claimedRhythmFloor`; test `testPatternClaimStaysBehindTheFloor`)
- **Coverage note.** `Recorded since <date>, when Kvotar began watching. Weekly-only exhaustion
  may not appear, and an unknown reset means an unknown lockout, not zero.`; before any watching,
  `Recorded from the day Kvotar starts watching — nothing yet.` replaces the first sentence. The
  middle clause is out of date and is to be rewritten (*Decided*, item 1). (`coverageNote`)

### Allowance history and the work-per-1% display gate

`Allowance history` follows the investigation: per provider, a work-per-1% verdict, then the
recorded account changes. It is context near an event, never a claimed cause.
(`allowancePanel`; test `testAllowanceHistoryFollowsTheInvestigation`)

- **Change rows** are newest first: `Plan changed · <date>` → `go → plus`, `Window added`,
  `Window removed`, `Window changed`, `Reset early` → `weekly window`. A width change and a window
  added at the same instant fold into one `Windows changed` row (`weekly → 5-hour + weekly`).
  Identical facts collapse into one row with a count (`Reset early · 3× · <span>`). At most 5
  rows, then `Earlier changes` → `<n> more · <span>`. Widths only, never a size.
  (`allowanceChangeRows`, `changeEntries`, `changeParts`; test
  `testRepeatedIdenticalChangesCollapseIntoOneCountedRow`)
- **The verdict** reads the work-per-1% series from
  [capacity learning](capacity-learning.md#the-work-per-1-series); the gate on what may be said
  is this page's (`windowChangeSummary`, `qualifyingCycles`, `correctedRate`):
  - one slot only, the widest whole-cycle one (ties go to the weekly); Claude's five-hour
    per-day slot is never used, because its spread is noise;
  - a cycle qualifies when the window moved 10 points or more and at most 20 % of the rise had
    no local work behind it;
  - the rate shown is corrected for that unseen share (dollars per 1 % ÷ (1 − unseen share)),
    because the raw rate misorders the weeks;
  - with 3 or more qualifying cycles: `Nothing conclusive yet.` and the row `<Weekly> · <n>
    cycles since <date>` → `$<low> – $<high> of work per 1%` (or `about $<n> of work per 1%`), whole
    dollars; below 3: `Not enough history yet — no usable cycle | 1 usable cycle | <n> usable cycles since <date>.`; never watched:
    `Not enough history yet — Kvotar has not watched a full window.`
  - never `steady`, never `no sign of change`, never a size. Reason: the smallest change the
    series could detect is large, so a calm word would be a guarantee it cannot give.

  (tests `HistoryExperienceChartTests.testSummaryStatesTheVerdictWithACorrectedRangeOverQualifyingCyclesOnly`,
  `testEqualRoundedBoundsReadAsASingleFigure`, `testTooFewQualifyingCyclesCountThemAndShowNoFigure`,
  `testNeverWatchedSaysSoWithoutADate`)

## Two near-twins

- **History's *Weekly recap* versus the popover's idle recap.** See *Weekly recap*: a completed
  Monday–Sunday week here, the last ended five-hour window there.
- **History's window outcome versus the popover's `Last window ended at N%` line.** Two ideas,
  two owners. This page owns the fold, `QuotaWindowOutcomes` and its `QuotaWindowOutcome`:
  width, ending and completion, so a window watched only partly reads `Reached at least N% used ·
  Partial`. [explanations](explanations.md) owns the popover's `Last window ended at N%` line, built
  from `SQLiteStore.previousWindowOutcome`, a separate `WindowOutcome` with the high water and the
  first 100 % reading only and no coverage check. Both read `quota_series` by anchor with the same
  ±60 s rule; they can word the same window differently.

## Rejected alternatives

- **A period picker** (45, 60, 90 days or All). Token history reaches far back, poll-side records
  start at install and notification rows are deleted at 90 days, so a longer period would put two
  different reaches under one header. Revisit only for a need that longer token history alone
  meets.
- **A Summary dashboard as the default mode.** Its best conclusions sat below raw rows; the
  recap answers one question instead.
- **Current-week content, recap notifications, plan-right-sizing or provider-shrink claims** from
  utilization outcomes.
- **Quota outcomes as a grain of Explore usage**, a row ledger as the main quota view, side-by-side
  provider charts, hover-only evidence, a line through missing history or across a width change,
  invented idle windows, or the current window in completed statistics.
- **`at least N%` on the recap's weekly lines.** The asterisk carries the same honesty more
  plainly. Explore quota keeps `Reached at least`.
- **A combined token total, a full dashboard on the recap, and the five-hour window count in the
  recap** (it lives in Explore quota).
- **A block tally** (`Hit the limit 3×`). Blocks differ by minutes or hours of lockout; each gets a
  row.
- **Averaging a few blocks into a claimed rhythm, or a weekday axis.** Plot each block; claim only
  above the floor.
- **Output tokens or Est. token value for the hour bars.** A second definition of "work" on a page
  where every bar is displayed tokens.
- **Blocked days against your own median.** It reads as causation and is wrong about a six-minute
  block.
- **Standalone *What changed?* and *When do I work?* blocks.** The first is empty on most
  accounts and separates a change from what it explains; the second is a question nobody asked.
- **Deleting the flapping plan-change rows.** They are a true record of disagreeing sources; the
  read collapses them instead.
- **`steady` for the work-per-1% verdict, a bigger work-per-1% panel, or a separate evidence
  window.** The series measures; the display stays a short verdict.

## Known gaps

| Gap | Today | Proposed fix |
|---|---|---|
| Hard blocks depend on a notification switch | With Over quota notifications off, no block is recorded and History says there were none; nothing on the page says why | Owner's choice (Questions for owner, item 1). At minimum, have the coverage note say blocks are recorded only while Over quota notifications are on |
| Stale weekly-exhaustion copy and comment | The coverage note says weekly-only exhaustion may not appear; the `ToolReport.limitBlocks` doc says it "cannot" be there because the state engine ignores the weekly. The state engine now enters Over quota on a spent weekly (`StateEngine`, the secondary check) | Rewrite the coverage clause and the doc (*Decided*, item 1) |
| A weekly block may show the wrong reset (until verified) | `limitBlock` reads `primaryResetsAtLast` only, and the row's window key is built from the primary window, so a block driven by a spent weekly probably shows the five-hour reset as its lockout end. Unverified | Build a fixture of a block driven by a spent weekly; if confirmed, take the reset of the limit that caused the block |
| Stale "Summary · All" comments | `HistoryWindowController.show`, the History block in `AppDelegate`, `AppViewModel.onOpenHistory` and the `HistoryViewModelSelectionTests` header still say an ordinary open lands on Summary · All; it lands on Weekly recap. `HistoryExperience.AllowancePanel` still names a Summary title | Fix with the next change to each file |
| Dead `HistoryDisplay` helpers | `footer` (the old `evidence from <date>` footer), `changeFootnote` with `providerCutSentence`, `projectRows` and the private `work` have no caller; `ToolReport.evidenceFrom` is read only by the dead `footer`, tests and previews | Delete the helpers; then keep or drop `evidenceFrom` |
| The window's lifecycle has no test | `HistoryWindowController` (one window, close hides, reload on open and focus, frame autosave) is App-level and checked by hand | Add an App-level test that shows, closes and shows again and asserts one window and a reload each time |
| No ⌘W in the History window | The app window wires ⌘W and ⌘Q by hand because an accessory app has no app menu (`QuotaWindowController.installKeyMonitor`); the History controller wires nothing. Whether ⌘W closes History is untested | Check by hand; if it does nothing, add the same scoped key monitor |
| The hour chart's block marks and the pattern band use `Calendar.current` | The report's local days use the injected calendar; `experienceHourChart` and `claimedRhythm` read the system calendar directly | Pass the injected calendar through |
| "Last 30 days" wording oversells the poll-side half | The popover link reads `History · last 30 days` and the menu-item comment says "the last 30 days of the local corpus"; quota windows, blocks and changes start at the watching date | The label is [popover](popover.md)'s to decide; fix the comment with the next change to `MenuBarController` |
| Live diagnostics can read the live database | With `KVOTAR_LIVE=1`, several env-gated tests reach the real database file. `HistoryExperienceLiveDiagnostics` falls back to `SQLiteStore.defaultPath()` when `KVOTAR_LIVE_DB` is unset (`HistoryExperienceLiveDiagnostics.swift:18`) and opens it writable with migrations on, though its type comment says read-only. `ExplanationLiveDiagnostics` falls back the same way (`ExplanationLiveDiagnostics.swift:145`), then copies the file before opening it. Core `LiveDiagnostics` opens `SQLiteStore.defaultPath()` directly in four tests (`LiveDiagnostics.swift:31`, `:52`, `:129`, `:160`) and falls back to it in two more (`:201`, `:254`); only `testLiveQuotaWindowOutcomes` demands a copy (`:313`). `HistoryExperienceSnapshots` opens whatever `KVOTAR_LIVE_DB` names writable | Require an explicit database copy in every live test: skip unless `KVOTAR_LIVE_DB` is set and is not the live path, and open it with `readOnly: true, runMigrations: false` (`SQLiteStore.openReadOnly`) |
| The oldest, clipped recap week usually says nothing happened | On a clipped week the pattern and calm leads are withheld, so without a block or change the lead falls to `Nothing was recorded this week.` beside the week's own work. No test pins this lead | Give a clipped week its own lead (for example, name the coverage limit as the lead) and pin it with a test |
| `HistoryDestination.focus` is carried but never read | The projects hand-off sets `focus: .projects`; nothing reads it. The day's project rows show because the day is selected | Read it (scroll to the project rows) or drop the field |
| A comment names a release stage | `HistoryViewModel`'s selection comment ties "nothing persisted" to a release stage | Drop the stage from the comment |

## Code and tests

App: `App/HistoryWindowController.swift`; `App/AppDelegate.swift` (the History wiring);
`App/MenuBarController.swift` (`onOpenHistory`); `App/PollCoordinator.swift` (`historyReport`);
`App/QuotaSurfacePresenter.swift` (`closeActiveSurface`).

Core, under `Packages/KvotarCore/Sources/KvotarCore/`: `History/HistoryReport.swift`
(`HistoryReport`, `WeeklyLimitOutcome`), `History/HistoryReportReader.swift`,
`History/QuotaWindowOutcomes.swift`, `Storage/SQLiteStore+History.swift`; also read:
`SQLiteStore+QuotaSeries.swift` (`quotaSeriesRange`, `quotaSeriesSecondaryRange`),
`SQLiteStore+ModelLimitSeries.swift`, `SQLiteStore+StateTransitions.swift`
(`criticalStateEntries`), `SQLiteStore+Discontinuities.swift`, `SQLiteStore+Retention.swift`
(`historyRollups`), `State/PlanChangeStability.swift`, `Attribution/AttributionEngine.swift`
(`historyReport`). The series and project grouping files in `History/` belong to
[capacity learning](capacity-learning.md) and [local usage](local-usage.md).

UI, under `Packages/KvotarUI/Sources/KvotarUI/`: `Model/HistoryExperience.swift`,
`Model/HistoryDisplay.swift`, `Model/HistoryDisplay+Experience.swift`,
`Model/HistoryDisplay+Recap.swift`, `Model/HistoryDisplay+Quota.swift`, `Model/HistoryWeeks.swift`,
`Model/HistoryDestination.swift`, `ViewModel/HistoryViewModel.swift`, `Views/History/`
(`HistoryView`, `HistoryModeViews`, `HistoryQuotaChart`, `HistoryComponents`, `HistoryTheme`),
`Previews/HistoryPreviews.swift`.

Tests. Core (`Packages/KvotarCore/Tests/KvotarCoreTests/`): `HistoryReportReaderTests`,
`HistoryReportWeeklyLimitsTests`, `QuotaWindowOutcomesTests`, `PlanChangeStabilityTests`,
`NotificationGroupTests.testOverQuotaDisabledDropsOverQuota`. UI
(`Packages/KvotarUI/Tests/KvotarUITests/`): `HistoryExperienceContractTests`,
`HistoryExperienceRecapTests`, `HistoryExperienceQuotaTests`, `HistoryExperienceExploreTests`,
`HistoryExperienceHardBlocksTests`, `HistoryExperienceAllowanceTests`,
`HistoryExperienceChartTests`, `HistoryDayHoverTests`, `HistoryWeeksTests`,
`HistoryViewModelDestinationTests`, `HistoryViewModelNavigationTests`,
`HistoryViewModelSelectionTests`, fixtures in `HistoryExperienceFixtures`. App:
`QuotaSurfacePresenterTests.testCloseActiveSurfaceClosesWhicheverIsUp`.

Two env-gated harnesses are the only way to see the window without clicking; both skip by default
and are on the expected-skips list. `HistoryExperienceSnapshots` writes PNGs of every mode when
`KVOTAR_SNAPSHOT_DIR` is set; `HistoryExperienceLiveDiagnostics` prints every payload when
`KVOTAR_LIVE=1`. **Always set `KVOTAR_LIVE_DB` to a copy of the database** when running either
one, and only when the person you work for asks ([AGENTS.md](../../AGENTS.md)). Reason: with
`KVOTAR_LIVE=1` and no `KVOTAR_LIVE_DB`, the diagnostics harness falls back to the live file
(`SQLiteStore.defaultPath()`), and both harnesses open the database writable with migrations on
(`SQLiteStore(path:)` defaults), despite the diagnostics' "read-only" comment. Other live
tests share the fallback (see Known gaps).

Checked against the code at faa525f + STEP_271
