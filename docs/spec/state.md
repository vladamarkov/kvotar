---
summary: The current rules for which state a tool is in — the priority list, the thresholds, how severe each state is, how a state calms down, the long-limit (weekly and monthly) tiers, and what is and is not concluded from missing, stale or expired readings.
read_when: Changing StateEngine, AppState, StateInputs, StateTrigger, StateChange, LongLimitAssessment, BlockEpisode, QuotaSnapshot.longLimit / blockEpisode / monthlyReached / isLowAllowanceShape / degradingExpiredWindows, DisplayFormatter.dot(for:), a state threshold, the de-escalation hold, or what a stale or restored reading classifies as.
---

# State

## Questions for owner

None.

## Decided

The maintainer ruled on these on 2026-10-04 (STEP_247). The code does not follow them yet; each
has a row in *Known gaps* below, which a later build step closes.

1. **A stale *Limit nearly spent* keeps its red while its limit's reset is still ahead,** like a
   block. The reading keeps its "as of" time on screen
   ([display semantics](display-semantics.md)), and returning to fresh data sends no second alert.
   Reason: a used percentage only rises within a window, so an old 92 % is still true or worse; the
   cost, a red that can outlive a provider's early reset until the next good poll, is the one the
   block rule already accepts. Today it drops to Idle like every other non-block state.

## About this page

This page is the specification for state classification. It replaces the private Baseline §13,
§13.1 and §13.4 (the state half; §13.2 and §13.3 stay with the pages that own notifications and
loading), and the private UI Spec §0.2 and the condition column of §1.2. Change this page in the
same commit as the code it describes.

What a reading, a window, a reset and staleness *mean* is in [quota readings](quota-readings.md).
How a state is worded and coloured on screen is in [display semantics](display-semantics.md). When
polls happen is in [polling](polling.md). Three pages consume state:
[notifications](notifications.md) (what fires on a transition, the weekly ladder), [forecast](forecast.md)
(burn, runway and the pace clock) and [credits and monthly limits](credits-and-monthly-limits.md)
(credits and the monthly pool's own layout).

## The states

Once evaluated, a tool is in exactly one state, from `AppState`. The raw values are what
`state_transitions.to_state` stores; renaming one is a storage change.
(`Packages/KvotarCore/Sources/KvotarCore/State/AppState.swift`: `AppState`)

| Rank | State (raw value) | Condition, first match wins | Severity |
|---|---|---|---|
| 13 | Idle / fallback (`idle_fallback`) | No reading at all, or the reading is stale (see [quota readings](quota-readings.md)) and is not a block | grey |
| 1 | Spend control (`spend_control`) | The provider's spend-control flag, or a monthly pool at or over 100 % | red |
| 2 | Over quota (`over_quota`) | Primary at or over 100 %, secondary (weekly) at or over 100 %, or the provider's limit-reached flag | red |
| — | *Low-allowance shape* | Codex only: Elevated at 60 % used or more, else Healthy (see below) | — |
| 3 | At risk (`at_risk`) | Primary used ≥ 75 % **and** runway < 30 min | red |
| 4 | Bad timing (`bad_timing`) | Primary used ≥ 85 % **and** the primary reset is ≥ 90 min away | red |
| 5 | Limit nearly spent (`limit_nearly_spent`) | The worst long limit is in the *nearly spent* tier | red |
| 6 | Fast burn spike (`fast_burn_spike`) | Primary rose ≥ 20 points between two polls ≤ 5 min apart, the newer ≤ 5 min old | amber |
| 7 | Off-machine burn (`off_machine_burn`) | Primary rose ≥ 2 points over the last two polls **and** local activity is confirmed idle | amber |
| 8 | Multi-surface (`multi_surface`) | Codex only: two or more surfaces active now. Needs no primary window | amber |
| 9 | Elevated (`elevated`) | Runway < minutes to the primary reset **and** the primary is over pace | amber |
| 10 | Limit ahead of pace (`limit_ahead_of_pace`) | A primary window is populated **and** the worst long limit is in the *ahead of pace* tier | amber |
| 11 | Healthy (`healthy`) | A primary used percentage exists and nothing above matched | green |
| 12 | Null window (`null_window`) | No primary window (absent or expired — see [quota readings](quota-readings.md)) and nothing above matched | neutral |

The table is in **evaluation order**; the Rank column is `AppState.priorityRank`, the **urgency
order** (lower is more urgent). They differ only for Idle, which is checked first as a guard (no
usable data) but is the least urgent. The hold below and the default popover tab read the
urgency order. Code comments use the older list numbering instead (Spend control 2, Over quota 3,
At risk 4, Bad timing 5, Limit nearly spent 5b, …, Limit ahead of pace 10, Null window 12); this
page names states rather than numbers. (`State/StateEngine.swift`: `StateEngine.classify`;
`AppState.priorityRank`; `AppStateTests.testPriorityRankSeverityOrder`)

Why first-match-wins: one tool can satisfy several conditions at once, and the user gets one
sentence. The order puts what is already true (a block) above what is forecast (runway), a
five-hour red above a long-limit red, and a long-limit red above a five-hour amber.

- **Limit nearly spent sits between the five-hour reds and the ambers.** A five-hour red (At
  risk, Bad timing) still speaks first; a five-hour amber does not, because a limit about to
  stop you outranks a fast hour.
- **Limit ahead of pace needs a populated primary window; Limit nearly spent does not.** With
  no primary window the account is on the monthly layout, which paints its own amber from the
  monthly forecast (see [credits and monthly limits](credits-and-monthly-limits.md)). Two amber sources on one meter
  would disagree. That layout has no way to say *nearly spent*, so Limit nearly spent may pre-empt it.
  (`StateEngineTests.testMonthlyLayoutKeepsNullWindowAtAmberAndYieldsAtRed`)
- **Elevated is pace-gated; At risk and Fast burn are not.** Against a weekly window "runway <
  time to reset" is almost always true, so without the pace clock 5 % used classified Elevated
  for about a fifth of an evening. At risk and Fast burn stay ungated so a late-window burst is still
  caught. The pace clock and its 2 % grace live in [forecast](forecast.md);
  (`Adapters/AccountAdapter.swift`: `QuotaSnapshot.paceExceeded`).
- **Over quota reads `≥ 100`, not `> 100`.** Claude's usage endpoint caps utilization at exactly
  100, so a strict test never fired. (`StateEngineTests.testOverQuotaAtExactly100`)
- **A spent weekly is Over quota**, not an amber weekly state. It stops the account.
  (`StateEngineTests.testSpentWeeklyIsOverQuota`)
- **Off-machine needs *confirmed* idle**: local activity was seen this run and the newest event
  is at least 8 minutes old. Never seen is "cannot confirm" and does not fire. Claude Code writes
  a usage line only when a turn completes, so a token-rate test misread long turns as idle.
  (`Attribution/AttributionEngine.swift`: `LocalAttribution.isConfirmedIdle`, `idleGap`)
- **Multi-surface counts real surfaces active in the last 8 minutes.** A subagent runs inside a
  surface and is not a second one; an `Unknown` surface is never active, because a state it raised
  could not name what to act on. (`Attribution/SurfaceWorkSplit.swift`: `activeSurfaces`)

### Thresholds

All live in `StateEngine` except where noted. They are starting values from replay or judgement,
not measured optima.

| Constant | Value | Used by |
|---|---|---|
| `atRiskUtilFloor` / `atRiskRunwayGateMin` | 75 % / 30 min | At risk |
| `badTimingUtil` / `badTimingResetDistanceMin` | 85 % / 90 min | Bad timing |
| `fastBurnDeltaPct`; `ForecastEngine.fastBurnMaxPollGap` | 20 points; 300 s | Fast burn spike |
| `offMachineBurnDeltaPct`; `LocalAttribution.idleGap` | 2 points; 480 s | Off-machine burn |
| `overQuotaUtil` | 100 % | Over quota (primary and weekly); the monthly and tier tests use a literal 100 |
| `lowAllowanceElevatedUtil` | 60 % | Low-allowance shape |
| `longLimitAheadFloorPct` | 50 % used | Long-limit amber floor |
| `longLimitProjectionPct` | projects past 110 % | Long-limit amber trigger |
| `longLimitNearlySpentPct` | 90 % used | Long-limit red line |
| `QuotaSnapshot.paceGraceFraction` | first 2 % of the period | Elevated and long-limit amber |
| `deEscalationCalmPolls` | 3 | De-escalation hold |
| `glyphDemotePolls` | 2 | Money-glyph hold (display-only) |
| `cachedStateTTL`, `resetJitterTolerance` | defined in [quota readings](quota-readings.md) | When a reading is stale, when a window has expired |

Three more constants sit in `StateEngine` but no state reads them: `weeklySecondNoticePct`,
`weeklyPrimaryNearlySpentPct` (notification marks, [notifications](notifications.md)) and
`modelWindowWarnLinePct` (85 %, where a per-model allowance becomes a model warning in the
[account summary](account-summary.md#model-warnings); it is never the hero, and it is
deliberately not the long-limit red line, so moving one never moves the other).

The long-limit numbers are replay-derived over a small corpus. 90 % is the weakest: it was chosen
when only one exhausted long limit had been recorded, and 85, 90 and 95 all warned it. The later
weekly-ladder replay counted three exhausted weeks (`weeklySecondNoticePct`'s comment); 90 has not
been re-graded against them (see Known gaps).

## Severity

Severity is a grouping of the states, not a second state machine. There is no severity type in
code; the grouping is the dot colour.
(`Packages/KvotarUI/Sources/KvotarUI/Model/DisplayFormatter.swift`: `DisplayFormatter.dot(for:)`;
test `DisplayFormatterTests`)

| Severity | States |
|---|---|
| red (critical) | Spend control, Over quota, At risk, Bad timing, Limit nearly spent |
| amber (elevated) | Fast burn spike, Off-machine burn, Multi-surface, Elevated, Limit ahead of pace |
| green (calm) | Healthy |
| neutral | Null window — a known, normal state, not an error |
| grey | Idle / fallback (and Loading, which is not a state — see below) |

The colours themselves, and the cases where the display repaints a dot from a percentage instead
of the state (the low-allowance shape, the monthly layout, a stale reading), are in
[display semantics](display-semantics.md).

Two subsets of states are named in code because other engines read them:

- **Hard block** — Over quota and Spend control (`AppState.isHardBlock`). Observed, not forecast.
  The only states that survive staleness (below).
- **Warning tier** — At risk, Bad timing, Over quota, Spend control (`AppState.warningStates`).
  It arms the pre-reset notification and stamps when a warning was first shown in the forecast log.
  **Limit nearly spent is deliberately not in it**: both readers are about the five-hour window,
  and a spent weekly is no reason for a five-hour pre-reset banner.
  (`AppStateTests.testNearlySpentIsNotWarningTier`)

## Long limits as states

A **long limit** is a secondary (weekly) window or a monthly pool. The primary window is never
assessed as a long limit, even when it is seven days wide (a seven-day primary keeps the ordinary
ranks; Bad timing is what turns it red). (`Adapters/AccountAdapter.swift`:
`QuotaSnapshot.longLimitAssessments`; `LongLimitAssessmentTests.testTheLongPrimaryWindowIsNotTiered`)

Each long limit gets one of four tiers, tested in this order
(`QuotaSnapshot.longLimitTier`, `State/LongLimitAssessment.swift`: `LongLimitAssessment.Tier`):

| Tier | Rule | Becomes |
|---|---|---|
| spent | At or over 100 %, or the provider's flag (monthly) | Over quota / Spend control |
| nearly spent | At or over 90 %, **whatever the pace** | Limit nearly spent |
| ahead of pace | Past the 2 % grace, at least 50 % used, **and** `used ÷ elapsed × 100 > 110` | Limit ahead of pace |
| on pace | None of the above | nothing |

- **The red tiers are position tests and ignore pace**; amber needs all three conditions. A gate
  that hides early false alarms must never hide a real late one.
- **Amber asks where the pace lands, not whether it is ahead.** On a week, a pace two points
  ahead projects to about 114 % on day 1 and about 102 % on day 6 — the first is real, the second
  noise (on day 1 the floor below still holds it). The test is cross-multiplied so a limit
  exactly on the 110 line stays on pace.
  (`LongLimitAssessmentTests.testTheProjectionLineIsExclusiveAtItsEdge`)
- **The floor** stops day-one noise: 3 % used on the first morning is "ahead of schedule" and
  means nothing.
- **One limit speaks: worst tier wins, then the nearer reset**, then the weekly before the monthly.
  State, display and the Limit nearly spent notification read this one ranking; the weekly
  notification ladder reads the weekly on its own (`QuotaSnapshot.weeklyForNotifications`,
  [notifications](notifications.md)).
  (`QuotaSnapshot.longLimitsRanked`, `longLimit(now:)`)
- **A weekly with no reported width paces against seven days**; Codex reports one and paces
  against it. (`QuotaSnapshot.secondaryWindowFallbackSeconds`)
- Long-limit ranks paint the tab and menu-bar dot but **not the five-hour verdict**, which stays a
  sentence about the five-hour window. That is a display rule; see display semantics.

**Rejected, don't re-propose:**

- *Weekly elevated* (`weekly ≥ 85 %` and nothing else, retired). It could not tell 85 % with five
  days left from 85 % with three hours left, never looked at a monthly, and showed a spent weekly
  amber. Stored rows that say `weekly_elevated` decode as `limit_ahead_of_pace`
  (`AppState.init(storedRawValue:)`); there is no migration.
- *Bare `used > elapsed`* for amber: it cannot tell a rounding error from a blowout.
- *A points slack* instead of the time grace: on the replay it silenced most genuine warnings.

## Blocks are episodes

A block belongs to the limit that caused it, not to the five-hour window it happened during.
`QuotaSnapshot.blockEpisode` picks, among the spent limits (primary at 100 % or flagged, weekly at
100 %, monthly reached), **the one whose reset is latest** — the reset that must pass before work
resumes. The spend-control flag counts against the monthly when one exists, else the primary. A
spent limit with no reset cannot form an episode. (`State/BlockEpisode.swift`: `BlockEpisode`;
`StateEngineTests.testEpisodeKeysToTheLimitWithTheLatestReset`)

Why: a weekly stayed spent for three days while the five-hour window rolled underneath it. Keyed to
the five-hour window, the app flipped Over quota ↔ Idle in every poll gap and sent a fresh banner
per rollover. (`BlockEpisodeReplayTests`)

## Calming down: the de-escalation hold

States escalate at once. A calmer candidate (higher `priorityRank`) is adopted only after
**3 consecutive poll-triggered evaluations** agree; until then the previous state is held and no
transition is written or announced. Why: burn in agentic sessions is spiky, and Healthy ↔ Elevated
flapped. (`StateEngine.resolveHysteresis`)

Adopted at once, without the hold:

- **A window reset or a withdrawn window.** Every held verdict was measured against a window that
  no longer exists. (Detection of reset and withdrawal: [quota readings](quota-readings.md).)
- **Any drop to Idle.** Lost data is not calming down; a warning must not freeze on dead data.
- **Leaving Off-machine burn while local activity is live.** A resumed local session proves the
  burn is not off-machine.

All three apply on any trigger. Only `.poll` evaluations advance the count; local-file and
poll-failure evaluations can escalate but never count towards calming. (`StateEngineTests.testHysteresisNonPollTriggersDoNotCount`)

The menu-bar money glyph uses the same escalate-now, demote-later rule with 2 polls; it is
display-only and adds no state (`StateEngine.resolveGlyphHysteresis`;
[credits and monthly limits](credits-and-monthly-limits.md)).

## When state is evaluated

`StateTrigger` says why an evaluation ran (`State/AppState.swift`; stored in
`state_transitions.triggered_by`):

| Trigger | When | Refreshes freshness? |
|---|---|---|
| `poll` | A successful account poll | Yes |
| `jsonl_delta` | A meaningful local change: a new surface, a new subagent (Claude only), a burn-tier crossing, or an observed quota 429. Debounced 5 s by the shared file watcher | No |
| `poll_failure` | A poll failed or was refused; re-checks the cached reading | No |
| `restore` | Launch, classifying the last saved poll | No |

(`App/PollCoordinator.swift`: `handleLocalDelta`, `evaluateStaleness`, the launch restore;
`Packages/ClaudeAdapter/Sources/ClaudeAdapter/ClaudeLocalAdapter.swift`: `emitDelta`;
`Packages/KvotarCore/Sources/KvotarCore/Adapters/JSONLDirectoryWatcher.swift`)

**The first evaluation of a tool is silent**, except when it lands directly in a hard block or in
Limit nearly spent. Those are position facts, not rates, and are emitted as a change from Idle; the
notification keys dedupe relaunches. On a usual relaunch the first evaluation is the launch
restore, which classifies the saved reading as stale, so the tool sits at Idle unless a block still
holds; the first fresh poll is then an ordinary transition and can notify. Notices on the poll
signal need no transition. The launch rules are the
[notifications](notifications.md#first-evaluation-and-launch) page's.
(`StateEngineTests.testFirstEvaluationHardBlockEmitsChange`,
`testFirstEvaluationNearlySpentEmitsChange`)

## What is not inferred from incomplete evidence

The rule throughout: **an absent input is "cannot confirm", never calm-by-default and never zero.**
A state whose input is missing is skipped, and the list falls through to the next.

| Evidence | What the engine concludes |
|---|---|
| No reading has ever arrived | Idle |
| A stale reading (see [quota readings](quota-readings.md): too old, or cached past its reset) | Idle, **unless** a block episode still exists — then Spend control or Over quota is kept |
| A restored reading at launch | Always classified as stale (a restore never refreshes freshness): only a still-live block survives |
| An expired window (see [quota readings](quota-readings.md)) | Its readings and flags are dropped first; a block on it ends, an expired primary is Null window |
| No primary window (absent or expired) | Null window, unless a block, Limit nearly spent or (Codex) Multi-surface applies |
| Fewer than two polls (no runway, no deltas) | At risk, Elevated, Fast burn and Off-machine cannot fire; blocks, Bad timing, both long-limit states and Multi-surface can |
| No reset on a long limit | No tier at all — even 91 % used stays unranked, but 100 % on a weekly is still Over quota |
| No reset on the primary | Bad timing and Elevated cannot fire |
| Local activity never observed | Off-machine burn cannot fire |
| Codex low-allowance shape (Free or Go plan, or one window ≥ 30 days and nothing else) | No rate-derived ranks: Elevated at ≥ 60 % used, else Healthy; blocks still classify |

Why blocks survive staleness: a used percentage only rises within a window,
so a cached block is a fact with an expiry. The same holds for Limit nearly spent, which is ruled to
survive too (Decided 1) but does not yet. Every rate-derived state rots with its inputs. Bad
timing is deliberately not kept either. (`StateEngine.classify` stale branch;
`StateEngineTests.testRestoredHardBlockKeepsItsVerdict`, `testStaleWarningsStillClearAtTTL`,
`testStaleBlockSurvivesOnTheWeeklyAnchorAfterThePrimaryExpires`)

Why expiry is applied before classifying: an expired window describes spend already forgiven. The
engine and the display share one degradation, so they cannot disagree about whether a window is
over. (`QuotaSnapshot.degradingExpiredWindows`;
`StateEngineTests.testExpiredWindowIsNullOnEveryTrigger`)

Why the low-allowance shape suppresses rates: one turn can move the meter by a fifth of the
allowance, so any runway would be wrong before it is drawn. Bad timing is excluded explicitly:
"reset ≥ 90 min away" is permanently true on a 30-day window and would pin red for weeks. Claude
never matches the shape. (`QuotaSnapshot.isLowAllowanceShape`; `LowAllowanceShapeTests`)

**Not states:** *Loading* (detected, first poll in flight) and *not detected* (no credential and
no local logs) are view-model phases with their own copy, not values of `AppState`. Adapter health
(refused polls, sign-in expired) changes the wording of a stale reading, not its state.
(`DisplayFormatter.loadingMenuBar`, `phase(for:)`; [first-run window](first-run-window.md))

The `kvotar status` command classifies the last saved poll with a cold forecast and judges
staleness by the row's age, so it never shows a rate-derived state. A row still fresh can show Bad
timing, the long-limit states or Healthy, where the app's own launch restore shows Idle.
(`Packages/KvotarCLI/Sources/KvotarCLI/StatusReader.swift`: `StatusReader.read`)

## Known gaps

| Gap | Today | Proposed |
|---|---|---|
| Low-allowance red boundary | The state goes amber at ≥ 60 % and never red short of Over quota; the dot is repainted red by `Fmt.thresholdDot`, whose 85 % boundary the private record states as `≥ 85` and the code as `> 85` | The fix belongs to [display semantics](display-semantics.md). Note `Fmt.thresholdDot` also paints every primary, weekly and per-model row dot, so `≥ 85` turns all of them red at exactly 85 %; changing only `lowAllowanceDot` would fork the one boundary its comment says must stay single |
| Unused inputs | `StateInputs.health` and `localTokensLast2Min` are carried but `classify` reads neither | Remove both, or comment them as carried for logging, with the next change to `StateInputs` |
| Stale comments | `classify`'s rank-12 and low-allowance comments still name *Weekly-elevated* and "weekly ≥ 85 %"; `testLevelWithTheCalendarIsOnPace` says the test is `used > elapsed` | Fix with the next change to either file |
| 90 % red line not re-graded | Chosen on one exhausted long limit; the later ladder replay counted three | Re-run the long-limit replay for 85 / 90 / 95 against all three before the next threshold change |
| CLI comment claims restore parity | `StatusReader`'s comment says it returns exactly the app's restore state; it judges staleness by row age instead (see above) | Fix the comment; or pass `isStale: true` if the owner wants parity |
| Limit nearly spent and staleness | A stale Limit nearly spent drops to Idle; no test covers it | Decided 1: keep it in the stale branch while its limit's reset is ahead, as for a block; keep the "as of" time; no second alert on recovery; add tests for both |

Checked against the code at 00ed0b1 + STEP_273
