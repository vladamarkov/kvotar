---
summary: What a quota reading means — limits, windows, primary and secondary slots, width, reset time and used percent — and how Kvotar treats a null, not-started, expired, withdrawn or stale reading, a reset, an early reset, and the age of a reading.
read_when: Changing QuotaSnapshot or AdditionalRateLimit fields and derived properties (isNullWindow, primaryWindowIsUnanchored, primaryWindowLength, primaryWindowStart, degradingExpiredWindows, withdrawingPrimaryWindow, resetJitterTolerance, isSameResetInstant), what an adapter puts in a window or reset field, StateEngine's reset detection or staleness (detectWindowReset, isStale, cachedStateTTL), DiscontinuityDetector window facts, or the launch restore of poll_snapshots.
---

# Quota readings

## Questions for owner

None.

## Decided

The maintainer ruled on these on 2026-10-04 (STEP_247). The code does not follow them yet; each
has a row in *Known gaps* below, which a later contract closes.

1. **Rule W applies to Codex too.** A Codex "not started" claim is retracted by the same two
   triggers as Claude's ([rule W](#retracting-a-falsified-not-started-claim-rule-w)). Reason: local
   evidence falsifies a negative claim whichever provider made it. Today only Claude applies it.
2. **The secondary window is named and sized from its reported width,** by the same rule as the
   primary ([limits and windows](#limits-and-windows)). `Weekly` and seven days are only the
   fallback when no width is reported. Reason: one rule for both slots; a provider can change a
   width without warning. Today every secondary is called `Weekly` and treated as seven days.

## About this page

This page is the specification for what a quota reading means: the shared vocabulary every other
page uses for limits and windows, and the rules for null, not-started, expired and stale readings,
for resets, and for freshness. It replaces the private Baseline §4 (the window-name rows and their
amendment), the reading and freshness parts of §8.0.2, §8.3, §9.3 and §13 item 12, and the private
UI Spec §0.1 rule as far as it concerns data. Change this page in the same commit as the code it
describes.

IDs such as REV-60 or D-58 below are private record IDs; [REFERENCES.md](../REFERENCES.md) explains
them. The rules here stand without them.

What this page does **not** own:

| Topic | Page |
|---|---|
| How Claude's usage endpoint fields become a reading, including model-scoped weekly limits | [Claude account](claude-account.md) |
| How Codex app-server and `wham/usage` fields become a reading, including the placeholder-reset rule | [Codex account](codex-account.md) |
| States, priority, severity, hard blocks, long-limit tiers, hysteresis, triggers | [state.md](state.md) |
| Percent left as shown, colours, placeholders, the amber age stamp, all wording except window names (owned here) | [display-semantics.md](display-semantics.md) |
| Poll cadence, floors, refusals, holds, extra polls near a reset | [polling.md](polling.md) |

## The vocabulary

Every page uses these words with these meanings.

| Term | Meaning |
|---|---|
| **Reading** | One `QuotaSnapshot`: the normalized result of one account-quota poll, for one tool. (`Packages/KvotarCore/Sources/KvotarCore/Adapters/AccountAdapter.swift`: `QuotaSnapshot`) |
| **Limit** | Any allowance the provider reports that can stop work: a window, a monthly limit, or a model allowance. |
| **Window** | A limit that refills on a schedule. It has three facts: **used percent**, **reset time** and **width**. Each may be missing. |
| **Primary / secondary** | The two account-wide window *slots* a provider fills. They are positions in the payload, not durations. The primary is usually five hours, but a Codex account can report its weekly as the primary with no secondary. |
| **Width** | How long the window is, in seconds, when the provider says so. `nil` means unknown. |
| **Reset time** (`resets_at`, the **anchor**) | When the current window ends and its spend is forgiven. |
| **Used percent** | The provider's utilization for a window. Windows are stored and reasoned about as *used*. "Percent left" is a display form ([display-semantics.md](display-semantics.md)). |
| **Weekly** | A window seven days (10,080 minutes) wide. Today the code also calls any secondary window weekly; ruled otherwise (Decided 2). |
| **Monthly limit** | A per-user pool on a calendar-month cycle (`MonthlyLimit`): credits on Codex, money on a Claude seat with no windows. |
| **Model allowance** | A per-model limit (`AdditionalRateLimit`) with its own primary and optional secondary window, the same three facts each. |
| **Null window** | The provider sent no window: used percent is `nil`. |
| **Not started** (*unanchored*) | The window is known to exist but has not begun: 0 % used, no reset time, a known width. |
| **Expired window** | A window whose reset time passed more than 60 s ago. It is treated as a null window. |
| **Withdrawn window** | A live window the **provider** took back before its reset time (recorded as `window_demolished`). |
| **Retracted not-started claim** | Kvotar's **display** dropping a "not started" reading to unknown because evidence contradicts it (rule W). Not a provider event. |
| **Reset** (rollover) | A window ending: its anchor passed, or a later anchor replaced it. |
| **Early reset** | The provider replaced a window that still had usage, before its scheduled reset. |
| **Fresh / stale** | See [Fresh and stale readings](#fresh-and-stale-readings): fresh for 600 s after the last successful poll, stale after that. |
| **Restored reading** | The newest stored reading, loaded at launch. Always stale until a live poll succeeds. |

## Limits and windows

**A reading carries only what the provider sent.** Every window field is optional. A missing
window creates no row and no claim; nothing is filled in from the plan, from the other slot, or
from another model. (`AccountAdapter.swift`: `QuotaSnapshot`, `AdditionalRateLimit`)

**Width is read, never inferred.** Codex reports a width on both transports; Claude reports none.
Codex's window size depends on the plan and is not documented for every plan (five hours on some,
30 days on others). Separately, no window rule branches on the plan name: plan strings vary more
than any list the code could test, and the plan string stays a raw `String`
([PATTERNS.md](../../PATTERNS.md), naming conventions).

**Where a provider states no width, two shared fallbacks apply**, both matching Claude's real
windows:

| Fallback | Value | Used by | Pointer |
|---|---|---|---|
| Primary width | 18,000 s (five hours) | Window start, pace, window-type names | `QuotaSnapshot.primaryWindowLength` |
| Secondary width | 604,800 s (seven days) | Long-limit pace assessment | `QuotaSnapshot.secondaryWindowFallbackSeconds` |

The Claude adapter sets 18,000 s on every reading, so the primary fallback in practice covers only a
Codex payload that omits its width. Several other call sites hold their own five-hour fallback (see
Known gaps).

**A width belongs to the plan, not to the window.** It survives expiry and withdrawal, so the next
poll can still recognise a not-started window. (`degradingExpiredWindows`,
`withdrawingPrimaryWindow`; test `QuotaSnapshotDegradationTests.testExpiredSecondaryKeepsItsWidth`)

**Where a window started is derived in one place:** `primaryWindowStart = resets_at − width`. Every
window-scoped span (local attribution, off-machine share, the window's start time on screen) reads
it. `nil` on a null or not-started window. Reason: a fixed five-hour assumption once put a 30-day
window's start a month in the future, and a window spent entirely on this Mac then read as almost
all off-machine. (`QuotaSnapshot.primaryWindowStart`; tests `QuotaSnapshotWindowStartTests`)

**A window is named by its width, never by its slot or the plan.** 300 min is five-hour, 10,080 min
weekly, 43,200 min monthly; another whole number of days (7 or more) or hours is named literally;
anything else makes no name claim. On screen that reads `5-hour`, `Weekly`, `Monthly`, or a
literal `14-day` or `72-hour`; the same rule names the secondary slot (Decided 2; today the code always says `Weekly`). Two
functions apply this with different spellings: the display name (`Packages/KvotarUI/Sources/KvotarUI/Model/DisplayFormatter.swift`: `windowGrain`) and the
stored `window_type` (`Packages/KvotarCore/Sources/KvotarCore/State/DiscontinuityDetector.swift`:
`DiscontinuityObservation.windowTypeName`). (Tests `DisplayFormatterWindowGrainTests`)

**Used percent is data.** Every engine (state, pace, forecast, notification thresholds) reads a
window's utilization untransformed; turning it into percent left is one step at the display edge.
Reason: one orientation inside the app means no threshold is ever flipped by mistake. The monthly
limit is the exception in storage: it keeps the provider's used and limit amounts and its remaining
percent verbatim, and engines read the used percent derived from the amounts
(`MonthlyLimit.usedPercentExact`).

## Null, not-started and expired windows

Four shapes, each with a different meaning. Keep them apart.

| Shape | Fields | Meaning | Pointer |
|---|---|---|---|
| Null window | used `nil` | The provider sent no window. Normal for an idle Codex account and for a Claude seat whose only limit is monthly. Not an error. | `QuotaSnapshot.isNullWindow` (both slots), `primaryUsedPct == nil` |
| Not started | used `0`, reset `nil`, width known | The window exists but has not begun. Utilization is real (0 %); the deadline does not exist yet. | `QuotaSnapshot.primaryWindowIsUnanchored` |
| Expired | reset more than 60 s in the past | The window is over; its spend is forgiven. | `QuotaSnapshot.degradingExpiredWindows` |
| Reset unreadable | used known, reset `nil`, not 0 % | A real window that cannot be dated. Keeps its utilization. Not "not started". | [Claude account](claude-account.md#the-five-hour-window-four-shapes) |

`nullWindowSource` records, for diagnostics only, whether a null primary came from the provider or
from Kvotar's own normalization. Nothing branches on it. (`AccountAdapter.swift`: `NullWindowSource`)

### Not started

Both adapters produce the same shape; how is provider-specific. Claude sends it almost directly
([Claude account](claude-account.md#the-five-hour-window-four-shapes)). Codex never says "not
started" and answers with a sliding placeholder reset, which its adapter recognises and drops
([Codex account](codex-account.md#the-placeholder-reset);
`Packages/CodexAdapter/Sources/CodexAdapter/CodexAccountAdapter.swift`: `isUnanchoredWindow`).
A model-allowance window uses the same shape test. (`DisplayFormatter+LimitSelection.swift`: the
`unanchored` test in `selectLimit`)

Everything downstream keys on the shape, never on the tool.

### Expired

**An expired window is a null window, decided once in Core.** A window whose reset passed more
than 60 s ago has its used percent, reset and hard-block flags cleared before anything reads them.
Each window expires on its own: the weekly, each model window and the monthly limit each have their
own test, and a model allowance is dropped only when none of its windows is left. Reason: the state
engine and the popover once disagreed about whether a window was over; one function shared by both
ends that. (`QuotaSnapshot.degradingExpiredWindows`; read by `StateEngine.classify` and
`DisplayFormatter`; tests `QuotaSnapshotDegradationTests`,
`StateEngineTests.testFreshPollWithPastResetsAtClassifiesNullWindow`)

The spend-control flag expires with the monthly limit when one exists, otherwise with the primary
window. (`degradingExpiredWindows`, `spendControlExpired`; test
`testLiveMonthlyReanchorsSpendControlPastPrimaryExpiry`)

This applies to fresh readings too: a just-polled reading whose reset already passed is a null
window. Code that compares anchors (reset detection, the crossed-reset check, window facts) reads
the **raw** reading, because degrading first would erase the anchor being compared.

### Retracting a falsified not-started claim (rule W)

A "not started" reading is a negative claim: no window is open. On Claude, the popover and the menu
bar retract it to the unknown form when either:

- local Claude Code activity is newer than the poll that produced the reading, or
- the reading has gone [stale](#fresh-and-stale-readings) while polls are refused or the sign-in
  has expired. (The freeze reason reaches the check only on the stale render, so for the first
  10 minutes only the local-activity trigger applies.)

The retraction clears only the primary's percent, reset and block flag; width, weekly, monthly and
model data stay. It is display-only: the state engine never sees it. How the unknown form looks is
[display-semantics.md](display-semantics.md)'s. Reason: during a run of refused polls the app once
said "no active session" for half an hour while local work was visibly running.
(`DisplayFormatter.notStartedWithdrawn`, `QuotaSnapshot.withdrawingPrimaryWindow`, both callers in
`Packages/KvotarUI/Sources/KvotarUI/ViewModel/AppViewModel.swift` `apply` / `applyCached`; tests
`DisplayFormatterTests.testLiveNotStartedWithNewerLocalActivityRendersUnknownForm`,
`testStaleNotStartedWithLocalActivityAfterPollRendersUnknownForm`,
`testObsoleteNotStartedWindowRendersUnknownForm`,
`testStaleNotStartedWithoutNewerLocalActivityKeepsTheClaim`)

A related rule covers expiry: on the stale path, an expired primary window or monthly cycle is shown
as unknown whatever the local activity, because off-machine work (claude.ai) leaves no local trace.
(`DisplayFormatter.swift`: `expiredOnStale`; test
`DisplayFormatterTests.testStaleExpiredWindowUnknownRegardlessOfLocalActivity`)

Rule W applies to Codex too (Decided 1); today the code applies it to Claude only.

## Resets

**One tolerance, 60 s, for both readings of a boundary.** A reset time that moves by 60 s or less
is the same reset (the Claude endpoint wobbles by about a second between polls); a window is
expired only once `now` is more than 60 s past its reset. The episode and long-limit keys
(`BlockEpisode`, `LongLimitAssessment`, the weekly ladder, the menu-bar reminder) compare resets
through `QuotaSnapshot.isSameResetInstant`, never by string. (`QuotaSnapshot.resetJitterTolerance`,
aliased by `StateEngine.resetJitterTolerance`; other copies are listed under Known gaps. The Claude
adapter also holds a wobbling reset steady: [Claude account](claude-account.md#reset-de-jitter).)

**The state engine tracks one anchor per tool: the primary window's.** It remembers the last live
reset and reports exactly one of three outcomes:

| Outcome | When | What happens | Pointer |
|---|---|---|---|
| Reset | The new reset is more than 60 s later than the anchor, **or** the anchor passed by more than 60 s | Emits `windowReset`, writes a `window_reset` row with the last live utilization. The anchor becomes the new live reset, or is cleared when the reading has none | `StateEngine.detectWindowReset` |
| Withdrawn window | The anchor is not past, nothing advanced, and the new reading is not started | Writes a `window_demolished` row and clears the anchor. **No** reset event, **no** notification: the user's quota improved | same |
| Nothing | Otherwise | Keeps or refreshes the anchor | same |

Why the "anchor passed" branch exists: right after a rollover the provider can send no reset at
all, so a test that only looks for an advance would miss the rollover exactly when it happens. Each
anchor fires once, because only a live reset is ever stored. A reset or a withdrawal also ends any
held calmer state ([state.md](state.md)). (Tests `StateEngineDiscontinuityTests`:
`testExpiryClauseWritesRowWithNullNewValue`,
`testWithdrawnWindowWritesOneDemolitionRowAndClearsTheAnchor`;
`StateEngineTests.testWindowResetEmittedWhenResetsAtAdvances`,
`testWindowResetIgnoresSubSecondJitter`)

A launch restore seeds the anchor when the restored window is still live, so a rollover between
launch and the first live poll is still reported. A rollover that happened while the app was not
running is not recorded (Known gaps). (`App/PollCoordinator.swift`: the restore block, trigger
`.restore`; test `StateEngineDiscontinuityTests.testRestoreThenPollAcrossRolloverWritesOneRow`)

**Window facts between two consecutive polls** (`DiscontinuityDetector.detect`, raw readings, never
on an all-null reading):

| Fact | Rule | Notes |
|---|---|---|
| `early_reset` | Both readings live, previous used > 0, the old anchor still more than 60 s ahead, and the new anchor more than 60 s later | Old value = the scheduled reset; new value = the time it was **observed**, which can be up to one poll after it happened. Suppressed when the plan name changed in the same comparison, because a plan change replaces the window |
| `window_removed` | A slot that was live goes null while its anchor was still ahead, and the other slot is still live | A not-started reading is 0 %, not null, so that case stays a withdrawn window, not a removal |
| `window_added` | The secondary slot appears beside a live primary | Not detected for the primary: from two readings it cannot be told apart from a window starting after idle |
| `window_width_changed` | The primary's reported width changed while it is live | Claude never fires it (its width is constant) |

Early resets are real: the provider has ended Codex weeklies well before schedule. A primary early
reset also trips the engine's advance clause, so both a `window_reset` and an `early_reset` row land;
that is correct. (Tests `DiscontinuityDetectorTests`:
`testEarlyResetRecordsScheduledAnchorObservedInstantAndForgivenUtilization`,
`testEarlyResetAtZeroPercentWritesNothing`, `testEarlyResetSuppressedOnPlanChange`,
`testWindowRemovedWhenSlotVanishesWithAnchorAheadAndOtherWindowLive`)

The monthly limit's cycle end comes from the payload on Codex. On a Claude seat it is derived as the
start of the next calendar month in UTC and tagged `derived_calendar_month_utc`, never shown as
payload data. A `monthly_rollover` fact is written when the cycle end advances by more than 60 s.
(`MonthlyLimit.nextCalendarMonthStartUTC`, `MonthlyLimit.cycleStart`)

How soon after a known reset Kvotar polls again is [polling.md](polling.md)'s.

## Fresh and stale readings

**The age of a reading is the time since the tool's last successful poll.** A JSONL-only re-render
and a launch restore never reset that clock. (`StateEngine.evaluate`, `lastSuccessfulPollAt`;
`AppViewModel.apply(recordsPoll:)`)

**A reading is fresh for 600 s (10 minutes) after the last successful poll, and stale after that,
or when no poll has ever succeeded.** (`StateEngine.cachedStateTTL`, `StateEngine.isStale`; tests
`StateEngineTests.testIdleWhenStale`, `testCachedStateExpiresToIdleAfterTTL`) Within those
10 minutes the popover's age stamp turns amber at 240 s, one missed poll; that stamp and all stale
wording belong to [display-semantics.md](display-semantics.md).

**A crossed reset makes cached data stale at once.** While serving cached data after a failed poll,
a primary reset that has passed means every cached number is wrong, whatever its age. A fresh poll
is never invalidated this way. (`StateEngine.evaluate`, `resetCrossed`; tests
`testPollFailureWithCrossedResetInvalidatesImmediately`,
`testPollFailureWithFutureResetStaysOnCachedState`)

**Stale data is kept, not wiped.** Past the 10 minutes the last reading stays available with its
poll time; windows that have expired since are null; no forecast is shown. (The state check still
computes one from the cached reading and writes it to `forecast_log`; see [forecast](forecast.md).) Which states survive
staleness (only an already-reached block whose reset is still ahead) is [state.md](state.md)'s.
Reason: wiping blanked the popover for hours overnight and during runs of refused polls.
(`App/PollCoordinator.swift`: `evaluateStaleness`; `AppViewModel.applyCached`; tests
`DisplayFormatterTests.testStaleRenderDegradesExpiredPrimaryKeepsLiveWeekly`,
`StateEngineTests.testStaleHardBlockSurvivesTTLOnPollFailure`)

**A restored reading is never a live one.** At launch the newest stored reading per tool is loaded
and goes through the stale path. It seeds the reset anchor (when still live) and the block it
proves, but never the poll clock, the success flag or the forecast shown with it.
(`SQLiteStore.readLatestPollSnapshot`; `PollCoordinator`, the restore block) A restored not-started
reading keeps its width, so it still reads not started; the first live poll corrects it either way.

Other sources keep their own clocks: the local collector ages from its newest local event, and the
Claude prepaid wallet from its own fetch time. Neither changes the quota reading's age.
(`PrepaidCredits.asOf`; `DisplayFormatter+LocalActivity.swift`)

## Rejected alternatives

- **Naming or sizing a window from the plan name or from its slot.** Plan strings vary more than
  any list the code tests, and Codex has returned the weekly as primary. (REV-59 / D-58)
- **A fixed five-hour window everywhere.** It put a 30-day window's start a month in the future.
  Replaced by the read width. (REV-60)
- **Turning Claude's not-started `0` into `nil`.** That made a not-started window read as "no active
  session"; the 0 is kept and the shape matches Codex's. (REV-80 / D-101)
- **Wiping the display past the 10 minutes.** Replaced by keeping the last reading with its poll
  time.
- **A debug-mode "Using cached data" banner.** In the private record, never built, and contrary to
  [diagnostics.md](diagnostics.md): debug logging changes no display.

## Known gaps

| Gap | Today | Proposed |
|---|---|---|
| Secondary named and sized as weekly regardless of width | `selectLimit` gives the secondary row `name: "Weekly"` and `periodSeconds: 7 days`; `longLimitName(.secondary)` is `Weekly`; `DiscontinuityDetector.secondaryWindowSeconds` is a fixed 604,800. The pace assessment uses the reported width | Decided 2: name and size from `secondaryWindowSeconds`, `Weekly` / seven days only when no width is reported |
| Primary block named `5-hour` regardless of width | `longLimitName(.primary)` returns `5-hour`, used in "blocked by the …" on a row; on a Codex account whose primary is seven days wide this would say "5-hour" | Name the primary from `windowGrain(primaryWindowSeconds)`, with Decided 2 |
| Codex not-started claim is never retracted | `notStartedWithdrawn` is called for Claude only | Decided 1: call it for Codex with the same predicate, with a test |
| A reset missed while the app was closed is not recorded | The engine stores only a live anchor, so a restored reading whose reset already passed seeds nothing: no `window_reset` row and no reset event on the first live poll. The `PollCoordinator` restore comment claims otherwise | On restore, treat a restored anchor that has passed as an expiry-clause reset, or accept the gap and fix the comment |
| Five-hour fallbacks outside `primaryWindowLength` | Separate fallbacks for a missing width: `NotificationEngine.fallbackWindowLength`, `OffMachineEstimator.fallbackWindowSeconds`, `ForecastEngine` (`item.windowSeconds ?? 18_000`), `ShadowTablesReader`, `DeltaLine`, `DisplayFormatter+Anatomy`, `SQLiteStore.lastActiveWindow` (a fixed `-18_000`, read today only for the Claude idle recap). Each would also apply to a Codex reading with no width. (`AttributionEngine.fallbackWindowSeconds` is a span floor, not a width, and is not in this list) | Read `primaryWindowLength` (or the stored width) everywhere; give Codex no window start when its width is missing. Low risk: no Codex payload without a width has been seen |
| Copies of the 60 s tolerance | `QuotaSnapshot.resetJitterTolerance` is the rule, aliased only by `StateEngine`. Own `60` constants: `ClaudeAccountAdapter.resetJitterTolerance`, `ForecastEngine.resetJitterTolerance`, `MonthlySpendRate.resetJitterTolerance`, `OffMachineEstimator.resetJitterToleranceUnix`, `MonthlyAttributionEstimator.resetJitterToleranceUnix`, `DeltaLine.resetJitterTolerance`, `QuotaWindowOutcomes.anchorJitterTolerance`, `NotificationEngine.minResetAdvanceForRollover` | Alias each to `QuotaSnapshot.resetJitterTolerance` |
| Stale "2 minutes" amber comments | Private Baseline §9.3 says the stamp turns amber after 2 minutes; the code uses 240 s. Comments in `DisplayFormatter.sourceTag` and `PopoverDisplay.swift` still say 2 minutes | This page and display-semantics.md win; fix the comments with the next change to those files |
| Stale code comments about windows | `QuotaSnapshot` doc says Claude always fills both windows (it can send no `five_hour`, or a not-started one). `AdditionalRateLimit` and a `selectLimit` comment say Claude's scoped limits carry no width; the Claude adapter sets seven days, so a 0 %, reset-less scoped limit would read not started. A `StateEngine.classify` comment says the null-window rank catches a not-started window; it classifies Healthy (used 0) | Fix the comments with the next change to each file; settle on [Claude account](claude-account.md#questions-for-owner) whether a scoped limit can be not started |
