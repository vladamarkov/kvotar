---
summary: The menu-bar item — the three display modes and their stored setting, the per-tool string and its shapes (steady, reminder, held), the under-60-minute runway slot, how the money glyph is drawn, the reserved width and the motion, and the amber reminder's schedule, episode and acknowledgement.
read_when: Changing what the status item shows or how — MenuBarDisplayMode, ToolMenuBarDisplay, MenuBarRender, LongLimitReading, MenuBarWidth, MenuBarReminder, ReminderEpisode, MenuBarItemView; DisplayFormatter.loadingMenuBar, toolMenuBar, staleMenuBar, menuBarRender, longLimitReading, longLimitBlockShape, menuBarTimeSlot; Fmt.moneyGlyphSymbol or Fmt.compactReset; AppViewModel's reminder schedule (setMenuBarDisplayMode, syncReminderEpisodes, seedReminderEpisode, acknowledgeReminders, the reminder clock); MenuBarController.render or reservedWidth; the menu_bar_display_mode or reminder_episode.<tool>.<limit> settings; migration v21_retire_menu_bar_modes.
---

# Menu bar

## Questions for owner

1. **Should the money glyph stay while the reading is stale?** Today a stale render draws no glyph
   at all, even over a hard block whose red stays, and so also after a relaunch until the first
   live poll (see Known gaps). The maintainer keeps today's behaviour for now and will decide later.
2. **A single-tool mode whose tool is not detected** draws an empty, clickable item about 8 pt
   wide while the other tool is detected. Keep it, or fall back to the detected tool's row? Left
   for a later decision (see Known gaps).
3. **Spend control in the bar** (one of the open term differences). The record says Spend control
   uses the ordinary string with a red dot. The code treats it as a block: when the block belongs
   to a monthly limit and a five-hour window is populated, the bar holds `CX ⚠mo 0% ↻9d` (or
   `⚠wk 0%` when a spent weekly resets later, since the block is the spent limit with the latest
   reset); when it belongs to the five-hour window, the ordinary string stays. Which is meant? This
   page describes the code and does not settle the term.

## Decided

The maintainer ruled on this on 2026-10-04. The code does not follow it yet; its row in *Known
gaps* below names the change.

1. **Delete the unused `Fmt.compactReset`.** It was the reset form for the reminder and has had no
   caller since the reminder lost its reset; only three `DisplayFormatterWindowGrainTests` tests
   call it. Reason: a duration form nothing renders is dead code, and the version history keeps it
   if a long limit's reset ever returns to the bar.

## About this page

This page is the specification for the menu-bar item: what it draws, in which mode, and how the
long-limit reminder runs. It replaces what was left of the private Implementation Baseline §14
(menu-bar baseline) and §14.1 (menu-bar display modes) after the shared pages took their parts,
the drawing half of the money glyph from Baseline §13.4 and UI Spec §1.6, the private UI Spec
Part 1 §1 intro, §1.0 (display modes), §1.1 (string grammar), §1.3 (time slot switching rule),
§1.4 (what the menu bar never shows), the example strings and drawing notes of §1.2, the
menu-bar rows of §5 (thresholds and tuning), and the bar parts of UI Spec Part 2 §1, §1.1 and §1.2
(Codex). Change this page in the same commit as the code it describes.

IDs such as REV-nn or STEP_nnn in code comments are private record IDs;
[REFERENCES.md](../REFERENCES.md) explains them. The rules here stand without them.

What this page does **not** own:

| Topic | Page |
|---|---|
| Percent left, the dot colours, the money glyph's colours, `…` / `––` / `——`, the stale grammar, countdown units, tabular digits | [Display semantics](display-semantics.md) |
| Which state applies, its rank, the long-limit tiers, hard blocks, the block episode | [State](state.md) |
| Runway minutes and the pace clock behind the exhaustion decision | [Forecast](forecast.md#runway) |
| What the money states mean, when the glyph arms, its two-poll hold, the monthly `◔~Nd` / `↻Nd` slot rule | [Credits and monthly limits](credits-and-monthly-limits.md#the-money-glyph) |
| The **Menu bar display** submenu, its labels and checkmark | [Menu actions](menu-actions.md#item-details) |
| Left and right clicks, the hidden-item detection, the open hook, the app window | [App lifecycle](app-lifecycle.md) |
| The status-item strip on the first-run window's third screen | [First-run window](first-run-window.md#screen-3--read-it-without-clicking-onboardingmenubarscreen) |
| The settings table and the migration rules | [Storage](storage.md#the-settings-table) |
| The weekly notification ladder and the *Limit nearly spent* alert (the bar reminder is not a notification) | [notifications](notifications.md) |
| The "since you last looked" line's reading of the mode | `explanations.md` (pending) |
| The default tab a single-tool mode pins, and the long-limit strip in the popover | `popover.md`, `account-summary.md` (pending) |

## One item, always there

Kvotar draws **one** status item for both tools, with variable length.
(`App/MenuBarController.swift`: `init`, `NSStatusItem.variableLength`)

- **Kvotar never hides its own item.** Every mode draws something. Reason: Kvotar has no Dock icon,
  and the right-click menu that changes the mode lives on the item, so a mode that removed it had
  no way back. macOS can still hide it on a full menu bar; detecting that is
  [app lifecycle's](app-lifecycle.md#the-hidden-menu-bar-item).
- **The drawn view ignores the pointer;** every click lands on the button, whose routing is
  [app lifecycle's](app-lifecycle.md#when-the-app-window-opens-and-closes) (left) and
  [menu actions'](menu-actions.md#two-doors-one-menu) (right). (`render`: `.allowsHitTesting(false)`)
- **What the bar never shows:** a project name or path, a model name, a long limit's *used*
  percentage, local versus elsewhere attribution, a per-surface breakdown, or a money amount.
  Those live in the popover. The only money element is the glyph below.

## Display modes

Three modes. The raw value is what `settings.menu_bar_display_mode` stores.
(`Packages/KvotarUI/Sources/KvotarUI/Model/MenuBarDisplay.swift`: `MenuBarDisplayMode`;
test `MenuBarRenderTests.testModeRawValuesAreTheSettingsStrings`)

Their labels in the right-click submenu are [menu actions'](menu-actions.md#the-menu-top-to-bottom).

| Mode (raw value) | Draws |
|---|---|
| `both_stacked` (default) | One row per **detected** tool, Claude above Codex, 9 pt text and a 5 pt dot each. With one tool detected it collapses to that tool's single row |
| `claude_only` | Claude's row alone, 11 pt text and a 6 pt dot |
| `codex_only` | Codex's row alone, same metrics |

(`DisplayFormatter.menuBarRender`; `Views/MenuBarItemView.swift`: `MenuBarLayers`; tests
`testStackedRendersOneRowPerToolWithDots`, `testStackedCollapsesToTheSingleToolShape`,
`testClaudeOnlyIgnoresCodex`)

- **One default does the whole job.** An absent row, an unknown value or a retired value all read
  as `both_stacked`, and `both_stacked` with one tool detected is byte-identical to that tool's
  single-tool mode. So "both when both are detected, otherwise the one that is" needs no code and
  nothing stored. Reason: a mode derived from detection and saved at first launch would strand a
  user whose second tool appears later. (`AppDelegate`: the launch read; `MenuBarDisplayMode`'s
  type comment)
- **The single row is 11 pt,** between the 9 pt stacked rows and the system's own items. Reason:
  it keeps the dense instrument look without the stack's orphaned time slot.
- **The choice applies at once and is stored.** Picking a mode re-renders the item, clears the
  popover's remembered tab pick, writes the setting through `writeSetting` and logs
  `Menu bar display mode changed` with the mode. The mode is read once at launch, after the first
  render, so a stored single-tool mode replaces the default render within the launch.
  (`AppViewModel.setMenuBarDisplayMode`; `AppDelegate`: `onSelectMode`, the launch read)
- **Migration `v21_retire_menu_bar_modes`** rewrites a stored `adaptive`, `compact_glyph` or
  `hidden` to `both_stacked` and writes its own `settings_changes` row, because raw SQL bypasses the
  audit ([storage](storage.md#the-settings-table)). Those values also fail to decode, so a database
  read before the migration still lands on the default. Reason for the rewrite: the stored row must
  not keep naming a mode the app no longer has. (`SQLiteStore+Migrations.swift`; tests
  `SQLiteStoreTests.testV21RewritesRetiredMenuBarModes`,
  `MenuBarRenderTests.testRetiredRawValuesDoNotDecode`)
- **No tool detected:** one neutral grey Kvotar mark, 14 × 14 pt, in every mode, and no text.
  Reason: a prefix, a percent or `——` would each claim something about a tool the app has not
  found. A detected tool with no reading yet is not this case; it draws its `…` or `–– est` row.
  (`MenuBarRender.Content.nothingDetected`, `MenuBarLayers.undetectedMark`; tests
  `testNothingDetectedRendersTheMarkInEveryMode`, `testDetectedToolWithNoReadingIsNotNothingDetected`)
- **A single-tool mode whose tool is undetected** while the other is detected draws an empty item
  (about 8 pt of padding, still clickable), not the mark, because a tool *is* detected (Question
  2). (`MenuBarLayers`, `case 0`; tests `testCodexOnlyWithUndetectedCodexRendersNothing`,
  `testSingleToolModeWithTheOtherToolDetectedIsNotNothingDetected`)

## The per-tool string

```text
[dot] [prefix] [percent] [time slot] [money glyph]
```

The prefix is `CL` or `CX` (`Tool.menuBarPrefix`). The percent is percent left and the dot is the
state's colour, both by [display semantics](display-semantics.md#by-surface). The dot and the
glyph are drawn as separate elements; the text between them is `ToolMenuBarDisplay.fullString`.
(`DisplayFormatter.toolMenuBar`, `staleMenuBar`, `loadingMenuBar`)

| Shape | When | Example |
|---|---|---|
| Loading | Detected, first poll not back | `CL …` |
| Idle / fallback | No usable account reading | `CL –– est` |
| No percent | Null window, a withdrawn not-started window, a stale reading whose window ended | `CX —— est` |
| Steady | Every other live reading | `CL 38% ↻1h52m`, `CX 71% ◔~31m` |
| Monthly layout | A monthly limit owns the hero ([credits](credits-and-monthly-limits.md#dots-the-menu-bar-and-the-strip)) | `CX 52% ↻17d` |
| Held block | Over quota or Spend control, and the block belongs to a weekly or monthly limit | `CL ⚠wk 0% ↻3d` |
| Held *Limit nearly spent* | The state is Limit nearly spent | `CX ⚠wk 8% ↻2d` |
| Reminder (a phase, not a steady shape) | Limit ahead of pace; see [The reminder](#the-amber-reminder) | `CL ⚠wk 43%` |

What each placeholder means is [display semantics'](display-semantics.md#unknown-missing-and-stale).

### The time slot

`menuBarTimeSlot` picks one slot:

1. `◔~[n]m` when the exhaustion decision the popover verdict also reads
   (`exhaustionRunwayMinutes`) returns a runway **under 60 minutes**. The decision and its runway
   are [forecast's](forecast.md#runway); the 60-minute cut is this page's. Reason: the slot is for
   what deserves a glance now, and an hour's warning reads as a reset countdown anyway.
2. Otherwise `↻[countdown]` to the five-hour reset, in
   [display semantics'](display-semantics.md#time-and-reset-wording) units.
3. No slot when neither is known.

- **The bar and the verdict read one decision,** so a `◔` in the bar always has the verdict's
  exhaustion row behind it. Local token silence does not withdraw it: the quota is account-wide,
  and other surfaces spend it unseen. (Tests `MenuBarExhaustionAgreementTests.testMenuBarRunwayImpliesExhaustionVerdict`,
  `testEstimateSurvivesGoingIdleAndIsWithdrawnByTheForecast`,
  `testLongRunwayKeepsTheResetSlotUnderAnExhaustionVerdict`)
- **The long-limit ranks never show a runway.** The decision returns nothing for them, so an amber
  long limit keeps `↻`. (`testLongLimitRankLeavesTheBarOnThePrimaryPercentWithNoRunway`)
- **The monthly layout** uses its own day slots, whose rule is
  [credits'](credits-and-monthly-limits.md#dots-the-menu-bar-and-the-strip). It is drawn in the
  same slot.

### The held shapes

The limit that stopped you, or is about to, **takes the bar and holds there**: no reminder, no
pulse, no cycle. (`DisplayFormatter.longLimitBlockShape`; tests
`MenuBarRenderTests.testAmberRemindsAndRedHoldsInTheSpecGrammar`,
`LongLimitSurfaceAgreementTests.testABlockingLongLimitTakesTheBarAndHolds`,
`AppViewModelReminderScheduleTests.testABlockHoldsAtEveryInstant`, `testRedHoldsAtEveryInstant`)

- **Block:** in Over quota or Spend control whose [block episode](state.md#blocks-are-episodes)
  is a weekly or monthly limit, the string is `⚠wk 0%` or `⚠mo 0%` plus **that limit's own** reset
  countdown. The percent is a fixed `0%`, never read back from a reading that may be degraded or
  restored. A five-hour block keeps the ordinary string (`CL 0% ↻48m`). Reason: during a weekly
  block the five-hour percent and reset are irrelevant or misleading; the reset that ends the block
  is the weekly's.
- **Limit nearly spent:** the same shape with what is left of the worst long limit, and its own
  reset. Reason: in red, the long limit is what will stop you this week, so it stands in the bar
  rather than in a seven-second reminder that may never be seen.
- `wk` names every non-monthly long limit, whatever its reported width; `mo` names the monthly.
  (`longLimitMenuBarScope`)
- **A five-hour red speaks first.** At risk and Bad timing outrank both long-limit ranks
  ([state](state.md#the-states)), so the bar shows the five-hour string, and the long limit returns
  when they calm. (`testATightFiveHourOutranksRedAndTheWeeklyReturns`)
- Spend control on a monthly-layout account keeps the monthly string, because the monthly branch
  comes first. See Question 3.

### Stale and restored readings

A stale reading follows [display semantics](display-semantics.md#fresh-and-stale): the last
percent, a grey dot, no time slot; a monthly keeps its `↻Nd`. A hard block keeps red, and a
long-limit block keeps its name without the countdown: `CL ⚠wk 0%`, but only while the five-hour
window under it has not ended; after that it reads grey `—— est` (see Known gaps). Reason: which limit blocked is
not a countdown, and a spent limit cannot un-spend itself.
(`DisplayFormatter.staleMenuBar`; tests `DisplayFormatterTests.testStaleMenuBarHardBlockKeepsRedDotAndPercent`,
`testStaleMenuBarHardBlockWithExpiredWindowDegrades`, `DisplayFormatterMonthlyTests.testMonthlyStaleMenuBarE10`)

- A stale render carries no long-limit reading, so it never reminds and never ends an episode
  ([Episodes](#episodes)).
- A stale render draws **no money glyph** (Question 1).
- **State's Decided 1** (a stale *Limit nearly spent* keeps its red,
  [state](state.md#decided)) is not followed yet. Today that state goes Idle when stale, so the bar
  greys. When state follows the ruling, `staleMenuBar` must hold the nearly-spent shape too; it
  handles only hard blocks today (see Known gaps).

## The money glyph, drawn

When the glyph is armed or charging, and its hold, are
[credits'](credits-and-monthly-limits.md#the-money-glyph); its colours are
[display semantics'](display-semantics.md#colours). This page owns how it is drawn.
(`Views/MenuBarItemView.swift`: `MenuBarLineView`; `Views/Theme.swift`: `Theme.money`)

- **Position:** after the string, after the time slot, never in place of it. Reason: the reset is
  still when the charging stops.
- **Symbol:** the account's currency symbol, `$`, `€`, `£` or `¥`, and no others. Any other
  currency, or none reported, draws `$`. (`Fmt.moneyGlyphSymbol`; test
  `DisplayFormatterTests.testMoneyGlyphIsTheAccountsCurrencySymbol`)
- **Weight and size:** semibold, at the row's own size (9 pt, 11 pt, or the headline's).
- **Colour:** its own amber or red, independent of the text. Inside a reminder the whole row,
  glyph included, takes the account's colour.
- **Width:** measured through the real view like any other render; the glyph appearing is a state
  change, so the width may change then and only then ([Width](#width)).
- **Spoken:** "extra usage may start" (armed), "extra usage charging" (charging).
  (`TextLine.accessibilityLabel`; test `MenuBarRenderTests.testTheLabelCarriesTheMoneyGlyph`)

## The amber reminder

While a tool's worst long limit is in the *ahead of pace* tier (state Limit ahead of pace), its row
has **two phases**: the steady string, and for 7 seconds at a time a reminder naming the limit:
`CL ⚠wk 43%` — provider, limit, what is left. No reset: it is drawn as one larger line, and a
headline with four things in it stops reading at a glance; the reset is in the popover.
(`DisplayFormatter.longLimitReading`, `reminderString`; `MenuBarReminder`;
tests `MenuBarRenderTests.testOnlyTheReminderLostItsReset`, `MenuBarReminderTests.testTheSevenSecondBoundary`)

Why amber reminds at all: it never notifies, and the dot alone cannot say which limit, or how much
is left.

**Red never reminds.** A block and *Limit nearly spent* hold their shape instead
([The held shapes](#the-held-shapes)). A red limit beside an amber one holds the bar, and nothing
cycles. Nothing reminds under a five-hour warning, on a stale, loading, idle or null-window render,
or on a monthly-layout hero. (`MenuBarReminder.cadence(for:)` returns the amber cadence for every
tier; tests `MenuBarReminderTests.testTheCadenceConstantsAreTheSpecs`,
`testARedMonthlyHoldsOverAnAmberWeeklyInTheAccountColour`, `testAFiveHourWarningHoldsTheBarAndKeepsTheLimit`)

### Schedule

Measured reminder-start to reminder-start from when the tier began (`tierAt`):

| Since the tier began | A reminder |
|---|---|
| At once | On entry |
| First hour | Every minute |
| Second hour | Every 10 minutes |
| After that | Hourly, until acknowledged |

- **Two warning limits alternate,** worst tier first, then the nearer reset. Reason: one ranking for
  state, display and this cycle (`QuotaSnapshot.longLimitsRanked`). (`testTwoWarningsAlternate`)
- **Four unacknowledged days are 160 reminders.** The first hour is loud because one look ends it.
  (`MenuBarReminder.reminderCount`; `testFourDaysOfAmberIsOneHundredAndSixtyReminders`)
- **The dot never decays.** Between reminders the account's colour stays on the dot; only how often
  the bar spells out the limit decays.
- **One clock for both tools.** `AppViewModel` sleeps to the next phase edge, recomputed from the
  wall clock each time, with a 50 ms tolerance, and stops when no tool has an edge left. Reason: a
  long sleep without a tolerance was coalesced and woke seconds late, clipping every reminder after
  the first. (`AppViewModel.runReminderClock`, `syncReminderClock`; `MenuBarReminder.nextEdge`; tests
  `testEveryEdgeIsInTheFuture`, `AppViewModelReminderScheduleTests.testOnlyPhaseEdgesRepublish`,
  `testAClockThatStopsOnItsOwnRestartsForTheNextEpisode`)
- **The formatter never picks a phase.** It builds every line steady and lists its reminders; the
  schedule turns one line's phase on. So the first-run strip, which calls the same formatter, never
  shows a reminder. (`MenuBarRender.showingReminder`; `testTheFormatterNeverPicksAPhase`)

### Episodes

A warning is an **episode**: one per tool per long limit, stored so a relaunch is not a new
warning. (`Model/ReminderEpisode.swift`; `AppViewModel.syncReminderEpisodes`, `seedReminderEpisode`)

- **Two clocks.** `enteredAt` is when the limit first entered any warning tier and never moves.
  `tierAt` is when the current tier began and moves **only on escalation**, which restarts the loud
  first hour without restarting the episode. A step down inside the warning band keeps the clock, so
  a limit that gets less serious never gets louder. (`testEscalationKeepsTheEpisodeAndRedHoldsTheBar`,
  `testADeEscalationDoesNotRestartTheHour`)
- **The instance is the reset.** A different reset is a different week and a new episode; the
  reset is compared with Core's tolerance, so a one-second wobble is not a new week.
  (`ReminderEpisode.matches`)
- **Held is not recovered.** Each render carries a `LongLimitReading`: `unknown` (loading, idle,
  null window, monthly-layout hero, every stale render) holds the episode, both clocks and the tier;
  `live` names exactly the limits in a warning tier, so a limit missing from it has recovered. A block or a
  five-hour warning keeps its limit in the reading and only drops the line, so the episode survives
  them. Recovery is the tier clearing, not the percent falling: a week catching up with its own
  usage clears at unchanged utilization. (`LongLimitReading`; tests
  `MenuBarReminderTests.testAStaleRenderHoldsTheEpisode`, `testRecoveryAtUnchangedUtilization`,
  `AppViewModelReminderScheduleTests.testAStaleGapHoldsTheEpisodeRatherThanEndingIt`)
- **Stored** under `reminder_episode.<tool>.<limit>` (`limit` is `secondary` or `monthly`) as
  `enteredAt|tierAt|tier|resetsAt|acknowledgedAt`: unix seconds, the tier as its number (1 ahead of
  pace, 2 nearly spent, 3 spent), the last field empty until acknowledged. A four-field row restores
  as unacknowledged; a malformed row is cleared. Recovery clears the row (its value is written as
  `NULL` through `writeSetting`, so the change is audited).
  (`ReminderEpisode.storedValue`, `restored`; tests `testTheStoredValueCarriesTheAcknowledgement`,
  `testAMalformedSeedIsDropped`)
- **A relaunch** restores the episode waiting for confirmation. When the first live reading
  confirms the tier, it reminds **once**, showing the worst limit, then continues at the episode's
  true age, not the loud first hour. A limit that recovered while the app was closed has its row
  cleared. Reason: the reader has been away, not newly warned. (`testARelaunchRemindsOnceAndThenDecays`,
  `testASeedForARecoveredLimitIsCleared`)

### Acknowledgement

**Opening the popover or the app window acknowledges every live amber episode on both tools.**
Acknowledged episodes schedule no more reminders; the dot, the tab dot and the popover's strip stay
amber. A reminder already on screen ends at its own edge. An episode still waiting for its
relaunch confirmation is acknowledged too, and an acknowledged episode earns no relaunch reminder.
(`AppViewModel.acknowledgeReminders`, called from `PollCoordinator.popoverOpened`; tests
`AppViewModelReminderScheduleTests.testOpeningThePopoverAcknowledgesBothTools`,
`testAReminderOnScreenFinishesAfterTheLook`, `testAnAcknowledgedSeedStaysSilentOnRelaunch`)

- Reason for both tools: the normal user has one account and opens one popover.
- The trigger is the shared open hook, so any ordinary open counts: a left click, a notification
  click that opens a surface, or the app window. The maintainer confirmed the notification click
  as an acknowledgement on 2026-10-04: opening a quota surface is a look, whatever opened it. A **Set up …** card fires no open
  hook and does not acknowledge ([app lifecycle](app-lifecycle.md#when-the-app-window-opens-and-closes)).
- **Amber only.** The stamp rides along on escalation and is ignored in red.
  (`testAnAmberAcknowledgementDoesNotMuteRed`)
- **A re-entry after recovery** is a new, unacknowledged episode with the loud first hour.
  (`testReEntryAfterALookIsLoudAgain`)

## Drawing a reminder

- **Variant D.** During a reminder the item draws one vertically centred line in the account's
  colour, up to 13 pt, fitted to the width already reserved and never below the mode's row size.
  **The other tool's row is hidden** for those seconds. Reason: a single larger line reads at a
  glance; the cost is about 12 % of an unacknowledged first hour with the calm tool's text hidden,
  accepted because both dots return between reminders and a look ends the loud hour.
  (`MenuBarLayers`; test `MenuBarWidthTests.testTheHeadlineFitsInsideTheReservedWidthAtNoSmallerThanTheRowItReplaces`)
- **Pulse:** the reminding row, dot included, dims to 0.55 opacity and back, four 1.6 s cycles,
  starting after the fade. Fade plus pulse ends 0.25 s before the 7 s phase does.
  (`MenuBarLineView.pulse`; `MenuBarMotionTests.testThePulseStartsAfterTheFadeAndEndsInsideThePhase`)
- **Crossfade:** 350 ms, opacity only, in both directions and on every path in and out (scheduled
  edges, a new episode, an escalation, a recovery, a first warning). The outgoing layer is hidden
  from VoiceOver, takes no clicks, and is removed when the fade ends or a newer step overtakes it.
  The schedule does not move: the fade's tail belongs to the view.
  (`MenuBarCrossfade`; `MenuBarReminder.fades`; `testBothEdgesOfAReminderFade`, `testARecoveryFades`)
- **Lands at once, no fade:** a confirmed block, a red long limit, a five-hour warning that
  outranks the long limit, a missing or pending reading, a change in the number of rows, and an identical re-render. Reason: a
  fade is a softening, and arriving at a block should not be soft.
  (`ToolMenuBarDisplay.transition`; `testTheThreeExemptionsLandAtOnce`, `testArrivingAtRedLandsAtOnce`,
  `testALineCountChangeDoesNotFade`, `testAnIdenticalRerenderDoesNotFade`)
- **Reduce motion** drops the pulse and the fade, also mid-fade, and keeps the reminder and its
  colour. Reason: the reminder carries information; the motion only draws the eye.
  (`MenuBarReminder.pulses`; `testReducedMotionKeepsTheReminderAndItsColour`, `testReducedMotionDropsTheFade`)
- **One VoiceOver element per row.** The label spells out the glyphs ("Claude", "weekly limit",
  "resets in", "runs out in about") and, in the steady phase, appends the row's reminders, so a
  reader need not wait for the cycle. It does not say "left"; that gap is
  [display semantics'](display-semantics.md#known-gaps). (`TextLine.accessibilityLabel`;
  `testTheLabelStatesTheWarningInBothPhases`, `testTheLabelSpellsOutTheGlyphs`)

## Width

**The width changes only on a state change.** Notched Macs hide items that overflow, so the item
must not grow unpredictably, and a bar that grew for seconds every minute would shove every item to
its left. Digits are tabular. (`MenuBarController.render`, `reservedWidth`; `MenuBarWidth`)

- **Reserved, not re-measured.** When the steady form of the render changes, the controller
  measures every phase the render can show (the steady form plus each line showing each of its
  reminders, at most five) and keeps the widest. A phase edge re-measures nothing.
  (`MenuBarWidth.phaseRenders`, `steadyForm`; tests `testTheReservedWidthIsIdenticalAcrossAPhaseEdge`,
  `testTheCandidateListIsEveryPhaseAndNothingMore`)
- **The reminder costs nothing extra.** With no reset it is shorter than every string the bar
  already draws, so the reservation is the steady width.
  (`testTheReminderIsNarrowerThanTheStringItReplacesAndReservesNothingExtra`)
- **Measured off-screen in the row form.** The headline is fitted to the measurement, so it cannot
  be one of the things measured; a separate hosting view with no state also keeps five candidate
  layouts from running five crossfades. (`MenuBarItemView.Layout.measuring`, `measuringView`)
- **Pinned to the leading edge.** A stretched view would re-centre the row and move the text at
  every phase edge.

## Constants

| Constant | Value | Where |
|---|---|---|
| Runway slot cut | under 60 min | `DisplayFormatter.menuBarTimeSlot` |
| Reminder length | 7 s | `MenuBarReminder.reminderSeconds` |
| Amber cadence | 60 s / 600 s / 3 600 s | `MenuBarReminder.amberCadence` |
| Cadence phase edges | 3 600 s, 7 200 s after `tierAt` | `decayAfterSeconds`, `secondDecayAfterSeconds` |
| Pulse | floor 0.55, 1.6 s per cycle, 4 cycles | `pulseFloorOpacity`, `pulseCycleSeconds`, `pulseCycles` |
| Crossfade | 0.35 s | `transitionSeconds` |
| Headline cap | 13 pt | `headlineMaxSize` |
| Row text / dot | 9 pt / 5 pt stacked; 11 pt / 6 pt single; headline up to 13 pt / 6 pt | `MenuBarLayers` |
| No-tool mark | 14 × 14 pt | `MenuBarLayers.undetectedMark` |
| Reminder clock tolerance | 50 ms | `AppViewModel.runReminderClock` |

They are judgements about a menu bar, not replay results; the maintainer confirmed them as the
rule on 2026-10-04. The monthly slot's
seven-day cap is [credits'](credits-and-monthly-limits.md#dots-the-menu-bar-and-the-strip).

## Looking at it without a live warning

- `KVOTAR_MENU_BAR_FIXTURE=<name>` forces one long-limit fixture onto the live item, read once at
  launch, never stored: the forced tool writes no episode row. It also works in Release builds
  (see Known gaps). (`AppViewModel.menuBarFixture`, `persistEpisode`; `Previews/LongLimitFixtures.swift`;
  tests `testEveryFixtureNameResolvesAndAnUnknownOneDoesNot`, `testNoFixtureIsForcedByDefault`)
- With debug logging on, every change to the bar while a row can remind writes one `Menu-bar phase`
  line (strings already on the bar, nothing else), plus `Menu-bar transition`, `Menu-bar reminders acknowledged` and
  `Menu-bar reminder clock stopped` lines. Logging itself is [diagnostics'](diagnostics.md).
- `MenuBarSnapshots` writes PNGs of every phase when `KVOTAR_SNAPSHOT_DIR` is set.

## Rejected alternatives

- **Six modes.** *Hidden* removed the only place to undo it, so it needed a Terminal command to
  recover. *Adaptive* showed one dominant tool behind its own hysteresis and kept a whole
  arbitration subsystem alive. *Compact glyph* (a two-bar gauge) was the one answer for a crowded
  bar, but shared all that machinery; its loss is accepted until a compact mode is designed on its
  own terms.
- **A default mode saved from detection.** It strands a user whose second tool appears later.
- **Dormant gauge types kept for a future compact mode.** Dead code with an open question.
- **A permanent `⚠wk` slot.** It took the five-hour reset off the bar for days and never showed the
  long limit's own reset.
- **The five-hour percent and reset during a weekly block.** The number was irrelevant and the
  reset was not the one that ends the block.
- **A reminder for red.** A red long limit is what will stop you this week; it holds the bar.
- **A flat one-minute reminder.** A warning true for four days repeated about 5 760 times.
- **The reset inside the reminder.** Four things in a headline stop reading at a glance.
- **Hiding the runway when local logs go quiet.** The quota is account-wide; local silence proved
  nothing and let the bar disagree with the verdict.
- **A two-row stack for a single tool.** Reversed after a day: its time slot sat orphaned.
- **Shrinking the item to fit a full bar** is [app lifecycle's](app-lifecycle.md#rejected-alternatives).

## Known gaps

| Gap | Today | Proposed fix |
|---|---|---|
| A long-limit block with no five-hour percent | Both paths test for a missing five-hour percent before the block shape. Live: an Over quota reading with no primary percent reads `CX —— est` with a red dot. Stale: a weekly block whose five-hour window has expired keeps Over quota ([state](state.md#what-is-not-inferred-from-incomplete-evidence)), but `staleMenuBar` draws grey `CX —— est`, against [display semantics'](display-semantics.md#fresh-and-stale) "a stale block keeps red". The live case is likely: Claude's normal overnight reading is a null five-hour window with a live weekly; not yet observed. No test covers either; `testStaleMenuBarHardBlockWithExpiredWindowDegrades` pins only a five-hour-anchored block, and its comment ("the engine would never classify it") does not hold for a weekly anchor | Check `longLimitBlockShape` before the `——` test in `toolMenuBar` and `staleMenuBar`, with a test for each path; the existing test stays valid for a five-hour-anchored block |
| Stale *Limit nearly spent* | [State Decided 1](state.md#decided) keeps it red while stale; `staleMenuBar` holds only hard blocks | In the step that closes state's row: keep the red `⚠wk [left]%` shape without a slot, with a test |
| Money glyph dropped while stale | `staleMenuBar` takes no glyph, so the glyph vanishes on any stale render, including a hard block and the launch restore | Question 1 (kept for now) |
| `◔~60m` | The cut tests the unrounded runway, then rounds, so 59.5 to 59.99 minutes prints `◔~60m` | Round before the test, or floor the printed minute |
| Dormant `Fmt.compactReset` | No caller; three `DisplayFormatterWindowGrainTests` pin it | Decided 1: a later build step deletes `Fmt.compactReset` and its three tests |
| Menu-bar fixture works in Release builds | `AppViewModel.menuBarFixture` reads `KVOTAR_MENU_BAR_FIXTURE` with no `#if DEBUG`, so a shipped build will draw a fake long-limit warning when the variable is set | Gate it to Debug builds, as `AppDelegate` gates `KVOTAR_NOTIFICATION_FIXTURE` |
| Empty item for an undetected single tool | About 8 pt of clickable blank | Question 2 (decide later) |
| Stale comments | `MenuBarDisplay.swift` (`TextLine` doc, `accessibilityLabel`), the variant-D comment in `MenuBarItemView` and `compactReset`'s doc say five seconds; `MenuBarLineView.pulse` says three cycles running past a five-second phase; `loadingMenuBar` and `staleMenuBar` mention a gauge track that no longer exists; `longLimitReading` still names a reached-monthly case that reminds in red; `menuBarTimeSlot`'s doc sits above `longLimitMenuBarScope`; `MenuBarDisplayMode.label`, `MenuBarController` and `AppDelegate` describe a Settings window that does not exist yet (planned, see [product scope Decided 1](product-scope.md#decided)); `PollCoordinator.popoverOpened`, `acknowledgeReminders` and `MenuBarController` call the app window the "quota window"; `testTheReminderIsStableBetweenPolls` speaks of the reminder's compact reset | Fix with the next change to each file |

## Code and tests

- `Packages/KvotarUI/Sources/KvotarUI/Model/`: `MenuBarDisplay.swift`, `MenuBarWidth.swift`,
  `MenuBarReminder.swift`, `ReminderEpisode.swift`; `DisplayFormatter.swift` (`loadingMenuBar`,
  `toolMenuBar`, `staleMenuBar`, `menuBarRender`, `longLimitMenuBarScope`, `longLimitReading`,
  `reminderString`, `longLimitBlockShape`, `menuBarTimeSlot`, `Fmt.moneyGlyphSymbol`,
  `Fmt.compactReset`).
- `Packages/KvotarUI/Sources/KvotarUI/Views/MenuBarItemView.swift`, `Views/Theme.swift`
  (`menuBarStatus`, `money`), `Views/KvotarMarkView.swift`.
- `Packages/KvotarUI/Sources/KvotarUI/ViewModel/AppViewModel.swift`: `setMenuBarDisplayMode`, the
  reminder schedule, `seedReminderEpisode`, `acknowledgeReminders`, `menuBarFixture`.
- `App/MenuBarController.swift` (the status item, `render`, `reservedWidth`, not `contextMenu()`);
  `App/AppDelegate.swift` (the launch read of the mode, `onSelectMode`, the episode persist and
  seed); `App/PollCoordinator.swift` (`popoverOpened`).
- `Packages/KvotarCore/Sources/KvotarCore/Tool.swift` (`menuBarPrefix`);
  `Packages/KvotarCore/Sources/KvotarCore/Storage/SQLiteStore+Migrations.swift`
  (`v21_retire_menu_bar_modes`).
- Tests in `Packages/KvotarUI/Tests/KvotarUITests/`: `MenuBarRenderTests`, `MenuBarWidthTests`,
  `MenuBarReminderTests`, `MenuBarMotionTests`, `MenuBarExhaustionAgreementTests`,
  `AppViewModelReminderScheduleTests`, `LongLimitSurfaceAgreementTests`, `DisplayFormatterTests`
  (stale bar, money symbol), `DisplayFormatterMonthlyTests`, `DisplayFormatterWindowGrainTests`
  (`compactReset`), env-gated `MenuBarSnapshots`; in `Packages/KvotarCore/Tests/KvotarCoreTests/`:
  `SQLiteStoreTests.testV21RewritesRetiredMenuBarModes`.

Checked against the code at 8ed7e0c + STEP_268
