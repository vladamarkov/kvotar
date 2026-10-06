---
summary: The current rules for Kvotar's quota notifications — the eleven kinds, when each fires and what suppresses it, the two firing paths and the one-per-cycle arbitration, caps, cooldowns, block episodes and the per-instance keys, the weekly ladder, the low-allowance gate, what a switched-off group does inside the engine, when permission is requested and read, delivery (sound, Focus, the one action, withdrawal at reset) and every title and body.
read_when: Changing NotificationEngine (evaluateCycle, the Path 1 or Path 2 candidates, a cap, cooldown or priority constant, blockDecision, nearlySpentDecision, ladderCandidates, handleWindowReset, markDismissed, windowStart), NotificationEventType or its arbitrationPriority, NotificationGroup's effect in the engine, NotificationDecision, NotificationSignal or the PollCoordinator code that builds it, WeeklyLadder, WindowFact as a notification input, QuotaSnapshot.weeklyForNotifications, SQLiteStore+Notifications, UserNotificationPresenter (copy, sound, withdrawal, the action, requestAuthorization), NotificationFixture, AppDelegate's presenter wiring or refreshNotificationAuthorization, or the meaning of the block_episode.*, nearly_spent.*, ladder.* or notification_project_name_enabled settings rows.
---

# Notifications

## Questions for owner

1. **What should clicking a notification show? (Decide later.)** Today **Open Kvotar**, or a
   click on the banner, opens the routed surface on its default tab, not the notified tool's,
   and highlights nothing, so a Codex notice can open on the Claude tab. The maintainer keeps
   this for now. Open: should the click select the notified tool's tab, and should the older
   per-event highlight tables be dropped from the record or become a gap on [popover](popover.md)?
2. **Which name is the term for spend control?** The event is `spend_control`, the state is
   *Spend control* ([state](state.md#the-states)), [credits and monthly
   limits](credits-and-monthly-limits.md#spend-control-as-a-condition) calls it a condition, and
   the banners say *spend limit reached* (Claude) and *monthly limit reached* (Codex). This page
   describes today's code and does not settle it.

## About this page

This page is the specification for Kvotar's quota notifications: which ones exist, when each
fires or is suppressed, how it is delivered, and its exact copy. It replaces the private
Implementation Baseline §13.2 (NotificationEngine architecture; the `notification_events` column
table stays with [storage](storage.md#tables-by-purpose)) and the rest of §16 (Notification
baseline) not already replaced, the notification marks in the private Baseline threshold
sections, the meaning of the notification keys in the private settings table (§17.1), the
private UI Spec Part 1 §4 (Notifications, with §4.1, §4.1a and §4.2), Part 2 §4.1 (the Codex
events) and the notification rows of both parts' §5 (Thresholds), and an older private
notification behaviour note. Change this page in the same commit as the code it describes.

What neighbours own:

| Topic | Page |
|---|---|
| Which state a tool is in, the tiers, the block episode, the warning tier, first-evaluation silence | [State](state.md) |
| What a window, a reset, a window fact and an expired window are | [Quota readings](quota-readings.md#resets) |
| Runway, poll-pair deltas, the pace clock the ladder reads | [Forecast](forecast.md#poll-pair-deltas) |
| Percent left, clock, countdown and "resets" grammar; the copy rule | [Display semantics](display-semantics.md#time-and-reset-wording) |
| What spend control, money states and the charging case mean | [Credits and monthly limits](credits-and-monthly-limits.md#money-states-claude) |
| Confirmed idle, active surfaces, subagents | [Local usage](local-usage.md#surfaces-and-helpers), [State](state.md#the-states) |
| The four groups' labels, defaults, keys and screen 4 | [First-run window](first-run-window.md#screen-4--when-should-kvotar-interrupt-you-onboardingnotificationsscreen) |
| **Notify me ▸** and the permission hint rows | [Menu actions](menu-actions.md#notify-me-and-its-permission-hints) |
| Which surface **Open Kvotar** opens | [App lifecycle](app-lifecycle.md#when-the-app-window-opens-and-closes) |
| The hidden menu-bar item notice | [App lifecycle](app-lifecycle.md#the-notice) |
| The `notification_events` table and its 90-day retention; the settings table | [Storage](storage.md#tables-by-purpose) |
| The permission fact in Save Diagnostics… | [Diagnostics](diagnostics.md#save-diagnostics) |
| The window-changed fact in History; the work-per-1% series | [Capacity learning](capacity-learning.md) |
| Menu-bar reminders and their acknowledgement | [menu bar](menu-bar.md) |
| What the popover shows and its recommendation copy | [popover](popover.md) |
| History's Hard blocks | [History window](history.md) |

**The hidden menu-bar item notice is not one of these notifications.** It is posted directly,
outside the engine, groups, arbitration and caps; all of it is on
[app lifecycle](app-lifecycle.md#the-notice).

## Who decides what

- **The state engine knows nothing about notifications.** It classifies, reports a transition
  (`StateChange`) and publishes a primary-window reset on its `windowResets` stream.
  ([state](state.md#when-state-is-evaluated))
- **`NotificationEngine` decides whether and which notification fires.** It owns caps,
  cooldowns, re-arm, episodes, instance keys, the ladder and arbitration. It is copy-free.
  (`Notifications/NotificationEngine.swift`)
- **`UserNotificationPresenter` owns delivery and every word.** It turns a
  `NotificationDecision` into a macOS notification. (`App/UserNotificationPresenter.swift`)
- **`PollCoordinator` drives it.** After every state evaluation it calls
  `evaluateCycle(change:signal:now:)` once for that tool. (`App/PollCoordinator.swift`)

## The eleven notifications

`NotificationEventType` has eleven cases; the raw value is what `notification_events.event_type`
stores, so renaming one is a storage change. (`Notifications/NotificationTypes.swift`;
`NotificationGroupTests.testEveryEventBelongsToExactlyOneGroupExceptWindowChanged`)

"Per window" below means per `window_start`: the primary window's reset minus its
provider-reported width (five hours when none is reported; in practice only a Codex payload
missing its width, since the Claude adapter sets five hours), or, with no reset,
a clock bucket of that width. (`NotificationEngine.windowStart`, `fallbackWindowLength`;
`NotificationEngineLowAllowanceTests.testWindowStartUsesTheReportedWidth`,
`testMissingWidthKeepsTheFiveHourFallback`, `testUnanchoredBlockDoesNotReNotifyEveryFiveHours`)

| Event (`event_type`) | Path | Fires when | At most | Cooldown | Priority | Group | Sound | Withdrawn at reset |
|---|---|---|---|---|---|---|---|---|
| Over quota (`over_quota`) | 1 | The tool enters Over quota | Once per block episode; once per window if the block has no episode | — | 1 | Over quota | yes | Only if the episode's limit is the primary (or there is no episode) |
| Spend control (`spend_control`) | 1 | The tool enters Spend control | As Over quota | — | 1 | Over quota | yes | no |
| Window changed (`window_changed`) | 2 | A window fact this poll recorded (one candidate per fact) | No cap; a fact that loses arbitration is not offered again | — | 2 | none (always on) | no | no |
| At risk (`at_risk`) | 1, re-arm on 2 | The tool enters At risk; re-arm below | 2 per window, first fire and re-arm together | — | 3 | At risk | yes | yes |
| Limit nearly spent (`limit_nearly_spent`) | 1; 2 on a seven-day primary | The tool enters Limit nearly spent; on a seven-day primary see [the ladder](#the-weekly-ladder) | Once per limit instance | — | 4 | At risk | yes | no |
| Bad timing (`bad_timing`) | 1 | The tool enters Bad timing, except on a seven-day primary | 1 per window | — | 5 | At risk | yes | yes |
| Limit ahead of pace (`limit_ahead_of_pace`) | 2 | A weekly ahead of pace stands on a ladder step deeper than any announced | Once per step per weekly instance | — | 6 | At risk | no | no |
| Fast burn spike (`fast_burn_spike`) | 2 | The poll-pair rise is at least 20 points | 2 per window | 10 min | 7 | Fast burn | no | yes |
| Off-machine burn (`off_machine_burn`) | 2 | Rising at least 2 points over the last two polls while local activity is confirmed idle, on two consecutive poll signals | 3 per window | 20 min | 8 | Fast burn | no | yes |
| Multi-surface (`multi_surface`) | 2 | Codex only: two or more active surfaces **and** a rise of at least 10 points within 120 s | 2 per window | 10 min | 9 | Fast burn | no | yes |
| Window resets soon (`window_reset_pre`) | 2 | The reset is more than 0 and less than 30 min away and a warning-tier state was seen this window | 1 per window | — | 10 | Window reset | no | yes |
| Window has reset (`window_reset_post`) | 2 | A genuine rollover (below) | 1 per window | — | 10 | Window reset | no | no |

(Constants: `NotificationEngine` `atRiskMaxPerWindow`, `badTimingMaxPerWindow`,
`overQuotaMaxPerWindow`, `spendControlMaxPerWindow`, `fastBurnDeltaPct`, `fastBurnCooldown`,
`fastBurnMaxPerWindow`, `offMachineDeltaPct`, `offMachineSustainedPolls`, `offMachineCooldown`,
`offMachineMaxPerWindow`, `multiSurfaceMinBuckets`, `multiSurfaceDeltaPct`,
`multiSurfaceCooldown`, `multiSurfaceMaxPerWindow`, `atRiskRearmRunwayMin`, `preResetWindowMin`,
`postResetGuardMin`, `windowResetPreMaxPerWindow`, `windowResetPostMaxPerWindow`. Priority:
`NotificationEventType.arbitrationPriority`; test
`NotificationEngineTests.testArbitrationPriorityMatchesSection16`. Group:
`NotificationEventType.group`. Sound: `UserNotificationPresenter.audibleEvents`. Withdrawal:
`UserNotificationPresenter.withdrawsAtReset`.)

The thresholds are starting values, not measured optima. What the states themselves mean, and
their own thresholds, is on [state](state.md#thresholds); the deltas and runway are
[forecast](forecast.md#poll-pair-deltas)'s.

### Notes per event

- **Over quota and Spend control are one banner per block episode.** The episode is the spent
  limit with the latest reset ([state](state.md#blocks-are-episodes)). One key per tool, shared by
  both events, is stored as `block_episode.<tool>` = `<limit>|<reset unix seconds>` and compared
  within the reset tolerance, so a five-hour rollover, a
  stale gap, a relaunch or a one-second reset wobble is the same block; a second limit reaching
  the ceiling inside it changes the copy, not the count. A **poll** that sees no blocking limit
  clears the key, so the next block is a new episode; a cycle without a poll signal never ends
  one. A different blocking limit or reset is a new episode and sends again, including after a
  relaunch (for example the primary was spent first, then the weekly). A block with no reset to
  key on falls back to once per window. Reason: keyed to the
  five-hour window, one spent weekly sent a fresh banner on every rollover underneath it.
  (`blockDecision`, `setEpisodeKey`; `NotificationEngineTests.testOneBannerPerEpisodeAcrossAFiveHourRollover`,
  `testRelaunchInsideAnEpisodeFiresNothing`, `testTheNextBlockIsItsOwnEpisode`,
  `testRecoveryClearsTheStoredEpisodeKey`, `testACycleWithoutASignalDoesNotEndAnEpisode`,
  `testAWobbledResetIsTheSameEpisode`, `testBlockWithNoEpisodeKeepsThePerWindowCap`,
  `testSpendControlIsOneBannerPerEpisode`; `BlockEpisodeReplayTests.testTheTesterEpisodeSendsOneBannerPerBlock`)
- **Over quota picks a copy variant, Claude only** (`copy_variant`): `case_1` while usage credits
  are paying, `case_2` when credits were used earlier but are not paying now, `case_3` for a hard
  block, including a spent credits cap. Codex has no variant. What each money state means is
  [credits and monthly limits](credits-and-monthly-limits.md#money-states-claude)'s.
  (`NotificationEngine.overQuotaVariant`; `testOverQuotaCase2WhenCachedCreditsPresent`,
  `testOverQuotaCase3WhenNoCredits`, `testOverQuotaCodexHasNoVariant`) There is no separate money
  notification: the charging case is Over quota's copy.
- **At risk re-arms once.** On a poll where the tool is still At risk, the runway is under
  10 minutes and the latest At risk notice this window has been acknowledged, it fires again,
  sharing the cap of 2. (`atRiskRearmCandidate`; `testAtRiskRearmRequiresDismissAndLowRunway`,
  `testAtRiskRearmSuppressedWhenRunwayAbove10`, `testAtRiskFirstFireThenCappedAtTwo`)
- **Limit nearly spent is once per limit instance:** the limit plus its reset, stored as
  `nearly_spent.<tool>.<limit>` (value: the reset in unix seconds) and compared within the reset
  tolerance. A new week or month fires again; the same one never does, across a rollover, a gap
  or a relaunch. There is no per-window cap on purpose: the window bucket is five hours, and a
  weekly warning keyed to it would re-arm every few hours. While a five-hour red state holds the
  tool, there is no transition into Limit nearly spent; when that calms, the transition fires it.
  (`nearlySpentDecision`; `testNearlySpentFiresOncePerLimitInstance`,
  `testNearlySpentIsSilentAfterARelaunchInTheSameInstance`,
  `testNearlySpentFiresAgainOnTheNextInstance`, `testNearlySpentDoesNotRefireOnResetJitter`,
  `testNearlySpentKeysAreIndependentPerLimit`, `testNearlySpentWaitsForTheFiveHourWarningToPass`)
- **Entering Limit ahead of pace sends nothing.** Only the weekly ladder sends event 10.
  (`testLimitAheadOfPaceTransitionFiresNothing`)
- **Fast burn reads the same poll-pair rise the state does**: two consecutive polls at most
  300 s apart, the newer at most 300 s old ([forecast](forecast.md#poll-pair-deltas)). It does
  not need the tool to be in Fast burn spike. (`fastBurnCandidate`;
  `testFastBurnObeysCooldown`, `testFastBurnBelowThresholdDoesNotFire`,
  `testFastBurnCappedAtTwoPerWindow`)
- **Off-machine needs the rise on two consecutive poll signals.** A poll that is not rising, or
  where idle cannot be confirmed, resets the run; a rollover resets it too. Confirmed idle is
  [state](state.md#the-states)'s (`LocalAttribution.isConfirmedIdle`); a session never observed
  is "cannot confirm" and never fires. (`offMachineCandidate`;
  `testOffMachineRequiresTwoSustainedPolls`, `testOffMachineDormantWhenLocalUnknown`,
  `testOffMachineDormantWhileLocalActive`)
- **Multi-surface counts real surfaces active now** (the same list as the state; subagents and
  `Unknown` never count) and needs a rise of 10 points inside the last 120 s.
  (`multiSurfaceCandidate`; `testMultiSurfaceFiresForCodex`, `testMultiSurfaceIgnoredForClaude`,
  `testMultiSurfaceCappedAtTwoPerWindow`)
- **Window resets soon** needs a warning-tier state (At risk, Bad timing, Over quota, Spend
  control — [state](state.md#severity)) seen on any poll of this window by this process, and is
  never offered on the process's first poll of the tool. (`windowResetPreCandidate`;
  `testWindowResetPreFiresWhenWarningAndCloseToReset`)
- **Window has reset** needs all of: the window key changed, the reset moved later by more than
  60 s (`minResetAdvanceForRollover`), the previous poll still saw an open window, and the new
  reset is more than 4 h 30 min away. A window that starts after an idle stretch (previous
  reading had no reset) is the user's own fresh start, not a reset, and stays silent. The
  rollover is detected once, so a post-reset candidate that loses arbitration is lost.
  (`signalCandidates`; `testWindowResetPostFiresAndRetainsPriorWindow`,
  `testWindowResetPostIgnoresSubSecondJitter`, `testWindowResetPostSuppressedOnFreshStartAfterIdle`,
  `testWindowResetPostSuppressedWhenLaunchedDuringIdle`,
  `testPostResetSuppressedWhenHigherPriorityWinsRolloverCycle`)
- **Window changed offers one candidate per fact** the poll recorded (`WindowFact.fold` over the
  detector's `window_added`, `window_removed` and `window_width_changed`; a width change with an
  added window at the same instant is one *restructured* fact; `early_reset` is never one). No
  cap and no cooldown, but no retry either: the fact exists only on the poll that observed it,
  so at most one fact fires per poll and a fact that loses arbitration (to a block, or to another
  fact on the same poll, at the same priority) is lost; History still records it. Always on, because the
  planning assumptions it reports broke whether or not the user wanted to hear. The facts
  themselves are [quota readings](quota-readings.md#resets)'. (`testWindowFactOnThePollSignalFiresWindowChangedOnce`,
  `testWindowChangedRanksBelowOverQuotaAndAboveAtRiskAndHasNoSwitch`)

## Two firing paths and one cycle

**Path 1 is the transition.** When an evaluation changes state, `transitionCandidate` maps the
new state: Over quota, Spend control, At risk, Bad timing and Limit nearly spent have a
notification; every other state has none.

**Path 2 is the poll signal.** After a successful poll, `PollCoordinator` builds a
`NotificationSignal` from the snapshot it classified (after expired windows degrade), the
forecast and local attribution: state, used percent, runway, reset and width, the low-allowance
flag, window facts, block episode, worst long limit, the weekly for the ladder, the three
deltas, last local activity, active surfaces, model and project. `signalCandidates` builds every
other candidate from it. (`PollCoordinator`, the `NotificationSignal(…)` call before
`evaluateCycle`)

**Only a successful poll has a signal.** The launch restore, a failed or refused poll's
staleness check and a local-file change call `evaluateCycle` with `signal: nil`, so only Path 1
can fire from them, with no project or model in the copy. A block that the restore still holds
can therefore notify at launch, but no rate, reset, ladder or window-changed notice can.
(`PollCoordinator`: the restore, `evaluateStaleness`, `handleLocalDelta`;
`WeeklyLadderTests.testACycleWithoutAPollSignalNeverSendsAStep`)

**One cycle, at most one notification.** `evaluateCycle` collects the Path 1 candidate and all
Path 2 candidates, drops disabled groups, then fires the one with the lowest priority number.
Ties go to the earlier candidate, which is the transition. Losers are logged
(`Notification suppressed · reason=arbitration`) and write nothing, so their caps and cooldowns
are untouched and they are offered again next cycle if they still qualify. Reason: no stacking —
the user gets one message per moment. (`testSingleDeliveryPerCycleHighestPriorityWins`,
`testSuppressedCandidateStillEligibleNextCycle`, `testFastBurnBeatsOffMachineAndMultiSurface`,
`testTransitionWinsTieOverSignalCandidateOfEqualPriority`)

**Observation runs even when nothing fires.** Rollover detection, the per-window memory, the
last reset and width, and the open-window flag advance on every signal, whatever wins.

**Housekeeping on every poll signal.** A signal with no block episode clears
`block_episode.<tool>`; a stored `nearly_spent.*` or `ladder.*` value whose reset has passed is
cleared. A new instance would not match an old value anyway; this keeps dead rows out of
`settings`. (`expirePassedNearlySpentValues`, `expirePassedLadderValues`)

**What the engine keeps in memory, per tool**, and so loses at relaunch: the current window
start, the last reset and width, the off-machine run, whether a warning was seen this window,
whether the last poll had an open window, and which weekly instances it has seen at the red
line. Everything else it reads from `notification_events` and `settings`. Consequence: a reset
that happens while Kvotar is not running, or across a relaunch, sends no *Window has reset*.

### First evaluation and launch

**A relaunch with a saved reading (the usual case).** The launch restore is the tool's first
evaluation. It always classifies the saved reading as stale, so the tool sits at Idle unless a
block still holds ([state](state.md#when-state-is-evaluated)). The restore runs with no poll
signal, so only that block can notify from it (once per episode, or once per window with no episode). The **first fresh poll** is
then an ordinary cycle: Idle → At risk, Bad timing, Limit nearly spent or any other state is a
real transition and Path 1 offers it, and every Path 2 candidate is offered except *Window
resets soon* (never on the process's first poll) and *Window has reset* (needs a previous poll in
this process). What limits a repeat across the relaunch is only what is stored: the per-window
rows (so an At risk window that already sent one notice can send its second; Bad timing fires
if it was not sent this window), the block episode, the nearly-spent instance and the ladder
step. Window changed compares against the restored reading, so a change overnight is announced.
(`PollCoordinator` restore → `evaluateCycle(signal: nil)`; `StateEngine.classify` stale branch;
`StateEngineTests.testRestoreThenLivePollIntoNearlySpentEmitsChange`)

**No saved reading (first run, or a tool first seen mid-session).** The first evaluation is the
first poll and is silent, except that landing directly in a hard block or in Limit nearly spent
is reported as a change from Idle ([state](state.md#when-state-is-evaluated)); the episode and
instance keys stop a later relaunch from repeating it.
(`testColdLaunchHardBlockFiresOncePerWindowAcrossRelaunches`,
`testColdLaunchNearlySpentFiresOncePerInstanceAcrossRelaunches`, `testLaunchIntoWarningDoesNotNotify`)
Path 2 candidates are offered on that poll too, except the two window-reset notices.

**The weekly ladder needs no transition** in either case: it is level-triggered on the poll
signal, so the first fresh poll that finds a weekly past an unannounced mark announces it once.
A restored reading never does. (`WeeklyLadderTests.testAFirstReadingPastTheSecondMarkSendsOnlyThatStep`)

## The weekly ladder

Every weekly warns on the way down: **50 → 25 → 10 → 0 % left**, and **50 → 25 → 15 → 0** on a
seven-day primary. The first two marks are event 10, `limit_ahead_of_pace`; the third is event 9,
`limit_nearly_spent`; the last is Over quota. (`Notifications/WeeklyLadder.swift`)

**Which windows are a weekly.** `QuotaSnapshot.weeklyForNotifications`: the secondary window as
the long-limit assessment builds it, else a primary whose reported width is exactly seven days,
anchored, on a shape that is not low-allowance. Never a monthly limit, a per-model allowance, the
30-day Free / Go primary or an unanchored weekly. The engine is its only reader; the long-limit
readers on screen still exclude the primary ([state](state.md#long-limits-as-states)). The pace
input for a seven-day primary is [forecast](forecast.md#the-pace-clock)'s.
(`WeeklyLadderTests.testTheSecondaryIsTheWeeklyExactlyAsTheLongLimitAssessesIt`,
`testASevenDayPrimaryIsTheWeekly`, `testTheLongLimitReadersStillExcludeThePrimary`,
`testOutOfScopeStaysOut`)

**The two early steps.** When the weekly's tier is *ahead of pace* (the amber rule on
[state](state.md#long-limits-as-states)), the step is `half` below `weeklySecondNoticePct`
(75 % used) and `quarter` at or past it. On pace, nothing. (`WeeklyLadder.step(for:)`;
`testTheStepIsHalfBelowTheSecondMarkAndQuarterFromIt`, `testOnPaceAtSeventyFiveSendsNothing`)

**Rules:**

- **Level-triggered against what was announced.** On any poll signal the step the weekly stands
  on is a candidate if it is deeper than the deepest step already announced for this instance.
- **An overtaken step is never sent.** A first reading at 23 % left sends `quarter`, and `half`
  can no longer follow. Reason: someone told "a quarter left" does not also need "half gone".
  (`testAFirstReadingPastTheSecondMarkSendsOnlyThatStep`, `testADeeperStepFollowsAndAShallowerOneNeverDoes`)
- **The red line closes the early steps.** Once the weekly has reached nearly spent or spent in
  this instance — event 9's stored key, or seen by this process even when the group was off —
  neither early step follows. (`testAFirstReadingAtNinetyTwoSendsNearlySpentAlone`,
  `testTheRedLineReachedUnannouncedStillClosesTheEarlySteps`)
- **The key is written only when the step fires:** `ladder.<tool>.<limit>` =
  `<reset unix seconds>|<step>`. A step that loses arbitration writes nothing and is offered on
  the next poll; losing costs one poll, not the step.
  (`testTheKeyIsTheInstanceAndTheLowestStep`, `testAStepThatLosesArbitrationIsSentOnTheNextPollAndNotBefore`)
- **Nothing repeats a step:** a relaunch, a poll gap, a one-second reset wobble, a five-hour reset
  under the weekly, or the pace recovering and slipping again. **A new instance starts again:**
  the ordinary reset, or a week the provider ended early (a different reset before the old one).
  (`testARelaunchInsideASentStepSendsNothing`, `testAOneSecondResetWobbleIsTheSameWeek`,
  `testAFiveHourResetUnderTheWeeklySendsNothingNew`, `testPaceRecoveringAndSlippingAgainSendsNothingNew`,
  `testANewInstanceStartsTheLadderAgain`, `testAnEarlyResetRearmsTheLadder`)
- **The five-hour window's state does not gate it.** The ladder reads the assessment, not the
  rank; a higher-priority five-hour notice only delays a step by arbitration.
- **Silent, in the At risk group, kept across five-hour resets.** Half a week left is not "about
  to be stopped". (`testEventTenSitsBelowBadTimingAndAboveFastBurnInTheAtRiskGroup`,
  `testEventTenFollowsTheAtRiskSwitch`)

**On a seven-day primary, Bad timing and Limit nearly spent change places.**

- `bad_timing` is not sent there (`reason=weekly_primary`); the **state** is untouched and the
  tab still turns red at 85 %. Reason: "85 % with the reset ≥ 90 min away" is a predicament on a
  five-hour window and only a position on a week. At risk is unchanged.
  (`testBadTimingIsNotSentOnASevenDayPrimary`, `testBadTimingStillFiresOnAFiveHourPrimary`,
  `testAtRiskStillFiresOnASevenDayPrimary`)
- `limit_nearly_spent` is decided on the poll signal at `weeklyPrimaryNearlySpentPct`, which is
  Bad timing's line (85 % used, 15 % left), once per instance under `nearly_spent.<tool>.primary`.
  There is no transition to ride, because Bad timing outranks Limit nearly spent on this shape.
  Reason: the notice arrives with the red state. The secondary weekly keeps 90 %, where its own
  red state is. (`testASevenDayPrimaryIsNearlySpentAtTheLineItsTabTurnsRedAt`,
  `testNearlySpentOnASevenDayPrimaryFiresOncePerInstance`)
- **Accepted:** this position test has no reset-distance gate, so in a week's last 90 minutes the
  notice can come without the red state.

**The switch.** `WeeklyLadder.isEnabled` is `true`. Set to `false`, every decision is still made
and logged (`Ladder would send …`, `Ladder would suppress bad_timing`), no key is written,
nothing is delivered, and events 2 and 9 behave as they did before the ladder. It is the revert
target. (`testTheShippedSwitchIsOn`, `testWithTheSwitchOffNothingChanges`,
`testWithTheSwitchOffTheLadderWritesAndSendsNothing`)

The marks were chosen on a replay of a small set of weeks (`WeeklyLadderReplayFixtures`;
`testEveryReplayedWeekFiresEachRungOnceAtTheReplaysHour`,
`testTheThreeExhaustedWeeksLeadTheStopByDays`); 75 % is supported, not proven.

## The low-allowance gate

On the Codex low-allowance shape (Free or Go, or one window of 30 days or more and nothing else —
[state](state.md#what-is-not-inferred-from-incomplete-evidence)), **only Over quota and Window
changed can fire.**

- Path 1 drops every transition except into Over quota (At risk, Bad timing and Spend control
  are logged `reason=low_allowance_shape`). At risk and Bad timing cannot be reached there
  anyway; Spend control and Limit nearly spent need a monthly or weekly limit, which the
  window-width backstop excludes and the two named plans have not been seen with.
- Path 2 drops At risk re-arm, fast burn, off-machine, multi-surface, both window resets and the
  ladder after the bookkeeping has run, and keeps window changed.

Reason: one turn moves that meter by a large share, so every rate-derived notice would be noise,
and a reset of a 30-day window carries nothing to act on (a ruling about the 30-day window; a
seven-day Plus window is not this shape and keeps its resets). Window changed is a fact about the
windows, not a rate. (`NotificationEngineLowAllowanceTests`:
`testBlockedPayloadFiresOverQuotaAndNothingElse`, `testFastBurnIsSilent`,
`testWindowResetPostIsSilent`, `testFiveHourShapeKeepsFastBurn`,
`testSevenDayWindowFiresWindowResetOnceTheRuleIsCorrect`)

## Groups inside the engine

The four groups (At risk, Fast burn, Over quota, Window reset), their labels, defaults and
`notification_<group>_enabled` keys are the [first-run
window](first-run-window.md#screen-4--when-should-kvotar-interrupt-you-onboardingnotificationsscreen)'s;
the menu that flips them is [menu actions](menu-actions.md#notify-me-and-its-permission-hints)'.
Inside the engine:

- **A disabled group is dropped before arbitration and before `fire`.** A switched-off
  higher-priority notice cannot silence an enabled lower one, and a dropped candidate uses no
  cap or cooldown and writes no row or key, so switching a group back on starts clean. The
  group rows are read from `settings` on each cycle that has a candidate in that group.
  (`dropDisabledGroups`; `NotificationGroupTests.testDisabledHigherPriorityDoesNotSilenceEnabledLower`,
  `testReEnabledGroupHasFullCap`, `testAtRiskDisabledDropsAtRiskAndBadTiming`,
  `testOverQuotaDisabledDropsOverQuota`)
- **Window changed has no group** and cannot be switched off.
- **Thresholds, caps, cooldowns and priorities do not change** with the groups.
- **History reads this page's rows.** Its Hard blocks come from `over_quota` rows in
  `notification_events` (`SQLiteStore.limitHits`). With the Over quota group off, no row is
  written, so History shows no blocks; Spend control rows are not read at all ([History window](history.md#hard-blocks-depend-on-the-over-quota-notifications)).

## Permission

- **Requested** with alert and sound (no badge), at two moments only: the first-run window's
  **Allow & continue**, and, for an install that has already finished or skipped onboarding,
  when the poll coordinator first reports a detected tool in this process. Never at launch
  otherwise; macOS shows the prompt at most once and the app never re-prompts.
  (`UserNotificationPresenter.requestAuthorization`; `AppDelegate`: `requestNotifications`,
  `onFirstToolDetected`; `OnboardingGate.decide`; [first-run window](first-run-window.md#when-it-opens))
- **Read, never requested,** at launch, on wake, when the one request resolves, and each time the
  right-click menu opens. The read takes the permission, the alert style and the sound setting,
  and logs only when one changes. What the menu shows from it is
  [menu actions](menu-actions.md#notify-me-and-its-permission-hints)'; the diagnostics fact is
  [diagnostics](diagnostics.md#save-diagnostics)'. (`AppDelegate.refreshNotificationAuthorization`)
- **The engine never reads it.** With notifications denied, decisions, rows and keys are written
  as usual and macOS drops the banner. A notice decided before permission was granted is spent.

## Delivery

- **Write, then deliver.** `fire` appends the `notification_events` row, writes the episode,
  nearly-spent or ladder key, then hands the decision to the presenter. A failed write does not
  block delivery; a failed delivery is logged and undoes nothing. Reason: a block or a weekly
  warning that fired must stay fired across a crash or relaunch. (`NotificationEngine.fire`)
- **One identifier per tool, event and window** (`stableRequestID` =
  `<tool>-<event_type>-<window_start>`). A re-fire in the same window replaces the banner in
  place instead of stacking. (`testStableRequestIDFormat`, `testRefireProducesSameStableRequestID`)
- **Standard delivery only.** No interruption level is set, so every notice is the standard
  level. Time Sensitive delivery is deferred and absent; Critical is not used. Kvotar has no
  Focus or quiet-hours logic of its own; macOS applies Focus and Do Not Disturb to standard
  notifications.
- **Shown while Kvotar is frontmost** (`willPresent` returns banner and sound).
- **Sound** is the default macOS sound on the five events that say *you are about to be stopped,
  or you just were*: Over quota, Spend control, At risk, Bad timing, Limit nearly spent. The rest
  arrive silently. The user's per-app sound switch still wins.
  (`audibleEvents`; `UserNotificationPresenterTests.testEveryEventTypeHasAPinnedSoundAnswer`)
- **One action, Open Kvotar**, plus the system Dismiss. No snooze. A click on **Open Kvotar** or
  on the banner opens the routed surface
  ([app lifecycle](app-lifecycle.md#when-the-app-window-opens-and-closes));
  the default tab opens, not the notified tool's, and nothing is highlighted. That is the rule
  for now (maintainer's ruling); what it should become is Question 1.
- **Any response is an acknowledgement.** Opening or dismissing a notice calls `markDismissed`,
  which sets `dismissed_at` on the latest row of that tool and event in the current window. Only
  the At risk re-arm reads it. So `dismissed_at` means *opened or dismissed*.
  (`didReceive`, `onAcknowledge`; `SQLiteStoreNotificationsTests.testMarkDismissedUpdatesMostRecent`)
- **Withdrawal at a primary-window reset.** When the state engine reports the reset, the
  presenter removes that tool's delivered notices flagged `withdraw_at_reset` and delivered
  before the reset: At risk, Bad timing, Fast burn spike, Off-machine burn, Multi-surface, Window
  resets soon, and an Over quota whose episode is the primary or has none. Kept: a weekly or
  monthly block, Spend control, Limit nearly spent, Limit ahead of pace, Window has reset and
  Window changed. Reason: Notification Center must not keep a claim the reset made untrue. The
  block episode is deliberately not cleared by the reset. (`withdrawsAtReset`, `windowDidReset`,
  `NotificationEngine.handleWindowReset`; `testNoticesAboutTheEndedWindowAreWithdrawn`,
  `testLongLimitsAndNewsAreKept`, `testOverQuotaFollowsItsBlockingLimit`,
  `NotificationEngineTests.testWindowResetTellsThePresenter`)
- **Project name.** At risk, Bad timing, Over quota, Fast burn spike, Off-machine burn and
  Multi-surface append ` Project: <folder>.` when the poll signal names a project (the last path
  component). Account-level notices never do. `notification_project_name_enabled = "false"`,
  read once at launch, turns it off. It stays a hidden setting by the maintainer's ruling: nothing in the app sets it (see Known gaps).
  (`UserNotificationPresenter.body(for:includeProject:)`; `AppDelegate`)

## Every title and body

`<Tool>` is `Claude` or `Codex`. Figures are examples. Percent, clock, countdown and "resets"
forms follow [display semantics](display-semantics.md#time-and-reset-wording), with the
exceptions in its Known gaps. `<countdown>` here is `25 min` or `2h 5m` below 48 hours and
`3 days` from there; `<time>` is the system short time; `<when>` for a block is `Oct 9, in 3 days`
(48 hours or more) or `at <time>, in 2h 5m`, or `when the window resets` without an episode.
A runway prints whole minutes up to 48 hours (`~11 min`, `~125 min`), then days.
(`App/UserNotificationPresenter.swift`: `title(for:)`, `coreBody`, `nearlySpentBody`,
`aheadOfPaceBody`, `windowChangedBody`, `blockReset`, `resetIn`, `runwayIn`)

| Event | Title | Body |
|---|---|---|
| At risk | `<Tool> quota at risk` | `13% left · runs out in ~11 min at this pace. Resets at <time>.` (no runway: `13% left · at risk. …`) |
| Bad timing | `<Tool> may block before reset` | `12% left with 2h 5m until reset. You could hit the limit before your quota refreshes.` |
| Over quota, block on the primary window, Claude hard block | `Claude quota exceeded` | `0% left · hard block. Resets in 45 min.` |
| Over quota, block on the primary window, Claude `case_2` | `Claude quota exceeded` | `0% left · credits no longer accruing ($12.00 used earlier · last observed). Hard block. Resets in 45 min.` |
| Over quota, block on the primary window, Codex (a spent seven-day primary too: `… Resets in 3 days.`) | `Codex quota exceeded` | `0% left · Codex CLI will block new requests. Resets in 45 min.` |
| Over quota, weekly block | `<Tool> stopped — weekly spent` | `The weekly quota is used up. Resets <when>.` |
| Over quota, both windows spent | `<Tool> stopped` | `Both windows are spent. Resets <when>, when the weekly resets.` |
| Over quota, credits paying (Claude `case_1`) | `Claude 5-hour spent` or `Claude weekly spent` | `Now running on usage credits ($50.00 cap). Weekly resets <when>.`; on the five-hour: `… 5-hour resets at <time>, in 45 min.` (`5-hour resets in 45 min.` without an episode); no cap reported: no brackets |
| Spend control, Claude | `Claude spend limit reached` | `The $500.00 monthly limit is used up. Resets <when>.` (no amount: `Your monthly spend limit is used up. …`) |
| Spend control, Codex | `Codex monthly limit reached` | `Monthly workspace limit reached. New requests are blocked until the limit resets <when>.` |
| Window changed | `<Tool> quota window changed` | `A weekly window was added.` · `Your 5-hour window was removed.` · `Your weekly window is now 120-hour.` · `You now have a 5-hour window and a weekly window — before, weekly only.` (no fact: `Your quota windows changed. See the History window.`) |
| Limit nearly spent, weekly | `<Tool> weekly nearly spent` | `8% of the weekly left, with 3 days until it resets Oct 9. Your 5-hour window is fine.` Under 48 hours: `…, and it resets Oct 9.` |
| Limit nearly spent, monthly, Claude | `Claude monthly spend nearly reached` | `$40.00 of the $500.00 limit left, with 10 days until it resets Nov 1. Ask your workspace admin if you need more.` |
| Limit nearly spent, monthly, Codex | `Codex monthly limit nearly reached` | `300 of 4,000 credits left, with 10 days until it resets Nov 1. You can request a limit increase from ChatGPT settings → Usage.` |
| Limit ahead of pace, `half` | `<Tool> weekly won't last at this pace` | `48% left with 4 days until it resets Sun 8:45 pm. That is about 12% a day; this week has averaged 17% a day.` |
| Limit ahead of pace, `quarter` | `<Tool> weekly: a quarter left` | Same body |
| Fast burn spike | `<Tool> usage spike detected` | Claude: `+24% since the last check on <model>.` Codex adds ` If unexpected, check Codex for a runaway loop.` |
| Off-machine burn, Claude | `Claude usage rising` | `Likely Claude Desktop here, claude.ai, or another computer. 40% left · resets at <time>.` |
| Off-machine burn, Codex | `Codex usage on another machine` | `Codex is idle here. Usage likely from another machine or Codex Web. 40% left · resets at <time>.` |
| Multi-surface | `Codex usage spike detected` | `+12% in ~2 min · Desktop + CLI both active on <model>.` Three or more: `… all active …`; fewer than two names: `… multiple surfaces active …` |
| Window resets soon | `<Tool> quota resets soon` | `Your 5-hour window resets in 25 min. Full quota available shortly.` |
| Window has reset | `<Tool> quota reset` | `Your 5-hour window has reset. Full quota available.` |

Rules behind the copy:

- **The block copy names the limit that stopped you** and its own reset, not the five-hour
  window's. The weekly shape is an episode on the secondary; *both windows* is that with the
  primary also at 100 %. Reason: a week-long block titled "quota exceeded" pointed at a reset
  three days early. (`testOverQuotaNamesTheWeeklyAndItsOwnReset`,
  `testOverQuotaBothWindowsNamesWhenWorkResumes`, `testOverQuotaOnThePrimaryIsUnchanged`)
- **Credits paying is decided first**, on either plan family: nothing has stopped, so the title
  says *spent*, never *stopped* or *exceeded*; money prints in the provider's currency.
  (`testOverQuotaChargingOnTheFiveHour`, `testOverQuotaChargingOnTheWeeklyInTheProvidersCurrency`,
  `testOverQuotaChargingWithNoCapDropsTheBrackets`, `testOverQuotaWithTheCapSpentIsAPlainWeeklyBlock`)
- **Codex's spend-control copy names the workspace's monthly limit** and says new requests are
  blocked until it resets; this wording, not the older record's *spend limit … Contact your
  admin*, is the rule (maintainer's ruling). (`testSpendControlNamesTheLimitPerTool`)
- **Claude's spend-control title stops short of "stopped"**, because what reaching the Claude
  monthly limit stops has not been observed ([credits and monthly
  limits](credits-and-monthly-limits.md#spend-control-as-a-condition)).
  (`testSpendControlNamesTheLimitPerTool`)
- **The window is named by its reported width**, `5-hour` when none is reported (in practice
  only a Codex payload missing its width; the Claude provider reports no width and the Claude adapter sets five hours). (`DisplayFormatter.windowGrain`; `testWindowChangedBodiesNameWidthsNeverSizes`)
- **The nearly-spent weekly tail** *Your 5-hour window is fine.* appears only on a secondary
  weekly while the primary is under 90 % used; never on a seven-day primary, which has no
  five-hour window. (`testNearlySpentDropsTheReassuranceWhenTheFiveHourIsAlsoHot`,
  `testNearlySpentOnAWeeklyOnlyAccountHasNoFiveHourSentence`)
- **The ladder body is a per-day budget, never a run-out date.** Budget = percent left ÷ days to
  the reset; average = used ÷ days elapsed, dropped while less than one day has elapsed. No
  five-hour tail and no project name: a planning notice says one thing.
  (`testTheAverageIsDroppedInTheWeeksFirstDay`, `testTheBudgetOnAWeekWithALittleOverADayLeft`,
  `testAheadOfPaceBodyIsAccountLevelAndSaysOneThing`)
- **Percent is left, never used**; "resets", never "back"; no polling words.
  (`testNoBodyContainsPercentUsed`, `testTheLadderCopyPassesTheStandingSweeps`;
  [display semantics](display-semantics.md#the-copy-rule-no-polling-words))

## The test aid: `KVOTAR_NOTIFICATION_FIXTURE`

In a **Debug build only**, setting `KVOTAR_NOTIFICATION_FIXTURE` at launch plays one scripted
weekly through the notification path so its banners can be seen for real. It runs a throwaway
`NotificationEngine` with no store: no `notification_events` row and no key is written, and the
engine the poll loop drives never sees a frame. Only the presenter is the real one, so macOS
permission still applies. With no store the four group switches are not read, so every group is
at its default. Frames start 10 s after launch, 20 s apart. Read once, never stored.

| Value | What it sends |
|---|---|
| `ladder-steps` | A Claude weekly off pace: `half`, then `quarter`, then nothing on a repeat reading |
| `weekly-only-nearly-spent` | A Codex seven-day primary at 92 % on its first reading: Limit nearly spent alone, once |
| `weekly-only-bad-timing` | A Codex seven-day primary crossing 85 %: Limit nearly spent in place of Bad timing |

An unknown value does nothing. (`App/NotificationFixture.swift`; `AppDelegate`, under `#if DEBUG`;
`NotificationFixtureTests`)

## Rejected alternatives

- **A block cap per five-hour window.** One spent weekly sent a fresh banner at every rollover
  underneath it. Replaced by the block episode.
- **Post-reset on every new window.** A window that starts after idle is the user's own start;
  telling them it "has reset" is wrong. Distinct "new window" copy was also rejected as noise at
  the moment the user began working.
- **Weekly notices from the first *won't make it*, from a runway trigger, or as a daily budget.**
  The first two ride the last hour's rate and can fire with most of the week left; the third
  repeats on a sustained state. Catch-up of an overtaken step, and a ladder on monthly limits or
  per-model allowances, were rejected too.
- **Fast-burn body variants with a subagent count, or an off-machine wording.** An older record
  specified both for Claude; neither was built, and the one body names the rise and the model.
- **Fast burn over a two-minute clock window.** The poll cadence could not fill it; the rise
  between two consecutive polls replaced it ([forecast](forecast.md#poll-pair-deltas)).
- **A token floor for off-machine idle.** A long local turn writes no usage line and read as
  idle; confirmed idle replaced it ([state](state.md#the-states)).
- **A money notification kind.** The charging case is Over quota's copy; a notice before credits
  start paying was not built.
- **A switch for Window changed.** It is rare and always actionable.
- **Critical alerts** and **snooze** are not used. Kvotar sets no interruption level, so every
  notice is delivered at the standard level.

## Known gaps

| Gap | Today | Proposed fix |
|---|---|---|
| Countdown form | Notification countdowns print `45 min` and `2h 5m` (`resetIn`), runway `~11 min` and `~125 min` (minutes up to 48 hours); elsewhere the sub-hour countdown is `43m` (`Fmt.countdown`) and the record says `48m` | Decide on [display semantics](display-semantics.md#time-and-reset-wording); then use `Fmt.countdown` here or record `min` as the notification form |
| Project-name opt-out has no control | The key is read at launch; no menu, window or command sets it (kept hidden by ruling) | Add a control only with a future settings surface; until then this page is where the key is documented |
| `dismissed_at` means opened or dismissed | Any response marks the row; the column name and the record say "dismissed" | Keep the behaviour (an opened notice was seen); say "acknowledged" in the next comment touching `markDismissed` and in [storage](storage.md#tables-by-purpose) |
| Screen 4 Over quota line over-promises | The first-run window says *Tells you when it comes back.*; no Over quota event sends such a notice, and the end of a weekly or monthly block sends nothing | A later contract changes the first-run copy ([first-run window](first-run-window.md#screen-4--when-should-kvotar-interrupt-you-onboardingnotificationsscreen)) to match the engine |
| Screen 4 Window reset line over-promises | The first-run window says *Fresh quota, only after a window where you were warned.*; only the pre-reset notice needs a warning, the post-reset notice fires on any reset the app watched | A later contract changes the first-run copy to match the engine |
| No *Window has reset* across a relaunch | Rollover detection is in memory, so a reset while Kvotar was not running sends nothing | Accept and keep, or persist the last reset per tool; owner's call |
| Red line reached unannounced, then relaunch | "Reached" is remembered across a relaunch only through event 9's key. If the group was off (or a block came first), the app relaunched and the provider lowered the reading in the same week, an early step could follow | Accepted in the record; no such sequence observed. Persist "reached" if one is |
| History blocks depend on a switch | `limitHits` reads `over_quota` rows only, so the Over quota group off means no blocks in History, and Spend control blocks never appear | Decide on [History window](history.md#questions-for-owner); for example read blocks from `state_transitions` |
| Duplicate thresholds | `NotificationEngine.fastBurnDeltaPct` (20) and `offMachineDeltaPct` (2) copy `StateEngine`'s constants of the same meaning | Point the engine at the `StateEngine` constants with its next change |
| Multi-surface's 120 s delta | Often finds only one sample at the 120 s cadence | On [forecast](forecast.md#known-gaps) |
| Notification percent, clock, unknown reset, copy-rule sweep | Truncated percent, system clock style, `a few min` for an unknown reset, most bodies not swept | On [display semantics](display-semantics.md#known-gaps) |
| Stale comments | `NotificationTypes`: `NotificationDecision.windowStart` says "the 5-hour window", `deltaPct` "the 2-minute window", `NotificationSignal` "input to `handlePoll`", `isLowAllowanceShape` "Over quota as the only kind"; `UserNotificationPresenter` says "nine" events; `includeProjectName` and `AppDelegate` say a toggle UI is coming in a later numbered step; `LongLimitAssessment.Tier.aheadOfPace` says "it never notifies"; `SQLiteStore.limitHits` says one row per window (it is one per episode); the `NotificationEngine` type comment and the `StateEvaluation` comment in `AppState.swift` say launching into a warning never notifies (true only without a saved reading); `NotificationDecision.primaryWindowSeconds` says `nil` on Claude | Fix with the next change to each file |

## Code and tests

Under `Packages/KvotarCore/Sources/KvotarCore/`: `Notifications/NotificationEngine.swift`,
`Notifications/NotificationTypes.swift` (events, priorities, groups, decision, signal, presenter
protocol), `Notifications/WeeklyLadder.swift`, `Notifications/WindowFact.swift`,
`Storage/SQLiteStore+Notifications.swift`, `QuotaSnapshot.weeklyForNotifications` in
`Adapters/AccountAdapter.swift`, `StateEngine.weeklySecondNoticePct` and
`weeklyPrimaryNearlySpentPct` in `State/StateEngine.swift`, `LongLimitAssessment`'s
nearly-spent key in `State/LongLimitAssessment.swift`, `BlockEpisode` in
`State/BlockEpisode.swift`.

App: `App/UserNotificationPresenter.swift`, `App/NotificationFixture.swift`; in
`App/AppDelegate.swift` the presenter wiring, `onFirstToolDetected`,
`refreshNotificationAuthorization`; in `App/PollCoordinator.swift` the engine, `onAcknowledge`,
`start` (the reset stream) and every `evaluateCycle` call.

Tests in `Packages/KvotarCore/Tests/KvotarCoreTests/`: `NotificationEngineTests`,
`NotificationEngineLowAllowanceTests`, `NotificationGroupTests`, `WeeklyLadderTests` with
`WeeklyLadderReplayFixtures`, `BlockEpisodeReplayTests`, `SQLiteStoreNotificationsTests`. In
`AppTests/`: `UserNotificationPresenterTests`, `NotificationFixtureTests`,
`NotificationPermissionHintTests`, `OnboardingGateTests`.
