---
summary: How Kvotar puts a dollar figure on local token use — the bundled price table, its schema and version, how a model is matched to a price, what happens to a model with no price, the per-tool formula, the spans each figure covers, the value note's wording and why the figure is never called a cost.
read_when: Editing Resources/pricing.json (adding a model, changing a rate, re-stamping `updated` or `version`); changing EstimatedValueEngine, PricingTable or ModelPricing (PricingModels.swift), UnpricedModelCollector, SQLiteStore.tokenTotalsByModel or SQLiteStore+UnpricedModels.swift; changing the value rows or the value note in DisplayFormatter+LocalActivity.swift (isOrganizationPlan) or LocalActivitySection; a ShippedPricingTableTests failure (stale table, a promotional rate past its date); naming or wording any estimated dollar figure.
---

# Estimated value

## Questions for owner

None.

## Decided

The maintainer ruled on these on 2026-10-04 (STEP_264). The code does not follow them yet; each
has a row in *Known gaps* below, which a later build step closes.

1. **Remove `LocalAttribution.windowValue`.** Reason: no screen has read it since the popover's
   value rows became Today / 7-day / 30-day, and computing it costs a store read and a pricing pass
   on every attribution. Today: `AttributionEngine.attribution` prices the current quota window
   (window start to now) on every call; only tests and the live diagnostics test read the result.

## About this page

This page is the specification for pricing local token use. It replaces the private
Implementation Baseline §12 (Estimated token value engine) and §12.1 (Pricing table schema), and
the data and copy rules of the private UI Spec §2.5b (What it's worth · est. token value) and its
Part 2 mirror. Change this page in the same commit as the code it describes.

The term **Est. token value** is defined on
[product scope](product-scope.md#terms-a-newcomer-needs); this page does not redefine it.

IDs such as REV-nn or STEP_nnn in code comments are private record IDs;
[REFERENCES.md](../REFERENCES.md) explains them. The rules here stand without them.

What this page does **not** own:

| Topic | Page |
|---|---|
| Which local tokens are counted, from which session logs, and how double counting is removed | `local-usage.md` (pending) |
| The displayed token count, the cache-hit ratio and the Today population (local midnight to now) | `local-usage.md` (pending) |
| The monthly split that uses the priced local rate to tell an idle Mac from a busy one | `credits-and-monthly-limits.md` (pending) |
| The `$12.00` USD form and every other number form | [Display semantics](display-semantics.md#rounding-and-number-forms) |
| Where user-facing strings are built, and the copy rule | [Display semantics](display-semantics.md#where-strings-are-built) |
| The `unpriced_models` table's place among the tables, and what "permanent" means | [Storage](storage.md#tables-by-purpose) |
| How the plan string is decoded for each tool | [Claude account](claude-account.md#the-plan-string), [Codex account](codex-account.md#plan-types) |
| The History window's layout, recap and `≈` mark | `history.md` (pending) |
| The popover's sections and their order | `popover.md` (pending) |
| The hover-card text | `explanations.md` (pending) |
| The price-table line and the unknown-model list in a diagnostics bundle | [Diagnostics](diagnostics.md#save-diagnostics) |

## What the figure is

The estimated value prices this Mac's local token use at the providers' published per-token API
rates, standard tier. It answers "what would this work have been billed at the public API price",
never "what did you pay". Reason: a subscription has no per-token bill, and a dollar figure with no
stated yardstick is read against the monthly plan fee.

- **Always an estimate, in USD.** The figure is Kvotar's own arithmetic over a USD price list
  ([display semantics](display-semantics.md#rounding-and-number-forms): `Fmt.dollarValue`).
- **Never called a cost.** The label is `Est. token value` or the section title
  `LOCAL ACTIVITY · ESTIMATED VALUE`; never `Cost`
  ([PATTERNS.md](../../PATTERNS.md#naming-conventions-baseline-4); `HistoryExperienceContractTests.testNoRenderedStringUsesRetiredVocabulary`).
  The ban is on "cost" as the figure's label or noun. Conditional wording that states the
  counterfactual, such as the hover card's "would have cost if you paid per token", may stay
  (`ExplanationRegistry`, `.estTokenValue`). The maintainer confirmed this rule on 2026-10-04.
  Real money a provider reports is a different thing with its own form (`Fmt.money`) and its own
  page (`credits-and-monthly-limits.md`, pending).
- **Computed locally.** Prices come from the bundled table; no tool such as ccusage runs at
  runtime ([PATTERNS.md](../../PATTERNS.md) Do / don't table).

## The price table

`Resources/pricing.json` is the only source of prices. It is bundled into the app target, not into
the `KvotarCore` package (`project.yml`, `Kvotar` sources), and loaded once at start by
`EstimatedValueEngine.loadPricingTable` from `AttributionEngine.start`. There is no remote fetch.
Read the file for the current rates; this page does not copy them.

### Schema

Top level (`PricingTable`):

| Key | Meaning |
|---|---|
| `version` | The table's own version string. Shown in the History footer (`prices v…`) and in a diagnostics bundle, so a figure can be traced to the table that produced it. Nothing compares versions |
| `updated` | The date every rate was last checked against the providers' pages, `yyyy-MM-dd`, read as UTC |
| `models` | Exact model string → one row |
| `fallback` | `claude` and `codex` → one row each, used when a model has no usable row |

A row (`ModelPricing`) holds rates in USD per million tokens. Every field is optional; a missing
rate prices that token type at zero.

| Field | Claude rows | Codex rows |
|---|---|---|
| `provider` | `claude` (model rows) | `codex` (model rows) |
| `input_per_mtok`, `output_per_mtok` | Yes | Yes |
| `cache_write_5m_per_mtok` | 1.25 × input | Never |
| `cache_write_1h_per_mtok` | 2 × input | Never |
| `cache_creation_per_mtok` | Never in the shipped table; read only as the 5-minute rate from an older table | The one cached-input rate |
| `cache_read_per_mtok` | The cache-read rate | The same cached-input rate again |
| `currency` | `USD` | `USD` |

Fallback rows carry no `provider`; the key says which tool they serve.

Why the two tools differ:

- **Claude charges two cache-write tiers**, 1.25 × input for a 5-minute write and 2 × input for a
  1-hour one. A single write rate underpriced the common 1-hour write. The untiered field is gone
  from Claude rows because two fields holding one rate drift apart
  (`ShippedPricingTableTests.testClaudeRowsCarryBothCacheWriteTiersAtTheirPublishedMultiples`).
- **OpenAI publishes one cached-input rate and no write charge.** A Codex row carries that rate
  in both cache fields, because stored Codex rows keep the cached count in either column depending
  on when they were written (`ShippedPricingTableTests.testCodexRowsCarryOneCachedRateInBothColumns`,
  `testCodexRowsCarryNoCacheWriteTier`).
- **There is no reasoning rate.** Both providers bill reasoning as output once; a separate rate
  would charge it twice (`ModelPricing` has no such field).

### Rules for editing the table

Each is enforced by `ShippedPricingTableTests`, the only unit tests that open the shipped file.

| Rule | Reason | Test |
|---|---|---|
| The file decodes and has a `claude` and a `codex` fallback | A missing fallback prices every unknown model at zero | `testShippedTableDecodes` |
| No rate is negative | A negative rate credits the user | `testEveryShippedRateIsNonNegative` |
| No row is all zero or all missing | It would show real work as free, and a zero local rate makes an active Mac look idle to the monthly split | `testNoShippedRowIsEntirelyNull` |
| Claude write tiers are exactly 1.25 × and 2 × the row's own input rate | A rate edit cannot leave the write rates behind | `testClaudeRowsCarryBothCacheWriteTiersAtTheirPublishedMultiples` |
| Claude cache reads are 0.1 × input, except the models the test names by name | The exceptions cannot be re-derived from a multiple, so each is pinned | `testClaudeCacheReadsAreATenthOfInputExceptOnFable51Mythos51AndOpus55` |
| Codex cached rate is below the input rate | Otherwise splitting the input term does nothing | `testCodexCachedRateIsBelowInputRate` |
| The models this project runs have exact rows | They were once priced at the fallback | `testModelsObservedOnThisMachineHaveExactRows` |
| `updated` is a real date and `version` is not empty | The age check needs a date | `testUpdatedParsesAsADate` |
| `updated` is at most 90 days old (`PricingTable.stalenessLimitDays`) | No provider publishes an effective date, so a silently changed rate is caught only by re-checking on a schedule. This test fails on a clock, on purpose | `testShippedTableIsNotStale`, `testStalenessBoundary`, `testUnparseableUpdatedReturnsNil` |
| A promotional rate with an end date has a dated test | The 90-day check alone would fire after the promotion ends | `testSolPromotionalRateIsStillWithinItsGuaranteedWindow` |

When the age test fails: re-check every rate against the providers' published pricing pages,
correct any row that moved, set `updated` to the check date, and bump `version` if any rate changed
(`ShippedPricingTableTests.testShippedTableIsNotStale` comment). Add a row for every model either
provider publishes with a full rate set, including retired ones, because the local history is
permanent and is priced again whenever History opens. A model string is its own key: an alias or a
dated variant needs its own row.

## Matching a model to a price

`EstimatedValueEngine.resolvePricing`:

1. **No table loaded** (file missing or undecodable): no row. Every figure is $0. One warning is
   logged at load (`loadPricingTable`; `EstimatedValueEngineTests.testMissingPricingResourceLogsWarningAndDoesNotCrash`).
2. **Exact string match** on the model string the session log reported. No normalisation. Reason:
   a fuzzy match would price a new model at a neighbour's rate without anyone noticing.
3. **The row's `provider` must equal the requesting tool.** A row from the other provider is
   treated as no match. Reason: a match is not a miss, so a cross-provider match would never be
   logged (`testResolvePricingRefusesARowFromAnotherProvider`,
   `testResolvePricingAcceptsAMatchingProvider`). A mismatch logs its own warning once, then
   falls through to step 4, which logs the miss as well. A row with no `provider` is accepted
   (`testResolvePricingAcceptsARowWithNoProviderDeclared`).
4. **Otherwise the tool's fallback row.** A known model string that missed is collected as
   unpriced (below) and logged once per tool and model per process (`PricingWarningLog`;
   `testUnpricedModelWarnsOncePerProviderAndModel`). A missing model string uses the fallback
   silently, since there is nothing to have missed (`testNilModelUsesProviderFallbackWithoutExactMatchAttempt`).
5. **No fallback for the tool:** no row, and that model's value is $0. A known model string is
   still recorded in `unpriced_models`, but no warning is logged: the collector runs before the
   fallback check, the warning after it
   (`testMissingModelAndMissingFallbackNeverThrowsReturnsZero`;
   `HistoryReportReaderTests.testDayModelValuesMarkFallbackPricing`).

Each fallback row is a real model's published rates, not a padded guess (today they match a Sonnet
row for Claude and `gpt-5.4` for Codex; no test pins this). Reason: a miss should stay visible as a
miss, not produce a more plausible wrong number (see *Rejected alternatives*).

`EstimatedValueEngine.isPricedAtFallback` answers the same question without side effects, for the
History window's `≈` mark. Two edge cases differ: with no table loaded it answers false, and for a
tool with no fallback row it answers true although the value is $0 (`HistoryReportReaderTests.testDayModelValuesMarkFallbackPricing`).

## Unpriced models

Every `(tool, model)` pair priced at the fallback is recorded, so a maintainer learns which row to
add. A log line rotates away; the record stays.

- `UnpricedModelCollector` buffers pairs in memory with first seen, last seen and a count
  (`UnpricedModelsTests.testFallbackMissIsCollected`, `testExactMatchIsNotCollected`,
  `testRepeatObservationsMergeInTheCollector`).
- `PollCoordinator` drains the buffer once per poll cycle and merge-upserts it into
  `unpriced_models` (`SQLiteStore.upsertUnpricedModels`): a new pair inserts, a known pair widens
  its span and adds to its count (`testFirstObservationWritesExactlyOneRow`,
  `testSecondObservationMergesRatherThanInserts`, `testDrainedBatchLandsAsMergedRow`). A failed
  write drops the batch; the next miss records the pair again.
- The same model under two tools is two rows (`testSameModelUnderTwoProvidersIsTwoRows`). A
  provider mismatch is recorded under the raw model string and the requesting tool
  (`testProviderMismatchIsCollectedUnderRawString`).
- **Strings that are not models are never recorded:** `<synthetic>` (Claude Code's zero-token
  placeholder for a turn that never reached the API) and `codex-auto-review` (Codex's internal
  approval reviewer) (`UnpricedModelCollector.knownNonModels`;
  `testKnownNonModelsAreObservedButNeverRecorded`). They are still priced at the fallback. A
  missing model string records nothing (`testNilModelRecordsNothing`).
- The table is permanent ([storage](storage.md#permanent-means-permanent)). A row means "was seen
  at the fallback", not "still missing": after a row is added to `pricing.json`, the pair's count
  stops rising. A diagnostics bundle lists the pairs
  ([diagnostics](diagnostics.md#save-diagnostics)).

## The formula

Inputs are per-model token totals from `SQLiteStore.tokenTotalsByModel`. Which events those totals
contain is `local-usage.md`'s (pending). The query groups by the event's own model and falls back
to the session's model for older rows that carry none, so a session that switched models prices
each slice at its own rate (`SQLiteStoreEstimatedValueTests.testMultiModelSessionPricesEachSliceAtItsOwnModel`,
`testNullModelRowFallsBackToSessionModel`).

Each model's totals are priced on their own and the results are summed
(`EstimatedValueEngine.value(for:provider:table:)`). Rates are per million tokens.

**Claude** — four disjoint quantities, each at its own rate:

```
input × input_rate
+ output × output_rate
+ (cache_creation − cache_creation_1h) × write_5m_rate
+ cache_creation_1h × write_1h_rate
+ cache_read × cache_read_rate
```

- The 1-hour write count is a subset of the cache-creation total, clamped to it, so the 5-minute
  part is never negative (`testOneHourSliceAboveTheTotalIsClamped`, `testMixedTiersPriceEachSliceAtItsOwnRate`).
- A row stored without the split counts as all 5-minute (the query sums a missing split as zero);
  these older rows are not backfilled (`testUnknownSplitPricesExactlyAsBefore`;
  `SQLiteStoreEstimatedValueTests.testCacheWriteTierRoundTripsAndUnknownSplitsFallToFiveMinute`).
- With no 5-minute rate, `cache_creation_per_mtok` is used; with no 1-hour rate, the 5-minute
  rate is used. Reason: an older table must price writes at its old rate, never at zero
  (`testALegacyTableWithoutTierFieldsStillPricesCacheWrites`, `testClaudeStillPricesAllFourColumnsSeparately`).

**Codex** — the cached count is part of input, not extra:

```
max(0, input − cached) × input_rate
+ cached × cached_rate
+ output × output_rate
```

- `cached` is the sum of both cache columns, because stored rows hold it in one or the other,
  never both (`SQLiteStore.ModelTokenTotals.codexCachedInputTokens`;
  `testCodexCachedSliceIsReadFromEitherCacheColumn`).
- `cached_rate` is `cache_creation_per_mtok`, else `cache_read_per_mtok`, else zero
  (`testNullCacheRateOnCodexContributesZeroForTheCachedSlice`).
- The uncached remainder is clamped at zero, so a payload with more cached than input tokens
  cannot credit the user (`testCodexUncachedRemainderIsClampedAtZero`).
- The Claude write tiers never apply to Codex (`testCodexIsUntouchedByTheTierSplit`).

Not modelled: service tiers other than standard (batch and flex cannot serve interactive use;
fast mode is an opt-in premium), long-context surcharges, regional uplifts.

## Spans and where each figure shows

| Figure | Span | Where | Code |
|---|---|---|---|
| Today | Local midnight to now, the Today population of the popover's local section | Popover value rows, `Today` | `DailyLocalReportReader` (priced per project and model), `DisplayFormatter.localActivitySection` |
| 7-day | Rolling: the last 604,800 seconds to now | Popover value rows, `7-day` | `EstimatedValueEngine.estimatedValue(for:)` `.weekly` |
| 30-day | Rolling: the last 2,592,000 seconds to now | Popover value rows, `30-day`; Codex credits section (raw plan `enterprise`, full form) | `.thirtyDay` |
| Today (engine) | Local midnight (`Calendar.current`) to now | Codex credits section (raw plan `enterprise`, full form), `Est. token value · today` | `.today` |
| Per day, per model | Each local day of the History period | History window | `HistoryReportReader` |
| One session | One session's events, per event model | History window | `EstimatedValueEngine.value(for:tool:)` over session totals |
| Local rate | The trailing 8 minutes, in $/min | Not shown; the monthly split's idle test (`credits-and-monthly-limits.md`, pending) | `AttributionEngine.localValuePerMin` |
| This quota window | Window start (or its fallback: the latest session start, else now − 5 h) to now | Not shown; to be removed (Decided 1) | `LocalAttribution.windowValue` |

- **The 7-day and 30-day figures are rolling, not tied to any quota window.** They cover the last
  7 × 24 and 30 × 24 hours, not calendar days. Reason: they show a trend. (The hover card's
  wording differs; see *Known gaps*.)
- **One pricing path.** The popover, History and the daily report all price through the one
  `EstimatedValueEngine` that `AttributionEngine` owns, so two surfaces cannot load different tables
  and disagree about a dollar (`AttributionEngine.historyReport`, `dailyReport`).
- **A missing input shows `—`, not `$0.00`** in the popover value rows: `Today` with no report,
  7-day and 30-day with no attribution (`DisplayFormatter.localActivitySection`). There is no
  attribution when there is no current session, nothing priced in 30 days and no surface share
  (`AttributionEngine.attribution`), so a quiet tool often reads `—` there. A loaded engine with
  nothing to price returns $0, which `Today` shows as `$0.00`.
- **The rows render on every plan, Enterprise included.** Reason: a list-price estimate of local
  work answers a different question from an organization's own money meter
  (`DisplayFormatterLocalActivityTests.testValueRowsRenderOnEveryPlanIncludingEnterprise`).
- **Per-row "est." where real and estimated money share a section.** The Codex credits section
  shows real credits beside the estimate, so its value rows read `Est. token value · today` and end
  in ` est.` (`DisplayFormatterTests.testCodexEnterpriseCreditsCard`). The popover's value section
  is all estimate, so the title carries it once.

## The value note

A fixed line under the popover's value rows names what the number is measured against.

| Plan | Note |
|---|---|
| Personal plans | `Based on published API rates in USD. Not your spend or bill.` |
| Organization plans | `Based on published API rates in USD. Not your organization’s spend or bill.` |

(`LocalActivitySection.valueNote`, `organizationValueNote`)

**"Organization pays" is decided by `DisplayFormatter.isOrganizationPlan`** in
`DisplayFormatter+LocalActivity.swift`: true when the plan's display name is `Team`, `Business` or
`Enterprise` (`planDisplayName`, which maps the raw strings for both tools). Education is not an
organization plan: a student's plan is their own
(`DisplayFormatterLocalActivityTests.testValueNoteNamesTheOrganizationOnSeatPlans`). No plan
means the personal note (`isOrganizationPlan`; untested). Reason:
on a seat someone else pays for, "your spend" is wrong.

The History window uses its own fixed line, `Priced at published API rates for each model. Not a
bill.` (`HistoryDisplay.pricingNote`, `HistoryDisplay.recapNotABill`); its layout is `history.md`'s
(pending).

## Rejected alternatives

- **A higher Claude fallback so a miss "errs high".** Not a published rate, and it turns a miss
  into a more plausible wrong number. The answer to a miss is to detect it (*Unpriced models*).
- **Billing a promotional rate at the expected list price.** The table carries the rate billed
  today; a dated test forces the re-check instead.
- **A separate reasoning rate.** Reasoning is billed as output once; the field was a double-charge
  trap and was deleted.
- **One Claude cache-write rate.** Most writes are 1-hour, so one rate understated the value.
- **Rows for models with no published cached-input rate.** Inventing a rate is what the table
  forbids, and a missing one fails the Codex cached-below-input rule.
- **A value-versus-plan-price ratio, or asking the user their plan price.** The plan tier is not
  always detectable and the maintainer ruled the question out; the note names the yardstick instead.
- **Calling the figure `API-equivalent`, or `Cost`.** Interpretation the figure cannot support;
  `Est. token value` is the one label.
- **A runtime dependency on ccusage.** Prices are computed locally from the bundled table.
- **Backfilling the cache-write split on older rows.** Declined; they keep the 5-minute price.

## Known gaps

| Gap | Today | Proposed fix |
|---|---|---|
| A missing or unreadable price table shows `$0.00` | `loadPricingTable` logs one warning; every figure is then $0. `Today` reads `$0.00`, and the 7-day and 30-day rows read `$0.00` whenever an attribution exists (a current session or a surface share), which reads as "no work" | When `tableStamp()` is nil, show `—` in the value rows; a test with an empty bundle |
| No check that every model seen locally has an exact row | The record had a coverage check over the local database; this repository has none. A miss shows only in `unpriced_models`, the log and a diagnostics bundle | A `kvotar` CLI line or a debug-log summary listing unpriced pairs whose count rose recently |
| `currency` is decoded and never read | Every rate is assumed USD; a row in another currency would be summed as dollars | A `ShippedPricingTableTests` case asserting `USD` on every row |
| Claude Team seats get the personal note | `planType(from:)` never yields `team`, so `isOrganizationPlan` is false on a Claude Team seat | Close the [Claude account](claude-account.md#known-gaps) row "Team plan string not decoded" |
| The 7-day and 30-day hover card says "calendar days" | `ExplanationRegistry` `.rollingHorizons` says "the last 7 and 30 calendar days"; the figures are rolling 7 × 24 and 30 × 24 hours | Say "the last 7 and 30 days" in the card, with `explanations.md` (pending) |
| `windowValue` computed and unread | One store read and pricing pass per attribution, no reader | (Decided 1) Remove the field, its computation in `AttributionEngine.attribution`, and the test and live-diagnostics uses |
| Two dollar forms for the estimate | History's recap rounds to whole dollars at $10 and above (`HistoryDisplay.recapDollars`); [display semantics](display-semantics.md#rounding-and-number-forms) lists only `$12.00` | Record the recap form on display semantics with `history.md` |
| Stale code comments | `PricingTable.version` says it "enables future remote-fetch conflict resolution"; no fetch exists. `EstimatedValueEngine.WindowValue` and `LocalAttribution.windowValue` comments describe a `This window` row that is gone | Fix with the next change to each file |

## Code and tests

Under `Packages/KvotarCore/Sources/KvotarCore/`: `Pricing/PricingModels.swift` (`PricingTable`,
`ModelPricing`), `Pricing/EstimatedValueEngine.swift` (`EstimatedValueEngine`,
`PricingWarningLog`, `UnpricedModelCollector`), `Storage/SQLiteStore+EstimatedValue.swift`
(`tokenTotalsByModel`, `ModelTokenTotals`), `Storage/SQLiteStore+UnpricedModels.swift`,
`Attribution/AttributionEngine.swift` (owns the engine; `localValuePerMin`),
`Attribution/DailyLocalReportReader.swift`, `History/HistoryReportReader.swift`. The drain:
`App/PollCoordinator.swift`. The table: `Resources/pricing.json`, bundled by `project.yml`.

Under `Packages/KvotarUI/Sources/KvotarUI/Model/`: `DisplayFormatter+LocalActivity.swift`
(value rows, `isOrganizationPlan`), `LocalActivitySection.swift` (title and notes),
`DisplayFormatter.swift` (`Fmt.dollarValue`, `planDisplayName`, the Codex credits rows).

Tests in `Packages/KvotarCore/Tests/KvotarCoreTests/`: `EstimatedValueEngineTests`,
`ShippedPricingTableTests`, `SQLiteStoreEstimatedValueTests`, `UnpricedModelsTests`,
`HistoryReportReaderTests`. In `Packages/KvotarUI/Tests/KvotarUITests/`:
`DisplayFormatterLocalActivityTests`, `DisplayFormatterTests.testCodexEnterpriseCreditsCard`,
`HistoryExperienceContractTests.testNoRenderedStringUsesRetiredVocabulary`.

Checked against the code at bb1c574 + STEP_264
