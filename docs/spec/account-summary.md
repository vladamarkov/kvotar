---
summary: The popover's account summary — which limit leads the header (the hero), its number, caption and meter, the verdict lines outside the monthly family, the hero's detail lines, the two header facts and their display gate, the long-limit strip, model warnings, the OTHER LIMITS rows and model groups, the plan badge and email, and the quota source tag.
read_when: Changing DisplayFormatter.selectLimit, AccountLimitSelection, AccountLimitCandidate, HeroReason, LimitStatus, HeaderSection, HeaderVerdict or VerdictFamily (outside the monthly family), HeaderFact, ModelLimitWarning, LongLimitStrip, OtherLimitRow, OtherLimitsSection; DisplayFormatter.header, headerVerdict, overQuotaVerdict, verdictRemovedAsNotStarted, longLimitScopesPrimary, limitCaption, heroDetailLines, headerFacts, burnHasDisplayEvidence, burnTier, longLimitStrip, modelLimitWarnings, otherLimitsSection, planDisplayName, sourceTag; HeaderSectionView (not its anatomy code) or OtherLimitsSectionView; which limit the popover leads with, a verdict sentence, a header fact, the strip, a model warning or an OTHER LIMITS row.
---

# Account summary

## Questions for owner

1. **"Spend control": a state or a condition?** This page meets the term once: the verdict row
   `Spend limit reached` is chosen by the *state* Spend control ([state](state.md#the-states)),
   while [credits and monthly limits](credits-and-monthly-limits.md#spend-control-as-a-condition)
   uses the same words for the *condition* (the pool is reached). Today's code is described below
   as it is; which page's meaning the word keeps is open with the other pages.

## About this page

This page is the specification for the **account summary**: the header at the top of each tool's
tab and the `OTHER LIMITS` section under it. It covers **display only**: which limit is shown,
in which words and colours. How a provider's payload becomes a reading, including plan strings
and model allowances, is [Claude account](claude-account.md) and
[Codex account](codex-account.md). The same view shows in the app window, which draws the
popover's content unchanged ([app lifecycle](app-lifecycle.md#when-the-app-window-opens-and-closes)).

It replaces the private Implementation Baseline §15.2 (the selected-limit contract, the scope of
header facts, the display half of independent model windows) and §15.3 (readability and the
separate model warning); the private UI Spec's top-level popover-contract and readability
amendments (their header and `OTHER LIMITS` parts), Part 1 §2.2 (header section), the non-monthly
rows of Part 1 §2.2a (runway verdict templates), the verdict layout left in Part 1 §0.4, and
Part 2 §2.2 and §2.3 (Codex header and account-quota section); and the decision records behind
them. Change this page in the same commit as the code it describes.

What this page does **not** own:

| Topic | Page |
|---|---|
| The popover frame: tabs, phases, section order, the recommendation, the Codex notes card, local activity, sizing | [popover](popover.md) |
| Hover cards on every element, the verdict's anatomy (click to pin), the "since you last looked" line. Their view code sits in `HeaderSectionView` (the peek and pin state, `VerdictAnatomyView`) | [explanations](explanations.md) |
| The monthly verdict family, the monthly meta line, the monthly strip's amounts, the monthly header facts, the organization credits line | [Credits and monthly limits](credits-and-monthly-limits.md#the-monthly-layout) |
| States, ranks, the long-limit tiers, hard blocks, block episodes, the model-warning constant | [State](state.md) |
| Burn, runway, the pace clock and the exhaustion data | [Forecast](forecast.md) |
| The `Not seen locally` estimate itself | [Local usage](local-usage.md#the-elsewhere-estimate) |
| Percent left, rounding, colours, unknown and stale wording, clocks and countdowns, the copy rule | [Display semantics](display-semantics.md) |
| Not-started, expired and withdrawn windows; window names; rule W | [Quota readings](quota-readings.md) |
| The menu-bar string, its runway slot and the long-limit reminder | [menu bar](menu-bar.md) |

## The seam with the popover frame

**One selection per render.** `claude()` and `codex()` build one `AccountLimitSelection` and hand
it to the header, its two facts and `OTHER LIMITS`. All three read it, so they cannot name
different limits. The hero and the `OTHER LIMITS` rows are two parts of one result: every limit is
either the hero or a row, exactly once. (`DisplayFormatter.claude`, `codex`;
`AccountLimitSelection.others`; test
`AccountLimitSelectionTests.testMainWeeklyOnlyPlusSparkPreservesAllThreeWindows`)

The summary meets the rest of the popover through two optional fields on each tool's display
state: `header` (`HeaderSection`) and `otherLimits` (`OtherLimitsSection`). Everything from the
top of the header to the last `OTHER LIMITS` row is this page's; where those two sit in the
section order is [popover](popover.md)'s. (`ClaudeDisplayState`, `CodexDisplayState`;
`ClaudePopoverContent`, `CodexPopoverContent`)

## Which limit is the hero

**Candidates are only what the provider sent.** A missing window makes no candidate and no row.
The candidates are the primary window, the secondary (weekly) window, the monthly meter, and
each window of each model allowance that carries a used percent or a reset. A model window with
only a width is an expired one and is dropped. (`selectLimit`; tests
`testNoLimitsYieldsNoHero`, `testExpiredModelWindowIsNotACandidate`)

- **The primary slot is kept even when empty,** so a null, expired or withdrawn primary still
  shows as the `——` placeholder. The one exception is the monthly layout: with no primary used
  percent and a monthly meter, the primary makes no candidate and the meter leads
  ([credits](credits-and-monthly-limits.md#the-monthly-layout)).
- **A Codex weekly-only account is not a missing primary.** Its weekly *is* the primary slot and
  leads as `Weekly quota left`. (test `testWeeklyOnlyMainAllowanceIsThePrimaryHero`)

**The hero is chosen in this order** (`selectLimit`, `HeroReason`):

| Step | When | Hero | `HeroReason` |
|---|---|---|---|
| 1 | A hard block with a [block episode](state.md#blocks-are-episodes) | The limit that blocks: primary, weekly or monthly | `blocked(limitIdentified: true)` |
| 2 | Spend control with no episode | The monthly meter, else the primary | `blocked(…)`, identified only with a meter |
| 3 | Over quota with no episode | The primary, else the monthly | `blocked(…)`, identified only when the primary reads 100 % |
| 4 | Stale, Idle or Null window | The primary slot, else the monthly | default |
| 5 | A five-hour warning state (Elevated, At risk, Bad timing, Fast burn spike, Off-machine burn, Multi-surface) | The primary | `stateWarning` |
| 6 | Otherwise | The primary; else the monthly | default |

Why the order:

- **Only the limit that stops you leaves the primary.** A spent weekly used to sit a row down while
  the header showed a five-hour window with room. Since a block takes the hero, the number, the
  verdict and the reset all name the limit holding the user. A stale block keeps its hero, since a
  block survives staleness ([state](state.md#what-is-not-inferred-from-incomplete-evidence)).
  (tests `testASpentWeeklyTakesTheHeroAndGreysTheFiveHour`,
  `testSpendControlIsTheMonthlyBlockWhereAMeterExists`,
  `testOverQuotaKeepsThePrimaryAndSaysWhetherTheLimitIsIdentified`)
- **A hot weekly or monthly does not take the hero.** Limit nearly spent and Limit ahead of pace
  keep the primary; the long limit speaks through the strip (below). (tests
  `testANearlySpentWeeklyDoesNotTakeTheHero`, `testHeldLongLimitRankKeepsThePrimaryHero`,
  `testNearCapMonthlyIsNotPromotedOverAPopulatedWindow`)
- **A five-hour warning keeps the primary** because it carries the validated forecast. (test
  `testPrimaryWarningStateKeepsThePrimaryOverAHotWeekly`)
- **Nothing is chosen from frozen or absent data.** Stale, Idle and Null window keep the primary
  slot. (test `testStaleWithholdsStatusExceptTheKnownBlock`)
- **A model allowance is never the hero,** even when spent or the only one with a value. It shows
  as a model warning and in `OTHER LIMITS`. A model limit stops one model, and a header about it
  would read as the whole account stopped. (test
  `testModelOnlyWarningNamesTheModelAndKeepsTheAccountHero`)

In practice the weekly leads only in a block: the primary slot exists whenever no monthly meter
does, so the code's final "weekly" fallback is never reached (Known gaps).

**Only a primary hero carries burn and runway.** `ForecastEngine` measures the primary series
alone, so a weekly or monthly hero inherits no runway and the exhaustion verdict needs a primary
hero. (`AccountLimitSelection.forecastApplies`; `exhaustionRunwayMinutes`;
[forecast](forecast.md#runway))

## The hero, caption and meter

- **The number** is the hero's percent left, bare
  ([display semantics](display-semantics.md#one-convention-the-number-says-what-is-left)). It is
  the menu bar's figure except while the bar shows a long limit instead ([menu bar](menu-bar.md)). At or past
  100 % used it reads `0%`; there is no overflow, and the used figure lives only in the hover
  card's bridge line ([explanations](explanations.md)). With no
  value it is the `——` placeholder, drawn smaller and muted so it never reads as a number.
  (`header`: `heroText`; `HeaderSectionView`: `heroIsPlaceholder`)
- **The caption** under it names the limit (`limitCaption`):

| Hero | Caption |
|---|---|
| Primary or weekly window | `[name] quota left`: `5-hour quota left`, `Weekly quota left`, or the window name from its width ([quota readings](quota-readings.md#limits-and-windows)). A Codex primary with no named width reads `Window quota left` |
| Monthly money meter (Claude) | `Monthly spend limit left` |
| Monthly credits meter (Codex) | `Monthly usage limit left` |

- **The meter** drains: its fill is what is left, empty at no value and at or past 100 % used; no
  overflow stripe. (`header`: `progress`; test
  `DisplayFormatterV46Tests.testHeaderOverQuotaReadsZeroLeftOverAnEmptyBar`)
- **The number and the meter take the state's colour,** with one exception. While a long-limit
  rank (Limit nearly spent, Limit ahead of pace) holds and the hero is not that long limit, they
  are green: they describe the five-hour window, which is fine. The account's colour then lives in
  the strip, the tab dot and the menu-bar dot. One predicate, `longLimitScopesPrimary`, drives this and
  the verdict's colour, so the two cannot disagree. (`header`: `heroCue`; tests
  `LongLimitSurfaceAgreementTests.testTheHeroInkFollowsTheLimitInTheHeaderNotTheAccount`)
- VoiceOver hears the status word on the number; the meter is hidden from it, since it adds no
  fact. (`HeaderSectionView`)

## Verdict lines outside the monthly family

Two lines under the caption. Line 1 is the verdict, in advice voice; line 2 is the numbers behind it,
in data voice, in a fixed token order ([voice](display-semantics.md#voice)). Line 2 is `—` where
nothing is known, and absent where a row has no numbers to add. (`headerVerdict`,
`overQuotaVerdict`; `HeaderVerdict`, `VerdictFamily`)

**Colour** is the state's own dot, never a recomputed threshold, except the green of the
long-limit exception above. Condition rows (sign-in, reconnecting, unknown, idle) are grey.

**First match wins:**

| # | Case | Line 1 | Line 2 |
|---|---|---|---|
| 1 | Monthly layout (a monthly meter and no primary value) | The monthly family: [credits](credits-and-monthly-limits.md#the-hero-and-its-lines) | |
| 2 | State Spend control | `Spend limit reached` | `—` |
| 3 | No primary value (Null window, or the primary is unknown): sign-in expired | `Claude sign-in expired — open Claude Code to reconnect.` (grey) | `—` |
| 3a | … polls refused | `Reconnecting…` (grey) | `—` |
| 3b | … the window expired while stale, or rule W retracted it | `—` (grey) | `—` |
| 3c | … otherwise (a fresh provider-null window) | `No active session` (Claude) / `No active window` (Codex) | `—` |
| 4 | Idle with a cached value: polls refused | `Reconnecting…` (grey) | `—` |
| 4a | … otherwise | `—` (grey) | `—` |
| 5 | Over quota, or the primary at 100 % or more | The block rows below | |
| 5a | A monthly hero over a populated window | The monthly family. No path reaches this row today: spend control (row 2) wins first (Known gaps) | |
| 6 | Codex low-allowance shape | **No row** | |
| 7 | The primary hero has not started | **No row** | |
| 8 | Exhaustion before the reset (`exhaustionRunwayMinutes`) | `Won't make it — slow down or you'll stop in ~[runway]`; Claude with credits off or their cap spent: `Won't make it — you'll be blocked in ~[runway]` | `stops ~[clock] · resets [clock] · runway ~[runway]` |
| 9 | A window a day or wider, fresh, with a reset: a warning colour still held | `Was on track to run out — safe if this pace holds` | none |
| 9a | … the pace clock fires | `Above pace — [used]% used` | none |
| 9b | … otherwise | `On pace` | none |
| 10 | A runway and a reset ahead: a warning colour still held | `Was on track to run out — safe if this pace holds` | `resets [clock] · in [countdown] · runway ~[runway]` |
| 10a | … margin under 30 min | `Safe, barely — reset beats you by ~[margin]` | same |
| 10b | … a long-limit rank holds | `Safe at this pace — [window] reset comes first` | same |
| 10c | … otherwise | `Safe at this pace — reset comes first` | same |
| 11 | No burn rate yet | `Measuring…` | `resets [clock] · in [countdown]`, or `—` |
| 12 | Otherwise: a burn rate exists but no row above applied (meant for a measured zero) | `Nothing burning` | `no burn · resets [clock] · in [countdown]` |

(Tests: the `testVerdict` cases of `DisplayFormatterV46Tests`, among them
`testVerdictHealthyResetsFirst`, `testVerdictExhaustsBeforeResetRedInCriticalState`,
`testVerdictNoBackstopBlocksBeforeReset`, `testVerdictMeasuringWhenBurnUnknown`,
`testVerdictNothingBurningWhenRunwayInfinite`, `testVerdictNullWindowByTool`,
`testVerdictIdleAndSpendControl`, `testVerdictThinMarginBoundary`,
`testVerdictHeldWarningTakesDeEscalationRow`, `testVerdictWeeklyBurstUnderPaceReadsOnPace`,
`testVerdictWeeklyOverPaceIdleReadsAbovePaceCalm`, `testVerdictWeeklyHeldWarningDropsDetailLine`,
`testNearlySpentWeeklyScopesTheFiveHourVerdict`;
`DisplayFormatterTests.testRateLimitedFreezeRendersReconnectingOverIdleDashesWithCachedData`,
`testCredentialExpiredFreezeRendersSigninExpiredClaude`)

Why each rule:

- **Sign-in expired names its fix.** Waiting cannot repair it; only Claude Code renews the
  sign-in. It wins over `Reconnecting…`, which promises a recovery by waiting. Neither says why
  the reading is old ([the copy rule](display-semantics.md#the-copy-rule-no-polling-words)).
- **`No active session` is a claim, so it is withdrawn when it may be false**: after an expiry
  seen only while stale, or when local work proves a window open
  ([rule W](quota-readings.md#retracting-a-falsified-not-started-claim-rule-w)). The unknown form
  is `—`.
- **Two shapes have no row at all** (6 and 7). Every row from 8 on answers a question about burn.
  On the low-allowance shape one turn can move the meter by a fifth, and a window that has not
  started has nothing to burn. `Measuring…` would promise a number that never comes; `Nothing
  burning` would claim a measured calm. The not-started fact is already on screen twice: `100%`
  under `5-hour quota left`, and the `not started` detail line. The rule applies only when the
  not-started primary is the hero, so a block on another limit keeps its verdict. The removed row
  still has an identity (`verdictFamily = .notStarted`) for the "since you last looked" line.
  (`verdictRemovedAsNotStarted`; tests `DisplayFormatterNotStartedTests`
  `testTheRolloverFrameStatesTheFactAndStops`, `testTheRemovedRowStillNamesItself`,
  `testABlockingWeeklyOverAnUnanchoredPrimaryKeepsItsVerdict`;
  `DisplayFormatterLowAllowanceTests.testVerdictIsNotRenderedOnTheShape`,
  `testOverQuotaVerdictStillRenders`)
- **Exhaustion needs both clocks.** The burn average spans minutes; against a week, "runway
  shorter than the reset" is nearly always true. The row also needs the pace clock and a primary
  hero. The menu bar's runway slot reads the same decision, so the two cannot disagree
  (`MenuBarExhaustionAgreementTests.testMenuBarRunwayImpliesExhaustionVerdict`). The decision's
  data is [forecast](forecast.md#the-pace-clock)'s.
- **A window a day or wider answers with pace,** not burst grammar, and holds from the first poll
  because the pace clock needs no burn history. These rows carry no line 2: their only number is
  the reset, which the detail line below states once. On a stale reading they fall through to the
  ordinary rows, since a pace verdict from frozen data would be a confident claim.
- **The held row.** The state calms only after three agreeing polls
  ([the hold](state.md#calming-down-the-de-escalation-hold)); the forecast has no memory. While a
  warning colour is held, "Safe at this pace" in amber would assert safety in the colour of
  danger, so the row names what the colour still carries. It also pre-empts `Safe, barely`.
- **The thin margin (30 min)** is its own display constant, deliberately not wired to the At-risk
  gate, so a notification tune never moves popover copy. (`thinMarginMinutes`)
- **Scoped wording under a strip.** With a strip below saying the weekly is tight, an unqualified
  "reset comes first" would read as *you are fine*. Naming the window makes the two lines fit.
- **`Measuring…` is not `Nothing burning`.** One says the burn cannot be told yet; the other is a
  measured zero (the cold-start phase is [forecast](forecast.md#cold-start-and-the-forecast-tiers)'s).
- **`~` marks forecast estimates only** (runway, margin, the stop clock), never the reset clock.
  (test `testVerdictHasNoDoubleTilde`)

### The block rows

The words name **which limit stopped you**, read off the [block episode](state.md#blocks-are-episodes).
A weekly's reset is days out, so it is a date; the five-hour reset is a clock.

| Case | Line 1 | Line 2 |
|---|---|---|
| The primary is spent | `Stopped — quota returns at [clock]`; no known reset: `Stopped — new requests blocked` | `blocked · resets [clock] · in [countdown]` |
| The weekly is spent | `Stopped — weekly spent, resets [date]` | `blocked · in [countdown]` |
| Both windows spent (the weekly is the later reset) | `Stopped — both windows spent, resets [date]` | `blocked · 5-hour resets [clock] · weekly [date] · in [countdown]` |
| Claude, usage credits paying (on, cap not spent) | `Running on credits — every token costs now`, led by the money glyph in charging colour | Fresh: `[amount] · [reset]`; stale: `over quota · [reset] · in [countdown]`; `—` when no token is known. The amount is `[amount] of [cap] this month` for organization credits, else `[amount] this window`. The reset is `weekly resets [date]` on a weekly block, else `resets [clock]` |

- **Codex always takes the plain block rows;** it has no money state
  ([credits](credits-and-monthly-limits.md#money-states-claude)).
- **A missing reset is never invented:** the line drops its clause.
- **Money tokens show only on a fresh reading;** stale, the line keeps the block fact without
  amounts. (test `DisplayFormatterTests.testStaleAccruingKeepsVerdictDropsMoneyTokens`)
- When credits are on but their cap is spent, the plain block row applies; on an organization
  seat the credits line is added under the hero
  ([credits](credits-and-monthly-limits.md#organization-card-team)).

(Tests `DisplayFormatterTests.testOverQuotaCase1CreditsAccruing`, `testOverQuotaCase2LastObserved`,
`testCodexOverQuotaCopy`; `DisplayFormatterV46Tests.testVerdictOverQuotaCodexHardBlock`,
`testVerdictQuotaSpentExactly100NoCredits`, `testVerdictAccruingInEuros`;
`LongLimitSurfaceAgreementTests.testFrameAWeeklySpentCharging`,
`testFrameBWeeklySpentCapReached`, `testABlockedHeaderStatesItsResetOnce`)

## Hero detail lines

Muted lines under the verdict (and under the strip). **The reset is stated once on the header.**
(`heroDetailLines`)

| Hero | Lines |
|---|---|
| Primary or weekly, not the block | Its reset: `not started` on a not-started window; `resets in [N days]` at 48 h or more; `resets in [h m]` on a window a day or wider; nothing on a shorter window, whose verdict line 2 carries the reset |
| Primary or weekly that is the block | No reset line: the block verdict names its own |
| Any primary or weekly hero in a block on an organization seat whose credits are spent | The organization credits line ([credits](credits-and-monthly-limits.md#organization-card-team)) |
| Monthly meter | The monthly meta line ([credits](credits-and-monthly-limits.md#the-hero-and-its-lines)) |

Why: the header once stated one weekly reset three times in four lines. A block hero once read
`resets [date]` / `in [countdown]` / `resets in [countdown]` top to bottom.
(tests `DisplayFormatterWindowGrainTests.testHeroResetLineOnALongWindow`,
`testHeroResetLineOnUnanchoredWindow`, `testHeroResetLineSub48hFallsBackToCountdown`,
`testHeroResetLineAbsentOnFiveHourWindow`, `testHeroResetLineAbsentWithoutAWidth`;
`LongLimitSurfaceAgreementTests.testABlockedHeaderStatesItsResetOnce`)

The [first-run window](first-run-window.md) also reads these lines: it shows the first one that
starts `resets in`, so rewording that prefix changes it too. (`OnboardingView`: `liveLine`)

## Header facts

Two label-and-value rows under the model warnings: `Quota burn` and `Not seen locally`. Each
belongs to the interval it was measured on. (`headerFacts`, `HeaderFact`)

**On a monthly hero** both facts are the meter's own, in its units
([credits](credits-and-monthly-limits.md#header-facts-on-a-monthly-hero)). **Otherwise both facts
are the primary window's, whoever the hero is**, and need a primary used percent; without one
neither shows.

- **They name their interval when it is not the hero's:** `Quota burn · 5-hour`,
  `Not seen locally · 5-hour` (the not-seen label lowercases the interval: `· weekly`). A
  five-hour figure must never read as a weekly one. With no named width the labels say
  `Quota burn · Window` and `Not seen locally · window`. (tests
  `DisplayFormatterOtherLimitsTests.testHeaderFactsAreLabelledWithThePrimaryIntervalUnderABlockingWeeklyHero`,
  `testHeaderFactsUnderThePrimaryHeroUseTheSpecLabels`)
- **Hidden, unknown and shown are three different things.** A fact that does not apply is hidden;
  a dash there would read as a failed fetch. A fact that applies but is not known reads `—`.

**`Quota burn`** shows only on a fresh reading with a burn rate that passes the display gate:

| Window | The rate shows when |
|---|---|
| Under a day | At least 10 minutes of span **and** at least 2 percentage points observed |
| A day or wider | At least 30 minutes **and** at least 3 points |
| Any | A measured zero, which has already passed the engine's flat-span proof |

The gate is stricter than the engine's: the provider sends whole percents, and a rate from one
tick is arithmetic, not a figure to show. State and runway still use the faster engine rate.
Otherwise the row is hidden, never dashed. (`burnHasDisplayEvidence`; tests
`DisplayFormatterBurnTierTests.testSingleQuantizedTickDoesNotRenderAsAnHourlyRate`,
`testUnmeasuredRateDoesNotRender`)

- **Value:** `[tier] · [rate]`, for example `Low · 0.4% / min`. On a window a day or wider the rate
  is per hour (`% / hr`). A positive rate that rounds to 0.0 reads `<0.1% / min` (`<0.1% / hr` a day or wider); a measured zero
  reads `No measurable burn`. (tests `testWeeklyFactRendersPerHourAndFiveHourDoesNot`,
  `testZeroAndSubPrecisionPositiveHaveDistinctReadableCopy`, `testTheUnitBoundaryIsOneDay`)
- **Tier words** are banded against the window's even pace (100 % ÷ window minutes, the rate that
  spends the window exactly at its reset): `Very low` below 0.3×, `Low` below 3×, `Mid` below 9×,
  `High` from 9×. The dot is grey, green, amber, red. Banding by pace keeps a weekly from being
  judged by five-hour bands. The internal tier key (`none`, `low`, `mid`, `high`) also feeds the
  "since you last looked" line. (`burnTier`, `burnTierThresholds`; tests
  `testFiveHourTiersAreUnchanged`, `testWeeklyBands`)

**`Not seen locally`** is the [Elsewhere estimate](local-usage.md#the-elsewhere-estimate) for the
window:

| Case | Shows |
|---|---|
| A positive estimate | `≈12% (est.)`; `<1% (est.)` when it rounds to zero |
| A measured zero, or an estimate with no usage behind it | Hidden |
| Stale, or no estimate | `—` |
| The idle recap of the last window | Hidden (there is no live window) |

**On the Codex low-allowance shape both facts are hidden:** no rate can be stated there
([state](state.md#what-is-not-inferred-from-incomplete-evidence)). (tests
`testUnknownBurnIsUnknownAndLowAllowanceIsInapplicable`, `testStaleFactsAreUnknownNotStale`,
`DisplayFormatterLowAllowanceTests.testBurnFactIsNotRenderedOnTheShape`)

## The long-limit strip

One line under verdict line 2: a dot and a sentence on its tier's tinted wash. The hero answers
*am I safe right now*; the strip answers *and is the week going to hold*. (`longLimitStrip`,
`LongLimitStripView`)

It shows only when all of these hold:

- the reading is fresh (a tier from frozen data would be a confident claim);
- there is no hard block (the blocking limit has the hero);
- the worst long limit ([state](state.md#long-limits-as-states)) is *ahead of pace* or *nearly
  spent*;
- that limit is not already the hero.

**Never two.** One limit speaks, by the ranking on [state](state.md#long-limits-as-states), shared
with the state and the menu-bar reminder. A second elevated limit keeps its tier word in its `OTHER LIMITS` row
instead.

| Tier | Colour | Text |
|---|---|---|
| Ahead of pace | Amber | `Weekly won't last the week at this rate — 40% left for 4 days, resets Oct 9` |
| Nearly spent | Red | `Weekly nearly spent — 8% left for 3 days, resets Oct 9` |

`for [N days]` drops below 48 hours. A monthly meter states money and may end on its forecast
date ([credits](credits-and-monthly-limits.md#dots-the-menu-bar-and-the-strip)). The amber lead
says the consequence, not the comparison: "ahead of pace" read as good news. Nothing pulses, and
no height is reserved when it is absent. (tests
`DisplayFormatterOtherLimitsTests.testNearlySpentWeeklyKeepsTheFiveHourHeroAndTakesAStrip`,
`DisplayFormatterV46Tests.testCodexWeeklyAheadOfPaceTakesTheSameStrip`,
`LongLimitSurfaceAgreementTests.testEveryReminderHasAStripBehindIt`,
`testNoSurfaceSaysAheadOfPace`)

## Model warnings

A model allowance near or at its end gets a boxed warning under the hero's detail lines. It
never replaces the account summary, and the model's windows stay in `OTHER LIMITS` too.
(`modelLimitWarnings`, `ModelLimitWarning`)

- **When:** a model window at 85 % used or more (amber), or 100 % (red), on a fresh reading. Stale,
  unknown and not-started windows never warn. The 85 % line is
  [state](state.md#thresholds)'s `modelWindowWarnLinePct`; model windows are not tiered like a
  weekly.
- **Text:** `⚠ [model] [period] · [N]% left` (`⚠ [model] weekly · 12% left`; no period when the
  width is unknown), then `Only this model’s allowance · resets [clock or date]`, or
  `reset unknown`.
- **Order:** red first, then the higher used percent, then a stable id.
- A model limit never implies the account is blocked, and no copy promises another model has
  room.

(tests `AccountLimitSelectionTests.testModelOnlyWarningNamesTheModelAndKeepsTheAccountHero`,
`testModelWarningTieBreaksOnUsedThenStableID`, `testSparkWeeklyCriticalVersusSparkFiveHourCritical`;
`DisplayFormatterOtherLimitsTests.testModelWarningStaysBelowTheAccountHeaderAndInOtherLimits`,
`testUnknownAccountHeaderCanCarryAFreshModelWarningButNotAStaleOne`,
`testPrimaryWarningKeepsItsForecastBesideAModelWarning`)

## OTHER LIMITS

Every limit that is not the hero, exactly once. Account limits first (primary, weekly, monthly),
then one group per model. The section is **suppressed when empty**, never drawn empty. The quota
source tag repeats at its foot. (`otherLimitsSection`, `OtherLimitsSectionView`; test
`testOtherLimitsIsSuppressedWhenEmpty`)

**A row** has a name, a reset, a dot and a value, then optional muted lines:

| Part | Rule |
|---|---|
| Name | The candidate's name: `5-hour` (or the window name from its width; `Window` for a Codex primary with no named width), `Weekly`, `Monthly spend limit` / `Monthly usage limit` |
| Value | Percent left, bare; `—` when unknown, never `100%` |
| Tier word | ` · on pace`, ` · runs out early`, ` · nearly spent` / ` · nearly reached`, ` · spent` / ` · reached` on a weekly or monthly with a fresh assessment. The row the strip names drops it: the strip already says it |
| Reset | `· resets [clock]` below a day, `· resets [date]` for a day or wider and for the monthly; the weekly adds `· day [n] of [days]` (`· day 4 of 7`); `not started`; `reset unknown`. Full date and time on hover and for VoiceOver |
| Dot | The weekly and monthly take their tier's colour when fresh and assessed ([display semantics](display-semantics.md#colours)); an unassessed weekly (no reset, or not started) falls back to the threshold dot and an unassessed monthly to its forecast dot; the primary and model windows take the used-percent threshold dot. No dot when the value is unknown |
| Monthly lines | `[used] of [limit]` and the meta line ([credits](credits-and-monthly-limits.md#the-hero-and-its-lines)) |

- **Blocked by another limit:** in a fresh hard block that has a [block episode](state.md#blocks-are-episodes)
  (a block with no episode marks nothing), every other row ends
  ` · blocked by the weekly` (or `5-hour`, `monthly spend`, `monthly usage`), drops its tier word
  and dot, and is drawn in tertiary ink. Model rows are marked the same way. A green dot beside
  quota that cannot be spent is a lie about headroom. Withheld while stale. (tests
  `LongLimitSurfaceAgreementTests.testABlockGreysTheOtherLimitsAndDropsTheirDots`,
  `testAStaleBlockKeepsTheBlockAndWithholdsTheTierWords`)
- **Highlighted:** the one row the strip is about sits on a faint chip, so a reader who reads the
  strip and looks down knows which row it meant. Its limit comes from the strip builder itself.
  Never in a block. (`Theme.rowHighlight`; tests `testTheStripAndTheHighlightNameOneLimit`,
  `testTheHighlightedRowDropsItsTierSuffix`, `testASecondElevatedLimitKeepsItsSuffix`)

**Model groups** are keyed by the model's display name, in first-seen order. A model with one
window is a single row named `[model] [period]` (`[model] weekly`, or `[model]` alone with no
known width). A model with two or more windows gets a heading with the name and indented rows
named by period (`5-hour`, `Weekly`, or `Window N`). Every window is its own row: a weekly-only
main allowance and a model's five-hour and weekly windows coexist, and neither implies the other.
(tests `DisplayFormatterOtherLimitsTests.testMainWeeklyAndBothSparkWindowsRemainVisible`,
`testUnanchoredModelWindowReadsNotStartedInOtherLimits`,
`testInlineResetCarriesFullTimestampAndUnknownIsExplicit`;
`DisplayFormatterTests.testModelLimitsRenderAsAVisibleGroup`)

## Plan badge and email

- **The badge is the plan's display name alone,** top right, beside the hero. No confidence or
  credits suffix: `Max · exact` read as "your plan is exactly Max", and the token was on in nearly
  every render. Neutral colour in every state
  ([display semantics](display-semantics.md#colours)). `—` when no plan is known.
  (`header`: `planBadge`; `Theme.badge`) The [first-run window](first-run-window.md) draws the
  same badge from the header.
- **Display names** (`planDisplayName`, case-insensitive): `plus` → `Plus`; `pro`, `prolite` →
  `Pro`; `max` → `Max`; `team` → `Team`; `business`, `self_serve_business_usage_based` →
  `Business`; `enterprise`, `enterprise_cbp_usage_based` → `Enterprise`; `education`, `edu`, `k12`
  → `Education`; `free`, `guest` → `Free`; `go` → `Go`. Anything else shows raw, so a new plan never
  breaks the badge. Which strings each provider sends is
  [Claude account](claude-account.md#the-plan-string) and
  [Codex account](codex-account.md#plan-types). (test
  `DisplayFormatterTests.testPlanDisplayNameMapping`)
- **The email** shows under the badge, small and muted, as the reading carries it; absent when
  the provider sent none. The explanation snapshot in a diagnostics bundle leaves both out.

## The quota source tag

One muted line at the foot of the header, repeated under `OTHER LIMITS`: where the numbers came
from and how old they are. (`sourceTag`, `SourceTagView`)

- **Base:** `Source: Claude account`. Codex names its transport today (`Source: wham/usage`,
  `Source: app-server RPC`); the ruling to say `Source: Codex account` is
  [display semantics Decided 2](display-semantics.md#decided).
- **Fresh:** `· exact · 12s ago`, the age turning amber after two base poll intervals. **Stale:**
  `· as of 9:47 pm`. The grammar and thresholds are
  [display semantics](display-semantics.md#fresh-and-stale)'s. (tests
  `DisplayFormatterTests.testCodexSourceTagsFollowSnapshotSource`,
  `testStaleRenderKeepsContentWithAsOfTag`)

## Rejected alternatives

- **A hot weekly taking the header** over a calm five-hour window. It made the weekly either
  shout (replace a good five-hour verdict with one about another clock) or say nothing. Replaced
  by the strip; only a block takes the hero.
- **A model allowance as the hero.** It read as the whole account at risk while every other model
  had room. Replaced by the scoped warning.
- **`Tight — N% of the weekly left`** as a verdict row. Retired with weekly promotion; the strip
  says it without displacing the five-hour verdict.
- **Painting the hero and meter in a long-limit rank's colour.** A red `64%` over a green
  `Safe at this pace` is the header contradicting itself.
- **Two strips at once.** The reader would have to work out which limit stops them first.
- **A placeholder verdict** (`Measuring…`, `Nothing burning`) on the low-allowance shape or a
  not-started window. Removed instead.
- **A confidence or credits suffix on the plan badge,** and colouring the badge by credits or
  staleness. Credits went to the credits card; staleness to the source tag.
- **A collapsed `+ N model limits` disclosure.** Model windows are visible by default.

## Known gaps

| Gap | Today | Proposed fix |
|---|---|---|
| Stale weekly block: header and menu bar disagree | When the five-hour window under a weekly block has expired and the reading is stale, the block survives ([state](state.md#what-is-not-inferred-from-incomplete-evidence)): the header leads with the spent weekly in red (`Stopped — weekly spent, resets [date]`), but the menu bar draws a grey `—— est`, because `staleMenuBar` tests for a missing five-hour percent before the block shape | The fix is the menu bar's ([menu bar](menu-bar.md)): check the block shape first; add a test that the header and the bar name the same blocked limit |
| Windowed spend control loses its date | With a monthly meter and a populated window (a Codex workspace seat), a spend-control block puts the meter in the hero but line 1 is the bare `Spend limit reached` with line 2 `—`, also on a credits meter. The branch meant to give a monthly hero the monthly family sits below the spend-control row and no current path reaches it | Check `selection.hero?.id == .monthly` before the spend-control row, so a monthly hero always takes the monthly family's reached row (`Spend limit reached — resets [date]` on money, `Monthly limit reached — resets [date]` on credits); keep `Spend limit reached` / `—` for a spend-control block with no meter; add a test |
| `Nothing burning` on a positive burn | Row 12 is the fall-through: any burn rate that reaches it reads `Nothing burning` / `no burn`. A positive burn on a window whose reset cannot be read (no reset, so no row 10) lands there and claims a measured zero | Take row 12 only for a burn at or below the engine's near-zero line (no runway); give a positive burn with no reset its own row or `Measuring…`; add a test |
| Sign-in expired hidden over a live cached window | The sign-in line is checked only when the primary has no value. A stale Claude reading whose window has not yet expired falls to the Idle row and reads `—`, while the source tag's card names the lapsed sign-in | Let the sign-in fork win in the Idle branch, as `Reconnecting…` already does; add a test |
| Hero ink ignores the display repaints | The number and meter take `dot(for: state)`. On a fresh monthly layout the tab dot follows the monthly forecast but the hero is neutral blue; on the Codex low-allowance shape the tab dot is repainted from the used percent but the hero keeps the state colour. No test covers either (the agreement fixtures exclude repainted dots) | Decide whether the hero follows the repaint; then make `heroCue` read the same repaint helpers and extend `testTheHeroInkFollowsTheLimitInTheHeaderNotTheAccount` to those fixtures |
| `PlanBadgeKind` draws nothing | `badgeKind` (`exact`, `credit`, `stale`) is still computed, but `Theme.badge` returns one neutral style for all three. `testStalePlanBadgeTextMatchesFreshOnlyStylingDiffers` and `testPlanBadgeNoCreditSuffixWhileOnCredits` still assert a "visual tell". The `Theme.badge` comment says the kind rides the diagnostics bundle; nothing in diagnostics reads it | Delete `PlanBadgeKind` and its assertions, or record why it stays; fix the comment |
| Window names fixed to five hours and a week | Both-spent line 2 says `5-hour resets` and the strip says `won't last the week` whatever the reported widths; `OTHER LIMITS` names the secondary `Weekly` | With [quota readings Decided 2](quota-readings.md#decided): name each from its width |
| Unreachable branches | `HeroReason.promoted` is never assigned; the `secondaryDefault` fallback cannot be reached (the primary slot exists whenever no meter does); `limitCaption`'s `Monthly quota left` needs a percent-unit monthly, which `MonthlyLimit` cannot carry; the model-hero caption and card branches are dead since a model never leads | Remove them with the next change to `selectLimit` or `header`, or keep each with a comment saying it is a guard |
| Stale comments | Comments still describe the retired behaviour: `LimitStatusReason` and the file header of `DisplayFormatter+LimitSelection` name Weekly-elevated and promotion; `HeaderSection.limit`, `limitCaption`, `progress` (overflow past 1.0), `heroDetails` (`used` pair) and `badgeKind` (green or blue pills); `header`'s "adds the promotions"; `HeaderFact.label` says `5-hour burn` (code: `Quota burn · 5-hour`); `exhaustionRunwayMinutes` mentions a promoted hero | Fix with the next change to each file |
| Claude model-warning fixture | `testClaudeScopedLimitWarnsWithoutAnInventedPeriod` builds a scoped limit with no width; the Claude adapter sends seven days, so the live headline reads `⚠ [model] weekly · [N]% left` | Add a fixture with the adapter's width |
| Older records disagree | They say a hot weekly takes the hero, that the source footer reads `Quota: Claude account`, that the tab shows a percentage, that the badge is blue on credits and grey when stale, that the accruing row shows `+$[rate]/hr`, and that stale condition rows carry `· as of [t]` on line 2 | Code wins; nothing to change in code |

Other gaps that touch this page live on their owners' pages: the `OTHER LIMITS` rows never say
"left", stale rows keep their colour, and the dead `quotaRows` builder
([display semantics](display-semantics.md#known-gaps)).

## Code and tests

| Area | Code |
|---|---|
| Selection types | `Packages/KvotarUI/Sources/KvotarUI/Model/AccountLimitSelection.swift` |
| Selection, caption, detail lines, header facts, strip, model warnings, `OTHER LIMITS` | `Packages/KvotarUI/Sources/KvotarUI/Model/DisplayFormatter+LimitSelection.swift` |
| `header`, `headerVerdict`, `overQuotaVerdict`, `verdictRemovedAsNotStarted`, `longLimitScopesPrimary`, `exhaustionRunwayMinutes`, `burnTier`, `planDisplayName`, `sourceTag`; the assembly in `claude()` / `codex()` | `Packages/KvotarUI/Sources/KvotarUI/Model/DisplayFormatter.swift` (a mixed file: the monthly family and the credits code beside them are [credits](credits-and-monthly-limits.md)'s) |
| `HeaderSection`, `HeaderVerdict`, `VerdictFamily`, `DetailLine`, `SourceTag`, `PlanBadgeKind` | `Packages/KvotarUI/Sources/KvotarUI/Model/PopoverDisplay.swift` |
| Views | `Packages/KvotarUI/Sources/KvotarUI/Views/Sections/HeaderSectionView.swift` (its peek, pin and `VerdictAnatomyView` are [explanations](explanations.md)'s), `Views/Sections/OtherLimitsSectionView.swift`, `PlanBadgeView` and `SourceTagView` in `Views/Components.swift` |

Tests, in `Packages/KvotarUI/Tests/KvotarUITests/`: `AccountLimitSelectionTests`,
`DisplayFormatterOtherLimitsTests`, `DisplayFormatterNotStartedTests`,
`DisplayFormatterLowAllowanceTests`, `DisplayFormatterWindowGrainTests`,
`DisplayFormatterBurnTierTests`, `LongLimitSurfaceAgreementTests`,
`MenuBarExhaustionAgreementTests`, and the header parts of `DisplayFormatterTests` and
`DisplayFormatterV46Tests`. `DisplayFormatterScopedLimitsTests` pins the dead `quotaRows` builder,
not anything drawn today.
