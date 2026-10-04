---
summary: The display rules every surface shares — percent left versus used on each surface, rounding, what each colour means, the wording for unknown, missing and stale values, time and reset wording, the no-polling-words copy rule, and where each kind of string is built.
read_when: Changing how a quota percentage, colour, placeholder, clock, countdown or freshness stamp is shown anywhere — Fmt, DisplayFormatter, StatusDot, Theme, ExplanationRegistry.bridgeLine, HistoryDisplay, UserNotificationPresenter copy, CLIFormat — or adding any user-visible string that could mention polling (UserCopyRules).
---

# Display semantics

## Questions for owner

None.

## Decided

The maintainer ruled on these on 2026-10-04 (STEP_247). The code does not follow them yet; each
has a row in *Known gaps* below, which a later build step closes.

1. **Every human-facing time follows the Mac's 12/24-hour setting** — popover, hover cards,
   History, notifications and the CLI's text output: `21:47` for a 24-hour user, `9:47 PM` for a
   12-hour user. Machine-readable output (for example CLI JSON) keeps one fixed format. Reason:
   people read times the way their Mac shows them everywhere else. Today four clock forms ship,
   mostly a fixed 12-hour `9:47 pm`.
2. **A source tag never names the transport.** Codex's tag reads `Source: Codex account`, like
   Claude's `Source: Claude account`. Reason: how Kvotar fetched a number is an internal detail;
   it stays in the log and diagnostics. Today Codex's tag names the endpoint or the RPC.
3. **`<1% left` while a positive fraction below 1 % remains;** `0% left` only when usage reaches
   100 %. Reason: `1%` overstates what is left and `0%` says it is gone while work still runs.
   Five-hour and weekly figures arrive as whole percents, so this mostly affects monthly meters.
   Today plain rounding shows `0%` above 99.5 % used.

## About this page

This page is the specification for the display rules all surfaces share: the menu bar, the
popover, hover cards, notifications, the History window and the CLI. It replaces the private UI
Spec Part 1 §0 (display semantics, both tools), the cross-cutting display parts of Part 2 §0, the
display rules in Baseline §14 and §15, and the REV-77 record (percent left). Change this page in
the same commit as the code it describes.

What a reading, a window or a stale reading *means* is in [quota readings](quota-readings.md).
Which state and severity apply is in [state](state.md). How often Kvotar asks is in
[polling](polling.md). This page only says how those facts are *shown*. Layout belongs to pages
not written yet: the menu bar's modes and string grammar to `menu-bar.md`, the popover's sections
and rows to `popover.md`, and hover-card content to `explanations.md`.

## One convention: the number says what is left

Every displayed quota **level** is **percent left**: `100 − utilization`, floored at 0, rounded to a
whole percent. Utilization (the used percent) is defined in [quota readings](quota-readings.md). One convention for both tools, with no setting to flip it.
(`Packages/KvotarUI/Sources/KvotarUI/Model/DisplayFormatter.swift`: `Fmt.remaining`,
`Fmt.percentLeft`)

- **Only the last step subtracts.** `Fmt.remaining` is the one place the screen turns utilization
  into what is left. Everything that *reads* a quota — the state engine, the forecast, the pace
  test, the row colour thresholds — keeps the raw utilization.
- **The word sits beside the number, not inside it.** The hero's caption says what the number is
  (`5-hour quota left`, `Weekly quota left`, `Monthly spend limit left`), and the number itself is
  bare, equal to the menu bar digit for digit. A per-model warning reads `⚠ <model> · 42% left`.
  `OTHER LIMITS` rows show a bare percent under the limit's name (`Weekly` · `70% · on pace`);
  nothing on those rows says "left" (see Known gaps).
  (`Packages/KvotarUI/Sources/KvotarUI/Model/DisplayFormatter+LimitSelection.swift`:
  `limitCaption`, `otherLimitRow`, the model-warning headline)
- **Bars drain.** The hero bar's fill is what is left, so the number and the bar say one thing. At
  or past 100 % used the bar is empty and the number reads `0%`; the state colour (red) carries
  "over". There is no overflow stripe. (`DisplayFormatter.header`: `progress`)
- **A used figure appears only where the string itself says *used*** — the bridge line, pace
  statements, anatomy threshold rows, the History chart and one notification average. The table
  lists every case.

Why: "how much is left?" is the question the menu bar exists to answer without arithmetic. A number
falling toward zero reads as a fuel gauge. OpenAI's own menu already reads remaining, so a used
figure there disagreed with it. Claude's own surfaces say used, so the bridge line keeps that figure
one hover away. (D-97)

### By surface

| Surface | Orientation | Example | Code |
|---|---|---|---|
| Menu bar string | Left, bare number | `CL 42% ↻1h52m`, `CL ⚠wk 9%` | `DisplayFormatter.toolMenuBar` |
| Popover hero and bar | Left; bar drains | `42%` | `DisplayFormatter.header` |
| Popover hero caption | Says `left` | `5-hour quota left` | `limitCaption` |
| `OTHER LIMITS` rows | Left, bare number, optional tier word | `70% · on pace` | `otherLimitRow` |
| Per-model warning | Left | `⚠ <model> · 42% left` | `DisplayFormatter+LimitSelection.swift` |
| Popover hints and long-limit strips that state a level | Left | `13% left · resets at 4:10 pm.` | `DisplayFormatter.recommendation`, `DisplayFormatter+LimitSelection.swift` |
| Pace statements (verdict, anatomy) | Used against time gone | `Above pace — 87% used`, `87% used at 64% of the window` | `headerVerdict`; `DisplayFormatter+Anatomy.swift` |
| Anatomy threshold rows | Used against a used-based line | `Weekly used 91%` | `DisplayFormatter+Anatomy.swift` |
| Hover-card bridge line | Left, then used (uncapped) | *`0% left · 106% used`* | `ExplanationRegistry.bridgeLine` |
| Monthly money or credits amount | Spend, as an amount of a limit | `$69.16 of $120.00` | `DisplayFormatter.usedOfLimitText` (verdict detail), `otherLimitRow` (row detail) |
| Notifications | Left | `13% left · runs out in ~11 min at this pace.` | `App/UserNotificationPresenter.swift`: `coreBody`, `nearlySpentBody`, `aheadOfPaceBody` |
| Weekly ahead-of-pace notification average | Used per day, named | `this week has averaged 15% a day` | `aheadOfPaceBody` |
| "Since you last looked" line | Movement, named | `13% burned`, `2% returned` | `DeltaLine.deltaToken` |
| History quota chart and window rows | Used; 100 % at the top | `Ended at 87% used` | `HistoryDisplay+Quota.swift` |
| History critical observations | Left | `At risk · 3:34 pm` → `8% left` | `HistoryDisplay.observationRow` |
| CLI `status`, human column | Left, bare number | `CL  Healthy      42%  resets in 1h52m · 12s ago` | `Packages/KvotarCLI/Sources/KvotarCLI/Status.swift` |
| CLI `status --json` | Used, as `utilization_pct` | — | same; a machine contract, unchanged |

The test to apply to a new percentage: **is it a gauge or an event?** A level the user reads as
"how much do I have" reads left. A rate, a change, a share, a pace comparison or a record of
consumption keeps its own word and says which it is.

**The History exception.** The quota chart shows consumption ending at a limit, so its axis and
copy read `% used` and every value is labelled. No chart mixes the two, and History never prints an
unlabelled percentage. (`HistoryDisplay+Quota.swift`, type comment; `HistoryExperience.swift`)

Tests: `ExplanationRegistryTests.testBridgeLineReadsLeftThenUsed`,
`UserNotificationPresenterTests.testNoBodyContainsPercentUsed` and the `…SaysLeft` /
`…SaysZeroLeft` tests, `StatusRenderTests.testHumanColumnPrintsRemaining`,
`DisplayFormatterOtherLimitsTests.testNearlySpentWeeklyKeepsTheFiveHourHeroAndTakesAStrip` (caption,
bare row value).

## Rounding and number forms

| Value | Form | Rule | Code |
|---|---|---|---|
| Any displayed percent | `42%` | Nearest whole number; `.5` rounds away from zero | `Fmt.percentNumber`, `Fmt.percent` |
| Percent left | `0%` at or past 100 % used; `<1%` while a fraction below 1 remains (Decided 3; today rounding gives `0%` above 99.5 % used) | Never negative | `Fmt.remaining` |
| An estimated share | `≈12% (est.)`; `<1% (est.)` when it rounds to zero | The `Not seen locally` header fact | `DisplayFormatter+LimitSelection.swift` |
| Money the provider reports | `$69.16`, `€69.16`, `69.16 CHF` | Provider currency, never converted; symbol only for USD, EUR, GBP, JPY | `Fmt.money` |
| Estimated token value | `$12.00` | Always USD (Kvotar's own estimate from a USD price list) | `Fmt.dollarValue` |
| Credits | `1,250` | Whole credits, grouped | `Fmt.credits` |
| Token counts | `900k`, `1.2M`, `2.50B` | Compact | `Fmt.tokens` |

**One rounding for one figure.** A row and the card that explains it, and a notification and the
popover, must print the same figure the same way, so they all call `Fmt.percent` /
`Fmt.percentNumber`. Notifications break this today (see Known gaps).

Digits are tabular (monospaced) wherever numbers sit in rows or the menu bar, so the width does not
jump as values change.

## Colours

Colour is a mapping from the state and from a few display-only rules. It is never a second state
machine: which state applies is decided in [state](state.md).
(`DisplayFormatter.dot(for:)`; `Packages/KvotarUI/Sources/KvotarUI/Model/StatusDot.swift`)

| Dot | Means | Where it comes from | Spoken as |
|---|---|---|---|
| Green | Calm | Healthy | "healthy" |
| Amber | Needs attention | Elevated, limit ahead of pace, fast burn spike, usage elsewhere, multi-surface | "needs attention" |
| Red | Critical | At risk, bad timing, over quota, spend control, limit nearly spent | "critical" |
| Blue (`neutral`) | No active window — informative, not an error | Null window | "no active window" |
| Grey | Unknown | Loading, idle or fallback, and stale readings (below) | "unknown" |

- **Neutral is not grey.** A null window is a known, calm fact. Grey is kept for "Kvotar does not
  know right now".
- **A stale status dot greys out, except a block.** On a stale reading (see
  [quota readings](quota-readings.md)) the menu-bar dot and the tab dot are grey, because a colour
  would claim a current status. A [hard block](state.md) keeps its red while stale: quota cannot
  un-spend itself. (`DisplayFormatter.staleMenuBar`; the limit status is withheld as `unknown`,
  `AccountLimitSelectionTests.testStaleWithholdsStatusExceptTheKnownBlock`)
- **Row value colours do not grey while stale.** A row's colour comes from its last used percent,
  so a stale row at 90 % used stays red (see Known gaps).
- **Row dot thresholds** read utilization, not what is left: green below 60 % used, amber from 60 %
  to 85 % inclusive, red **above** 85 % (`Fmt.thresholdDot`). This one boundary paints every primary,
  weekly and per-model row dot and the low-allowance repaint. A weekly or monthly row takes its
  long-limit tier ([state](state.md)) instead when one is assessed and the reading is fresh
  (`tieredCue`). Test: `DisplayFormatterTests.testQuotaThresholdDots` (85 amber, 86 red).
- **Two display-only repaints.** On the low-allowance shape the menu-bar dot and the tab dot are
  repainted from the used percent by the same thresholds (`lowAllowanceRepaintPct`,
  `lowAllowanceDot`). On a monthly layout with a null window, the dot follows the monthly forecast
  (`monthlyForecastDot`). Neither runs while stale or over a hard block, and neither changes the
  state.
- **Menu bar uses system colours** (`systemGreen`, `systemOrange`, `systemRed`,
  `secondaryLabelColor`, `systemBlue`) because the bar is translucent. The popover uses its own
  reviewed light and dark palette. Same meanings in both. (`Packages/KvotarUI/Sources/KvotarUI/Views/Theme.swift`:
  `menuBarStatus`, `status`)
- **The money glyph** in the menu bar is amber when usage credits are about to be spent and red
  while they are being spent. (`Theme.money`)
- **Provider accents are not status colours.** Claude blue and Codex teal mark which tool a bar or
  tag belongs to (History, first-run window). Green, amber and red mean calm, attention and critical
  everywhere. (`Theme.accent`;
  `Packages/KvotarUI/Sources/KvotarUI/Views/History/HistoryTheme.swift`)
- **The plan badge is neutral.** It names the plan and asserts nothing about health, credits or
  freshness. (`Theme.badge`)
- **Contrast** of each tinted fill against its own hue is pinned by `ThemeContrastTests`.
- **Colour is never the only channel.** Every dot has a spoken word (`StatusDot.accessibilityStatusWord`);
  the menu-bar string is spoken with words for its glyphs (`MenuBarDisplay.swift`: `spoken`). The
  spoken string does not say "left" (see Known gaps).

## Unknown, missing and stale

The rule: **an absent input shows as absent, never as calm and never as zero.** Each placeholder has
one meaning.

| Shown | Where | Means | Code |
|---|---|---|---|
| `…` | Menu bar | Loading: no reading yet | `DisplayFormatter.loadingMenuBar` |
| `––` `est` | Menu bar | Idle or fallback: no usable account reading | `toolMenuBar` |
| `——` `est` (menu bar), `——` (hero) | Menu bar, popover hero | No percent to show: a null window, a retracted not-started claim, or a stale reading whose window has ended ([quota readings](quota-readings.md)) | `toolMenuBar`, `staleMenuBar`, `header` |
| `—` | Popover rows, facts and verdict lines | This value is missing | `otherLimitRow`, `headerVerdict` |
| `No active session` / `No active window` | Popover verdict (Claude / Codex) | The provider says no window is open | `headerVerdict` |
| `Reconnecting…` | Popover verdict, grey | Kvotar cannot read the account right now | `headerVerdict` |
| `Claude sign-in expired — open Claude Code to reconnect.` | Popover verdict, grey | The Claude sign-in has lapsed; waiting will not fix it | `headerVerdict` |
| `Measuring…` | Popover verdict | The burn cannot be measured yet, so nothing is claimed about pace | `headerVerdict` |
| `––`, `—`, `no data yet`, `no active window`, `no window open` | CLI human column | No percent; no reset; never read; no window; window not started | `CLIFormat.percent`, `CLIFormat.detail` |
| `Unknown` | History stat | A fact that was not recorded (no timed block) | `HistoryDisplay+Experience.swift` |

`Reconnecting…` is the honest name for a frozen reading. It never says why (no "rate limited", no
"retrying"); see the copy rule below.

### Fresh and stale

When a reading counts as fresh or stale (the 600-second limit) is defined in
[quota readings](quota-readings.md); the poll interval is in [polling](polling.md). The
display follows one grammar, driven by the time the source last answered:

- **Fresh:** the source tag carries an always-on age, `Source: Claude account · exact · 12s ago`
  (`12s ago`, `4m ago`, `2h ago`). The age turns amber at **240 seconds** — two base poll
  intervals, one missed poll. (`DisplayFormatter.sourceTag`, `freshnessTag`; `Fmt.relativeAge`;
  `PollBackoffPolicy.freshnessAmberAge`)
- **Stale:** the tag drops `exact` and the age and reads `· as of 11:32 pm`, dated
  (`· as of Jul 5, 11:32 pm`) when not from today. The last known values stay on screen; the
  popover is not wiped. (`DisplayFormatter.asOfStamp`)
- **A stale menu bar** keeps the last percent, greys the dot and drops the time slot, because a
  cached countdown would lie. A stale monthly reading keeps its `↻Nd` slot (a calendar date does
  not age). A stale block keeps red, the percent and which limit blocked.
  (`DisplayFormatter.staleMenuBar`)
- **An ended window never shows a countdown.** A reading whose reset has passed is shown as a null
  window. Display and state engine share one rule for this, so they cannot disagree.
  (`DisplayFormatter.degradeExpiredWindows` → `QuotaSnapshot.degradingExpiredWindows`)

Tests: `AppViewModelTests.testFreshnessStampAgesAndTurnsAmber`,
`DisplayFormatterTests.testStaleRenderKeepsContentWithAsOfTag`,
`DisplayFormatterTests.testStaleRenderDatesTagWhenNotFromToday`,
`DisplayFormatterTests.testRateLimitedFreezeRendersReconnectingOverIdleDashesWithCachedData`,
`DisplayFormatterMonthlyTests.testMonthlyStaleMenuBarE10`.

## Time and reset wording

| Kind | Form | Rule | Code |
|---|---|---|---|
| Clock | `9:47 pm` today | Ruled: the Mac's 12/24-hour setting (Decided 1). Today 12-hour, lowercase am/pm, fixed locale | `Fmt.clock` |
| Clock tomorrow | `12:41 am tomorrow` | Any future clock that is not today and under 48 hours away (see Known gaps) | `Fmt.clockDay` |
| Past clock | `3:12 pm`, `yesterday 11:40 pm`, `Aug 14, 11:40 pm` | Stand-alone stamp | `Fmt.clockDayPast` |
| Date | `Jun 12` | A reset two days or more away | `Fmt.monthDay` |
| Monthly reset instant | `Aug 1, 02:00` | 24-hour, because it is a month boundary, not an appointment | `Fmt.monthDayTime` |
| Countdown | `1h52m` (menu bar), `1h 52m` (popover), `43m` | Below 48 hours | `Fmt.countdown` |
| Long countdown | `30d` (compact), `30 days` (spelled out) | From 48 hours, whole days **rounded up** | `Fmt.daysUntil`, `Fmt.daysLong` |
| Runway | `~1h38m`, `~3 days` | Same day band; the caller adds `~` exactly once | `Fmt.durationHM`, `Fmt.runwayLong` |
| Measured past span | `7m`, `3h 25m`, `7d` | Rounded, for how long a block lasted | `Fmt.span` |

- **The unit follows the distance, not the tool.** Under 48 hours a countdown is hours and minutes;
  from 48 hours it is days. The boundary is 48 rather than 24 because `1d` could mean 24 to 47
  hours. Days round **up** because a countdown must never promise relief sooner than it arrives.
  `Fmt.daysUntil` owns the band; the exceptions are listed in Known gaps. (D-59; tests
  `DisplayFormatterWindowGrainTests.testCountdownGainsADayUnit`, `testDayCountdownRoundsUp`)
- **Reset, not "back".** Notification copy says a quota *resets*, never that it is "back". Only
  the weekly notices are tested for this
  (`UserNotificationPresenterTests.testTheLadderCopyPassesTheStandingSweeps`).
- **Window names come from the width,** not the tool or the slot. The naming rule is in
  [quota readings](quota-readings.md#limits-and-windows); `DisplayFormatter.windowGrain` renders it.

## Voice

Two tiers. **Advice** — verdict lines, notifications, hints and hover cards — may say "you" and give
an imperative ("slow down"). **Data** — rows, the menu-bar string, the detail line, source tags —
is impersonal: nouns and values. Copy never says "we". (UI Spec D-27, D-87; the "never we" half is
tested by `ExplanationRegistryTests.testNoCardSpeaksAsWe` and
`testNoLiveLineExposesPollingMechanicsOrSpeaksAsWe`)

## The copy rule: no polling words

Users never see how Kvotar polls: no cadence, throttling, back-off, retries, rate limits or
endpoints. The reason is in [decision 0003](../decisions/0003-polling-and-rate-limits.md); the rule
itself is word for word in `AGENTS.md`.

The banned words are one list, matched case-insensitively from a word start (so `poll` catches
`polling`, not `apollo`; `429` must stand alone):
(`Packages/KvotarCore/Sources/KvotarCore/UserCopyRules.swift`: `UserCopyRules.pollingWords`,
`pollingWord(in:)`)

`poll`, `cadence`, `throttl`, `backoff`, `back off`, `backing off`, `rate limit`, `rate-limit`,
`endpoint`, `next in`, `retry`, `429`

Tests that read the list: `ExplanationRegistryTests.testNoCardExposesPollingMechanics`,
`ExplanationRegistryTests.testNoLiveLineExposesPollingMechanicsOrSpeaksAsWe`,
`UserNotificationPresenterTests.testTheLadderCopyPassesTheStandingSweeps`,
`UserNotificationPresenterTests.testTheHiddenItemNoticeSaysMayBeHidden`. Changing the rule or the
list needs the maintainer's agreement.

## Where strings are built

Views draw; they do not format. Every user-visible quota string comes from one of these builders,
so two surfaces showing one fact call one function.

| Builder | Builds | File |
|---|---|---|
| `Fmt` | Every number, percent, money, clock and duration form | `Packages/KvotarUI/Sources/KvotarUI/Model/DisplayFormatter.swift` |
| `DisplayFormatter` | Menu-bar strings, popover header, verdicts, rows, source tags | `DisplayFormatter.swift` and its `+…` extensions |
| `ExplanationRegistry` | Hover-card text and the bridge line | `Packages/KvotarUI/Sources/KvotarUI/Model/ExplanationRegistry.swift` |
| `HistoryDisplay` | History window copy | `Model/HistoryDisplay*.swift` |
| `UserNotificationPresenter` | Notification titles and bodies | `App/UserNotificationPresenter.swift` |
| `CLIFormat` | The CLI `status` line | `Packages/KvotarCLI/Sources/KvotarCLI/CLIFormat.swift` |

`Fmt` is internal to `KvotarUI` except `percent`, `daysLong`, `monthDay` and `money`, which the
notification presenter uses so an alert and the popover round and name a figure the same way. The
CLI cannot depend on `KvotarUI`, so `CLIFormat` restates a small slice of the grammar; it drifts
(see Known gaps).

**Cross-surface agreement.** When two surfaces must agree, they call one function rather than each
deriving the answer: the menu-bar runway and the popover verdict read one exhaustion decision
(`MenuBarExhaustionAgreementTests`), the menu-bar dot and the tab dot read one mapping
(`LongLimitSurfaceAgreementTests.testMenuBarDotMatchesTheTabDotOnEveryFixture`), and the first-run
window draws its menu-bar sample through the real `DisplayFormatter.menuBarRender`
([first-run window](first-run-window.md)).

## Rejected alternatives

- **Keep `% used` everywhere.** It keeps the one subtraction the app exists to remove, and disagrees
  with OpenAI's own menu.
- **Remove "used" entirely.** It cuts the only bridge to Claude's own surfaces, which say used.
- **Per-tool convention** (Claude used, Codex left). A user with both tabs would hold two rules for
  one number. Never mix conventions per tool.
- **A user toggle for left or used.** It doubles every string and fixture for a corner case.
- **Time as the glance number** (runway in the menu bar, percent only in the popover). Runway is often
  absent, so the fallback is a percent anyway.
- **An overflow stripe past 100 %.** A drained bar has nothing to overflow; red and the bridge line
  say "over".

## Known gaps

| Gap | Today | Proposed |
|---|---|---|
| Source tag names the transport | Codex's tag reads `Source: wham/usage` or `Source: app-server RPC` (`DisplayFormatter.sourceTag`) | Decided 2: `Source: Codex account`; keep the transport in the log |
| `0% left` before the stop | Plain rounding prints `0%` above 99.5 % used while the limit is not reached | Decided 3: `<1%` until usage reaches 100 %, in `Fmt.remaining`, with tests |
| Red row boundary: `>` or `≥` 85 | `Fmt.thresholdDot` turns red **above** 85 % used, matching the row-colour table in the record; the record for the low-allowance repaint says `≥ 85`. The one function paints every primary, weekly and per-model row dot and the low-allowance repaint | Keep `> 85` and correct the low-allowance wording. If `≥ 85` is wanted, change `thresholdDot` itself, never `lowAllowanceDot` alone, so the boundary stays single |
| `OTHER LIMITS` rows never say "left" | The row reads `Weekly` · `70%`; the hero caption carries "left" but a row has no caption | Add `left` to the row value or the section label |
| Stale rows keep their colour | `tieredCue` falls back to `thresholdDot` while stale, and the primary's cue is always `thresholdDot`, so a stale 90 %-used row stays red while the dot greys | Grey a row's colour while stale except under a hard block, or record why rows keep it |
| Notification percent truncates | `coreBody` prints `100 − Int(utilization)`; the popover rounds `100 − utilization`. At 57.6 % used the alert says `43% left`, the menu bar `42%`. Visible only on fractional inputs (monthly meters, recomputed figures) | Use `Fmt.percentLeft` in `coreBody` |
| Notification clock | `resetTime` uses the system short time style; `weekdayClock`, `Fmt.clock` and `CLIFormat.clock` use a 12-hour form | Decided 1: one formatter that follows the Mac's 12/24-hour setting on every human-facing surface; CLI JSON stays fixed |
| Unknown reset in notifications | A missing reset prints `a few min` (`resetIn`) or `Resets at reset time.` (`resetTime`): an invented or empty claim | Drop the reset clause when the reset is unknown |
| `tomorrow` on a non-adjacent day | `Fmt.clockDay` adds `tomorrow` to any future date that is not today and under 48 hours, so Monday 23:00 → Wednesday 22:00 reads `10:00 pm tomorrow` | Check for the next calendar day; otherwise use `monthDay` |
| Day slots round to nearest | `Fmt.dayScale` rounds to the nearest day; `Fmt.daysUntil` rounds up. It is used by the monthly menu-bar slot, the monthly verdict (`On pace — resets Aug 1 (16d)`) and the monthly near-cap hint, so one reset can differ by a day between surfaces | Make `dayScale` round up like `daysUntil` |
| Sub-day countdown truncates | `Fmt.countdown` and the notification `resetIn` drop the leftover seconds, so they can read up to a minute early, against the "never promise relief early" rule | Round minutes up, or record the minute as accepted |
| Bridge line rounds twice | `[left]` and `[used]` are rounded separately, so 57.5 % used reads `43% left · 58% used`. Visible only on fractional inputs | Derive one from the other when utilization is at most 100 |
| Spoken menu bar has no orientation | VoiceOver hears `Claude 42%`, not "42% left" | Add "left" to the spoken form |
| CLI drifts from `Fmt` | `CLIFormat.dayScale` switches to days at 24 h (app: 48 h) and rounds to nearest; a long primary window counts down in hours (`167h59m`); ages gain a `d` unit | Port the 48-hour day band and the round-up rule to `CLIFormat` |
| Copy rule only partly enforced | The shared list is read by the registry tests and by notification tests over the weekly notices and the hidden-item notice only. Most notification bodies (`coreBody` events, spend control), History (its own inline list in `HistoryExperienceChartTests`), popover verdicts, rows, source tags, the menu bar and the CLI are not swept | Sweep every `NotificationEventType` body with the list, point History's sweep at it, and add one sweep over `DisplayFormatter` outputs |
| Stale code comments | `UserCopyRules` says History reads the list; `Fmt.relativeAge` and `sourceTag` say the stamp turns amber at 2 minutes; `ExplanationRegistry` says the bridge line is the only place a used figure appears | Fix with the next change to each file |
| Dead builders | `DisplayFormatter.quotaRows`, `quotaRowLabel` and `windowAccountingRows` have no production caller; tests still pin `quotaRows` | Delete them and their tests with the next change to `DisplayFormatter` |
| Older design records disagree | They describe a percentage on the tab, a menu-bar gauge, an overflow stripe past 100 %, green for idle and loading, and an amber stamp at 2 minutes | Code wins; nothing to change in code |

Checked against the code at 14dd256 + STEP_247.
