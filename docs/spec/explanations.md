---
summary: The explanation layer in the popover — every hover card (element IDs, the copy table, live lines, the bridge line, the source-tag card, the two header-fact cards), the peek-and-pin gesture rules, the verdict's anatomy (which verdicts open it, its rows, comparison and flip line), and the "Since you last looked" line (snapshot, noise gate, tokens, boundary form).
read_when: Changing a hover card's text or live line (ExplanationRegistry, ExplanationElement, LiveVariant, the explainable modifier, ExplanationCardView, ExplanationCardOverlay); changing peek, pin, grace or settle timing (ExplanationTiming, AppViewModel+ExplanationLayer, handleEscape); changing the verdict anatomy (DisplayFormatter+Anatomy, VerdictAnatomy, VerdictAnatomyView, togglePinnedAnatomy); changing the "Since you last looked" line (DeltaLine, LastOpenSnapshot, AppViewModel+DeltaLine, DeltaLineView, the last_open_snapshot_<tool> setting); editing Fixtures/explanation_registry.md or ExplanationRegistryTests.
---

# Explanations

## Questions for owner

1. **`Est. token value` or `ESTIMATED VALUE`?** The E-10 card opens `**Est. token value.**`; the
   section it explains is titled `LOCAL ACTIVITY · ESTIMATED VALUE`. This is one of the open term
   questions; this page describes the code and does not settle it.

## Decided

The maintainer ruled on these on 2026-10-04. The code does not follow them yet; each has a row in
*Known gaps* below, which a later contract closes.

1. **The two header-fact cards join the copy table.** The `Quota burn` and `Not seen locally` cards
   become rows of the registry and its fixture, tested byte for byte like every other card. The
   contract that adds them decides how the dead E-05, E-07 and E-21 text is retired. Reason: two cards
   that users see are tested only by substring, while three table cells for the same elements
   never render. Today the two texts are built outside the table (`burnFactCard`,
   `notSeenLocallyFactCard`), and the table below stays a byte-for-byte copy of today's fixture.
2. **The "Since you last looked" token says `elsewhere`, not `off-machine`.** Reason: `Elsewhere` is
   the app's label and the [product scope](product-scope.md#terms-a-newcomer-needs) term for this
   share; `off-machine` is a banned word. Today the token reads `+14% off-machine`
   (`DeltaLine.evaluate`).
3. **E-24 is reworded so "window" no longer means an editor window.** Reason: on these pages
   "window" means a quota window, and Kvotar's own window is the app window
   ([app lifecycle](app-lifecycle.md)). Today the `Most recent` card says "It doesn't mean the
   window is open"; its table row below is today's text.

## About this page

This page is the specification for the popover's explanation layer: the hover cards, the
verdict's anatomy and the "Since you last looked" line. It replaces the private UI Spec Part 3 §5
(the explanation layer: its intro, the gesture mechanics, the hover-card registry and its rules,
the verdict anatomy, the coach marks and what was left out), Part 1 §2.8 and Part 2 §2.10 (Since
you last looked), the two explanation rows of the Part 1 §5 tuning table, and the Implementation
Baseline §15 bullets on the explanation layer and the delta line, the meaning of the §17.1
`last_open_snapshot_<tool>` setting, and the §19 anatomy fixtures. Change this page in the same
commit as the code it describes.

IDs such as REV-nn, D-nn or STEP_nnn in code comments, and in the element column of the copy table
below (kept byte for byte, see [The copy table](#the-copy-table)), are private record IDs;
[REFERENCES.md](../REFERENCES.md) explains them. The rules here stand without them.

What this page does **not** own:

| Topic | Page |
|---|---|
| Which rows, facts and lines exist in the popover, their labels, and the verdict's words | [popover](popover.md), [account summary](account-summary.md) |
| Percent left versus used, and the copy rule that bans polling words | [Display semantics](display-semantics.md) |
| What a reading, a window or a stale reading means | [Quota readings](quota-readings.md) |
| States, the long-limit tiers and the 90 % line | [State](state.md#long-limits-as-states) |
| Burn, runway, pace and the span a burn was averaged over | [Forecast](forecast.md) |
| The Elsewhere estimate and the local figures | [Local usage](local-usage.md) |
| The estimated token value, including why "would have cost" may stay in its card | [Estimated value](estimated-value.md#what-the-figure-is) |
| Usage credits and the monthly split | [Credits and monthly limits](credits-and-monthly-limits.md) |
| `explanation-snapshot.json` in the diagnostics bundle: when it is written, consent, privacy | [Diagnostics](diagnostics.md#save-diagnostics) |
| When the popover and the app window open and close, and when Esc reaches the view model | [App lifecycle](app-lifecycle.md#when-the-app-window-opens-and-closes) |
| The menu-bar display modes the delta line reads | [menu bar](menu-bar.md) |
| A window's recorded outcome and the window-fact fold, and the History window's own day card | [History window](history.md) |
| What the first-run window teaches instead | [First-run window](first-run-window.md) |

## Terms used here

| Term | Meaning |
|---|---|
| **Element** | One `ExplanationElement`, `E-01` … `E-24`. Its ID is the case's position, so new elements are appended only (`ExplanationElement.specID`) |
| **Site** | Where an element is drawn, when it is drawn more than once (`ExplanationTarget.site`), so the card hangs under the one the pointer is on |
| **Card** | What a hover shows: an optional bridge line, the concept text, an optional live line |
| **Live line** | One italic sentence filled from the current render, below the concept text |
| **Bridge line** | `*[left]% left · [used]% used*`, above the concept text on a percentage element |
| **Peek** | A card shown because the pointer rests on its element |
| **Pin** | A card kept open by a click |
| **Anatomy** | The block under the header that shows how the verdict was decided |
| **Delta line** | The "Since you last looked" band at the top of a tab |

## The gesture grammar

One grammar for the hover cards and the anatomy. Reason: the reader experiences them as one
gesture; two timings would make them disagree.

- **Rest to peek.** The pointer must rest on an element for **600 ms** before its card opens. Every
  element re-arms the full delay; there is no instant swap between neighbours. So sweeping the
  pointer down the popover opens nothing, and resting opens one card. Reason: at 350 ms with a swap,
  a pointer passing by dealt out one card per row.
  (`ExplanationTiming.peekDelay`; `AppViewModel.explanationHover`;
  `AppViewModelTests.testSweepingPastElementsOpensNothing`,
  `testSlidingOntoAnotherElementReArmsTheDelay`, `testHoverPeeksAfterTheDelayNotBefore`)
- **Grace.** A peek stays **120 ms** after the pointer leaves, long enough to cross the 6 pt gap
  into the card. On the card it stays open. It closes only when the pointer is neither on its own
  element nor on the card. (`ExplanationTiming.graceLeave`; `explanationCardHover`;
  `testPeekEndsAfterGraceUnlessThePointerIsOnTheCard`)
- **Settle.** Hover-enters within **0.5 s** of the popover opening or a tab switch are ignored.
  Reason: AppKit sends a false hover-enter while the popover window re-frames.
  (`ExplanationTiming.settle`; the anatomy has its own copy of the guard, `appearedAt` in
  `HeaderSectionView`)
- **Click to pin.** A click pins the card; a second click on the same element releases it; a click
  on another element pins that one instead. While a card is pinned, no peek opens.
  (`togglePinnedCard`; `testSecondClickReleasesAndAnotherElementReplaces`,
  `testNoPeekOpensUnderAPin`)
- **One pinned thing at a time.** Pinning a card releases a pinned anatomy, and pinning the anatomy
  releases a card. (`togglePinnedCard`, `togglePinnedAnatomy`;
  `testPinReleasesAnatomyAndAnatomyReleasesPin`)
- **Releasing a pin.** A click anywhere else (a clear scrim catches it), Esc, a tab switch, and
  every popover or app-window open and close. Esc releases a pinned card first, then a pinned
  anatomy; with nothing pinned it is passed through, so the popover's own Esc-to-close still
  works. The app window never closes on Esc ([app lifecycle](app-lifecycle.md#when-the-app-window-opens-and-closes)).
  (`AppViewModel.handleEscape`, `releaseExplanationLayer`, `QuotaSurfaceLifecycle.didOpen` /
  `didClose`; `testEscapeReleasesTheCardFirstThenTheAnatomy`, `testEscapeConsumesOnlyWhenPinned`,
  `testReleaseIsTheCloseHookAndTabSwitchReleases`)
- **Nothing persists.** Every open starts with no card and no anatomy.
- **Where a card sits.** Inside the popover's own bounds, full width less 13 pt on each side,
  **6 pt below** its element, or above it when below would run past the end of the content. The side is chosen
  once per peek or pin, so a live line growing on a poll never flips the card under the pointer.
  The card is drawn inside the scrolling content, so it scrolls with its row and never blocks the
  scroll wheel. The popover never changes size or position. (`ExplanationCardOverlay`)
- **The hover tell.** Nothing at rest. On hover, a row's label brightens and takes a dotted
  underline; a state-coloured value takes only the underline; the header hero number shows no
  tell. The verdict's line 1 takes a solid underline in its own colour, and a blue wash while its
  anatomy is pinned. (`explanationLabelTell`, `explanationValueTell`, `HeaderSectionView.verdictLine1`)
- **Chrome.** 8 pt radius, card background, border, soft shadow; the anatomy uses the same chrome.
  A pinned card or anatomy shows `PINNED · ESC` at its top right. (`hoverCardChrome`)
- **Reduce Motion:** no fade; cards appear and disappear at once.
- **Outside the popover nothing is explainable.** An element is a hover target only inside an
  `ExplanationContext`, which the Claude and Codex tabs set. The History window reuses the card view
  and the peek and grace constants for its own day card, whose text and swap rule are History's.
  (`ExplanationContext`; `HistoryViewModel`)

| Constant | Value | Code |
|---|---|---|
| Peek delay | 600 ms | `ExplanationTiming.peekDelay` |
| Grace after leaving | 120 ms | `ExplanationTiming.graceLeave` |
| Settle after open or tab switch | 0.5 s | `ExplanationTiming.settle` |

## Hover cards

### What a card shows

A card is up to three parts, top to bottom (`ExplanationCardView`):

1. **The bridge line**, only on an element that shows a quota percentage
   ([below](#the-bridge-line)).
2. **The concept text**, fixed per element and tool. It never changes with state.
3. **One live line**, filled from the current render. It is italic, secondary colour.

Rules for a live line (`ExplanationRegistry.liveLine`):

- **One missing value drops the whole line, without trace** — never a placeholder, never a dash.
  The card then shows its concept text alone. Reason: a half-filled sentence makes a claim the app
  cannot back. (`testLiveLineDropsOnAnyMissingValue`)
- **A tool with no template has no line** (`—` in the table). (`testLiveLineDropsAsNoTemplateOnADashCell`)
- **The registry owns the words, the formatter owns the values.** `DisplayFormatter` supplies
  `[name]` values and never assembles prose. The placeholder list is closed and tested
  (`testPlaceholderVocabularyIsClosed`). Debug builds assert that no `[name]` and no doubled `%%`
  survives a fill.
- **Why a line dropped** (`LiveDropReason`) is for diagnostics only; the view never reads it.
- **Codex grain words.** Codex's E-01 `[Width]` and E-02 / E-14 `[grain]` take the tab's window
  name (`5-hour`, `Weekly`, `Monthly`, or a literal width such as `14-day`); with no reported or
  nameable width they read `5-hour`. One
  substitution fills both spellings, so a cell is never half filled.
  (`testCodexPrimaryWindowFillsTheWidthPlaceholder`,
  `testCodexSecondaryAndWeeklyResetFillTheGrainPlaceholder`)

Rules for the words, kept from the record and tested where a test can:

- **Cards explain a concept, never a label.** If a label needs a card to be understood, fix the
  label.
- **A derived value names its inputs in words**, never as a formula.
- **One column per tool.** Identical text is allowed where the concept is identical.
- **At most 45 words**, concept and live line together. (`testEveryBodyIsAtMost45Words`,
  `testConceptPlusLiveLineIsAtMost45Words`)
- **Advice voice:** one idea per sentence, "you" where natural, never "we"
  ([display semantics — voice](display-semantics.md#voice); `testNoCardSpeaksAsWe`).
- **No polling words**, by the shared list ([display semantics](display-semantics.md#the-copy-rule-no-polling-words);
  `testNoCardExposesPollingMechanics`, `testNoLiveLineExposesPollingMechanicsOrSpeaksAsWe`).

### Where each element is drawn

Which rows exist is the popover's and the account summary's ([popover](popover.md),
[account summary](account-summary.md)). This table says which
element each tagged place carries, and its live line.

| Element | Drawn on | Live line |
|---|---|---|
| E-01 Primary window | The hero caption (only when the primary window is the hero); the primary row in `OTHER LIMITS` | `·live` with the window's start and reset; `·notStarted` on an unanchored window, both tools. One derivation for both places (`primaryWindowLive`) |
| E-02 Weekly window | The weekly row in `OTHER LIMITS`; a weekly hero; the long-limit strip on a weekly | Row and strip: the tier line (`·aheadOfPace`, `·nearlySpent`) when the weekly has one, else which window is tighter (`·primaryTighter`, `·weeklyTighter`). A weekly hero: none |
| E-03 Reset | The hero's reset line under the verdict, when shown; the primary row's reset in `OTHER LIMITS` | — |
| E-04 Percent left | The hero number on a windowed layout | `·pace` on a window a day or wider; `·runway` on a shorter one when a runway exists. Dropped while stale and on a `——` hero |
| E-05 Burn | The `Quota burn` header fact (windowed) | Card body replaced; see [header-fact cards](#cards-built-outside-the-table) |
| E-06 Local apps | The local-app rows under `LOCAL ACTIVITY · TODAY` | — |
| E-07 Elsewhere | The `Not seen locally` header fact (windowed) | Card body replaced; the `·live` / `·none` templates are not shown (see Known gaps) |
| E-08 Verdict detail | Verdict line 2 | The whole card is one `E-08·family` row ([below](#verdict-line-2)) |
| E-09 Source tag | Every source tag | Built from what the tag shows ([below](#cards-built-outside-the-table)) |
| E-10 Est. token value | The `Today` row of `LOCAL ACTIVITY · ESTIMATED VALUE` | — |
| E-11 Cache hit | The `Cache hit` row | — |
| E-12 Usage credits | The `Usage credits` row of the credits card (Claude) | `·off`, `·on` (the wallet balance), `·orgManaged` (the organization's cap) |
| E-13 7-day and 30-day | The `7-day` and `30-day` value rows | — |
| E-14 Weekly reset | The weekly hero's reset line; the weekly row's reset in `OTHER LIMITS` | — |
| E-15 Left this month | A monthly hero; the monthly row in `OTHER LIMITS`; the strip on a monthly | The monthly tier line (`·aheadOfPace`, `·nearlySpent`) when there is one |
| E-16 Pace | The monthly meter's organization-and-pace note | — |
| E-17 Reset | The monthly row's reset in `OTHER LIMITS` | — |
| E-18, E-19, E-20 | Nothing; E-19's ID is carried by the monthly `Not seen locally` fact, with its own body | See [credits Decided 1](credits-and-monthly-limits.md#decided) |
| E-21 Spend rate | The `Quota burn` header fact on a monthly hero | Card body replaced |
| E-22 Model limit | A model row in `OTHER LIMITS`; a per-model warning box under the verdict | — |
| E-23 Today on this Mac | The `LOCAL ACTIVITY · TODAY` summary row | — |
| E-24 Most recent | The `◷` marker beside the most recent project | — |

Section titles are never explainable. A row with no element is inert. (`RowView`,
`OtherLimitsSectionView`, `LocalActivitySectionView`, `HeaderSectionView`;
`DisplayFormatter.header`, `otherLimitRow`, `otherLimitLive`, `heroLive`, `longLimitCardLive`,
`secondaryLiveVariant`; tests `DisplayFormatterTests.testHeroCarriesE15OnTheMonthlyLayoutAndE04Otherwise`,
`testBurnFactCarriesE21OnTheMonthlyLayoutAndE05Otherwise`, `testPrimaryWindowLiveIsOneValueOnTwoSurfaces`,
`testUnanchoredWindowTakesNotStartedOnBothTools`, `testSecondaryWindowLiveNamesWhicheverWindowIsTighter`,
`testHeroLivePicksItsVariantByShape`, `LongLimitSurfaceAgreementTests.testTheStripAndTheHighlightNameOneLimit`)

- **The strip and the row are two doors into one card.** The long-limit strip opens the card of
  the limit it names, with the same tier line, so the two cannot explain one limit two ways.
- **The tier line names what decided the verdict.** `·nearlySpent` names the
  [90 % line](state.md#long-limits-as-states) ("that sets the verdict whatever the pace");
  `·aheadOfPace` names how far ahead of the calendar. An on-pace limit has no line: a card that
  says "nothing is wrong" is one nobody opened for a reason.

### Verdict line 2

Line 2's card (E-08) is a whole card per verdict family, not a fixed text plus a line. Reason: the
concept changes with the verdict ("runway", "two resets", "blocked", "pace").
(`ExplanationRegistry.verdictDetailCard`; `DisplayFormatter.headerVerdict`,
`overQuotaVerdict`, `monthlyVerdict`; `DisplayFormatterTests.testVerdictDetailLiveIsWholeCardsAndNilWhenInert`,
`testOverQuotaAndCreditsCarryTheirOwnE08Cards`)

| Verdict | Card |
|---|---|
| `Safe at this pace`, `Safe, barely`, and the held row `Was on track to run out…` on a short window | `E-08·resetsFirst` |
| `Won't make it — …` | `E-08·exhaustion` |
| `Nothing burning` | `E-08·nothingBurning` |
| `Measuring…` with a reset to state | `E-08·measuring` |
| `Stopped — weekly spent…`, `Stopped — both windows spent…` | `E-08·weeklyElevated` ("Two resets") |
| Any other `Stopped — …` | `E-08·overQuota` |
| `Running on credits — …` (Claude, live) | `E-08·onCredits` |
| Monthly `On pace — …` / `At this pace, runs out…` | `E-08·monthlyOnPace` / `E-08·monthlyRunsOut` |

A line 2 that reads `—` or is removed carries no card. The long-window families (`On pace`,
`Above pace`, the long-window held row) have no line 2 and so no card.

### The copy table

Every fixed card and live-line template, as the code holds it. The rows below are byte for byte
the lines of `Packages/KvotarUI/Tests/KvotarUITests/Fixtures/explanation_registry.md`, the
fixture `ExplanationRegistryTests` checks the registry against. A row whose ID has a `·` is a live
line (the suffix names the variant) or, for E-08, a whole card. `—` means no card or no line for
that tool. `[name]` is a placeholder the formatter fills.

| ID | Element | Claude card | Codex card |
|---|---|---|---|
| **E-01** | Primary window row + D-58 caption | **5-hour window.** The clock starts with your first message, not at a fixed time, so the reset moves with when you started. Usage returns to zero at the reset. | **[Width] window.** The account sets the length. The clock starts with your first turn, not at a fixed time, so the reset moves with when you started. Usage returns to zero at the reset. |
| **E-01·live** | *live* — window known | *This one started at [start] and resets at [reset].* | *This one started at [start] and resets at [reset].* |
| **E-01·notStarted** | *live* — unanchored window *(both tools since REV-80 / D-101)* | *Not started yet — your first turn starts the clock.* | *Not started yet — your first turn starts the clock.* |
| **E-02** | Secondary window row (`Weekly left`) | **Weekly window.** A second, longer quota on top of the 5-hour one. You need room in both; the tighter one sets the verdict and the colour. | **Weekly window.** A second, longer quota on top of the [grain] one. You need room in both; the tighter one sets the verdict and the colour. |
| **E-02·primaryTighter** | *live* — the primary window drives | *Right now the 5-hour window is the tighter one — [left]% left, against [wkLeft]% on the weekly.* | *Right now the [grain] window is the tighter one — [left]% left, against [wkLeft]% on the weekly.* |
| **E-02·weeklyTighter** | *live* — weekly drives (more of the weekly spent than of the primary) | *Right now the weekly window is the tighter one — [wkLeft]% left, against [left]% on the 5-hour.* | *Right now the weekly window is the tighter one — [wkLeft]% left, against [left]% on the [grain] window.* |
| **E-02·aheadOfPace** | *live* — weekly ahead of the week *(REV-96 §3.9 — STEP_194)* | *[used]% of the week used with [elapsed]% of it gone — [diff] points ahead.* | *[used]% of the week used with [elapsed]% of it gone — [diff] points ahead.* |
| **E-02·nearlySpent** | *live* — weekly past the line *(REV-96 §3.9 — STEP_194)* | *At [used]%, past the [line]% line — that sets the verdict whatever the pace.* | *At [used]%, past the [line]% line — that sets the verdict whatever the pace.* |
| **E-03** | Primary reset row | **Reset.** When this window ends and usage goes back to zero. The time comes from the account and is exact. Using Claude doesn't push it later — after the reset, your next message simply starts a new window. | **Reset.** When this window ends and usage goes back to zero. The time comes from the account and is exact. Using Codex doesn't push it later — after the reset, your next turn simply starts a new window. |
| **E-04** | Header hero `%` (no tell; monthly layout → E-15) | **Percent left.** How much of this window's quota you still have, straight from your account. | **Percent left.** How much of this window's quota you still have, straight from your account. |
| **E-04·runway** | *live* — short window, forecast present | *About [runway] of usage left at today's speed.* | *About [runway] of usage left at today's speed.* |
| **E-04·pace** | *live* — long window | *[elapsed]% of the [period] gone — you're [pace].* | *[elapsed]% of the [period] gone — you're [pace].* |
| **E-05** | Burn card primary line | **Burn.** How fast you're using the quota, averaged over recent readings — per minute, or per hour on a long window. The account only reports whole percents, so when you're quiet it can't tell slow from stopped — it shows *Measuring…* until it can. | **Burn.** How fast you're using the quota, averaged over recent readings — per minute, or per hour on a long window. The account only reports whole percents, so when you're quiet it can't tell slow from stopped — it shows *Measuring…* until it can. |
| **E-06** | Local-app rows under `LOCAL ACTIVITY · TODAY` *(retargeted 2026-09-13, STEP_197 — was the burn card's `Local source` row, inert since D-67)* | **Local apps.** What on this Mac used the quota today. A *subagent* is a helper that Claude Code starts for part of a task; its tokens count inside Claude Code's own figure. They all share one quota. | **Local apps.** Which Codex apps on this Mac used the quota today — the desktop app, the CLI, the editor extension. An app's figure includes helper threads it started. *Unknown app* is one this Mac hasn't seen before. ◷ marks the app seen most recently. |
| **E-07** | `Elsewhere` row | **Elsewhere.** Usage that nothing Kvotar can see on this Mac explains — Claude Desktop here, claude.ai, mobile, or Claude Code on another computer. Worked out from timing, not measured. | **Elsewhere.** Usage that didn't come from this Mac — the web app, your phone, another computer. It can't be seen directly, so it's worked out by subtraction. |
| **E-07·live** | *live* — share known | *The account says [total]% used, this Mac explains ≈[local]%, so ≈[off]% came from elsewhere.* | *The account says [total]% used, this Mac explains ≈[local]%, so ≈[off]% came from elsewhere.* |
| **E-07·none** | *live* — "none this window" | *This window, everything the account shows is explained by this Mac.* | *This window, everything the account shows is explained by this Mac.* |
| **E-08·resetsFirst** | Verdict line 2 — Safe / Safe, barely / held | **Runway.** How long you can keep going at this speed before the quota runs out. *Yours: about [runway] — longer than the [countdown] to the reset, so the reset comes first.* The `~` means estimate. Reset times are exact. | **Runway.** How long you can keep going at this speed before the quota runs out. *Yours: about [runway] — longer than the [countdown] to the reset, so the reset comes first.* The `~` means estimate. Reset times are exact. |
| **E-08·exhaustion** | Verdict line 2 — Won't make it (both) | **Runway.** How long you can keep going at this speed before the quota runs out. *Yours: about [runway] — shorter than the [countdown] to the reset, so you'd stop at ~[stops].* The `~` means estimate. Reset times are exact. | **Runway.** How long you can keep going at this speed before the quota runs out. *Yours: about [runway] — shorter than the [countdown] to the reset, so you'd stop at ~[stops].* The `~` means estimate. Reset times are exact. |
| **E-08·nothingBurning** | Verdict line 2 — Nothing burning | **Runway.** How long you can keep going at this speed before the quota runs out. *Nothing is burning right now, so the reset comes first.* Reset times are exact. | **Runway.** How long you can keep going at this speed before the quota runs out. *Nothing is burning right now, so the reset comes first.* Reset times are exact. |
| **E-08·measuring** | Verdict line 2 — Measuring… | **Runway.** How long you can keep going at this speed before the quota runs out. *Not measured yet — it shows once the account's number has moved.* Reset times are exact. | **Runway.** How long you can keep going at this speed before the quota runs out. *Not measured yet — it shows once the account's number has moved.* Reset times are exact. |
| **E-08·weeklyElevated** | Verdict line 2 — Stopped, weekly blocking *(re-homed REV-96 §3.7 — STEP_194: the "Tight — weekly" row it was written for is retired with the weekly promotion, and these are exactly the words a weekly block needs)* | **Two resets.** The weekly limit is what's tight, so its reset is the one that matters — the 5-hour reset won't free anything up. *Weekly resets [wkReset]; the 5-hour window at [reset].* | **Two resets.** The weekly limit is what's tight, so its reset is the one that matters — the [grain] reset won't free anything up. *Weekly resets [wkReset]; the [grain] window at [reset].* |
| **E-08·overQuota** | Verdict line 2 — Stopped | **Blocked.** You've used 100% of this window. Nothing runs until the reset at [reset] — unless usage credits are on. | **Blocked.** You've used 100% of this window. Nothing runs until the reset at [reset]. |
| **E-08·onCredits** | Verdict line 2 — Running on credits | **On credits.** You're past 100%, so every token is now paid from your prepaid balance at API prices, until the reset at [reset]. | — |
| **E-08·monthlyOnPace** | Verdict line 2 — monthly, on pace | **Pace.** Your spend per day so far this month, against the limit. *~[pace] a day — at that rate the month ends before you reach [limit].* | **Pace.** Your credits per day so far this month, against the limit. *~[pace] a day — at that rate the month ends before you reach [limit].* |
| **E-08·monthlyRunsOut** | Verdict line 2 — monthly, runs out | **Pace.** Your spend per day so far this month, against the limit. *~[pace] a day — at that rate you'd reach [limit] about [days] before the reset.* | **Pace.** Your credits per day so far this month, against the limit. *~[pace] a day — at that rate you'd reach [limit] about [days] before the reset.* |
| **E-09** | Source tags (segments; only the shown terms render) | **exact:** straight from your account. **est.:** estimated from Claude Code's session logs on this Mac. **as of [t]:** the last good reading — nothing fresher was available. *Reconnecting…* — the account isn't answering right now. *sign-in expired* — open Claude Code to sign in again. | **exact:** straight from your account. **est.:** estimated from Codex's session logs on this Mac. **as of [t]:** the last good reading — nothing fresher was available. *Reconnecting…* — the account isn't answering right now. |
| **E-10** | `This window` / `Last window` / `Today` value row | **Est. token value.** What this work would have cost if you paid per token at the public API prices. Not a bill — it shows how much work you're getting for what you pay. | **Est. token value.** What this work would have cost if you paid per token at the public API prices. Not a bill — it shows how much work you're getting for what you pay. |
| **E-11** | `Cache hit` row | **Cache hit.** How much of the model's input today was reused from a cache instead of read fresh. Cached input is much cheaper at API prices. High is normal in long sessions. | **Cache hit.** How much of the model's input today was reused from a cache instead of read fresh. Cached input is much cheaper at API prices. High is normal in long sessions. |
| **E-12** | `Usage credits` row | **Usage credits.** Optional prepaid money that lets you keep working after you hit 100%, paying API prices until the reset. | — |
| **E-12·off** | *live* — credits off | *Yours are off — at 100%, Claude stops and waits for the reset.* | — |
| **E-12·on** | *live* — credits on | *Yours are on — past 100%, work is paid from your [balance] balance until the reset.* | — |
| **E-12·orgManaged** | *live* — credits paid by the organization (REV-102 / D-125) | *Yours are paid by your organization — past 100%, work is charged at API prices against its [limit] monthly cap.* | — |
| **E-13** | `7-day` / `30-day` rows | **7-day and 30-day.** The same estimate for the last 7 and 30 calendar days, from this Mac's session logs. Nothing to do with your quota windows, and still not a bill — good for spotting a trend. | **7-day and 30-day.** The same estimate for the last 7 and 30 calendar days, from this Mac's session logs. Nothing to do with your quota windows, and still not a bill — good for spotting a trend. |
| **E-14** | `Weekly resets` row | **Weekly reset.** When the weekly quota goes back to zero. The date comes from the account and is exact. The 5-hour window has its own, separate reset. Using Claude doesn't push this one later. | **Weekly reset.** When the weekly quota goes back to zero. The date comes from the account and is exact. The [grain] window has its own, separate reset. Using Codex doesn't push this one later. |
| **E-15** | Monthly `Used` row + the monthly-layout hero | **Left this month.** How much of your organisation's monthly limit is still there, from the account. The limit is set by your admin. It resets on the date shown. | **Left this month.** How much of your organisation's monthly credit limit is still there, from the account. Credits aren't money. It resets on the date shown. |
| **E-15·aheadOfPace** | *live* — monthly ahead of the month *(REV-96 §3.9 — STEP_194)* | *[used]% spent, [elapsed]% of the month gone — [diff] points ahead of even pace.* | *[used]% used, [elapsed]% of the month gone — [diff] points ahead of even pace.* |
| **E-15·nearlySpent** | *live* — monthly past the line *(REV-96 §3.9 — STEP_194)* | *[used]% spent, past the [line]% line — that sets the verdict whatever the pace.* | *[used]% used, past the [line]% line — that sets the verdict whatever the pace.* |
| **E-16** | Monthly `Pace` row | **Pace.** Your spend per day so far this month, and where that lands against the limit — on pace, or running out before the reset. Worked out from the account's own meter, not from local sessions. | **Pace.** Your credits per day so far this month, and where that lands against the limit — on pace, or running out before the reset. Worked out from the account's own meter, not from local sessions. |
| **E-17** | Monthly `Resets` row | **Reset.** When the monthly limit goes back to zero. The date comes from the account and is exact. Using Claude doesn't move it. | **Reset.** When the monthly limit goes back to zero. The date comes from the account and is exact. Using Codex doesn't move it. |
| **E-18** | `This machine` row | **This machine.** The part of this month's spend that happened while Claude Code was active on this Mac. The meter is exact; which bucket each step lands in is an estimate. | **This machine.** The part of this month's credits used while a Codex app was active on this Mac. The meter is exact; which bucket each step lands in is an estimate. |
| **E-19** | `Elsewhere` monthly row | **Elsewhere.** Usage that nothing Kvotar can see on this Mac explains — Claude Desktop here, claude.ai, mobile, or Claude Code on another computer. Worked out from timing, not measured. | **Elsewhere.** Credits used while no Codex app on this Mac was active — another computer, or the cloud. Worked out from timing, not measured. |
| **E-20** | `Unattributed` row | **Unattributed.** Spend that was already on the meter before Kvotar was watching this month — after an install mid-month, or a long gap. It isn't guessed into either bucket. | **Unattributed.** Credits already on the meter before Kvotar was watching this month — after an install mid-month, or a long gap. They aren't guessed into either bucket. |
| **E-21** | Burn line on the monthly layout (`~$4.10/hr` / `~14 credits/hr`) | **Spend rate.** How fast this month's limit is being used right now, averaged over the last hour, from the account's own meter. Blank until there are enough readings to average. | **Spend rate.** How fast this month's credits are being used right now, averaged over the last hour, from the account's own meter. Blank until there are enough readings to average. |
| **E-22** | Model-scoped limit row (`Fable left`; since STEP_176 also a Codex model window in `OTHER LIMITS` and a model-window hero) | **Model limit.** A weekly cap on this model alone, on top of the weekly limit above. Use it all and that model stops until the weekly reset. Everything else keeps running on whatever the weekly limit has left. | **Model limit.** A separate cap on this model alone, with its own windows. Use it all and that model stops until its reset. Everything else keeps running on the account's own limit. |
| **E-23** | `LOCAL ACTIVITY · TODAY` summary line (STEP_178) | **Today on this Mac.** Work Claude Code logged here since midnight, grouped by project. Anything else on your account — Claude Desktop, the web, another computer — isn't in it. These are grouped folders, not a list of open repositories. | **Today on this Mac.** Work the Codex apps logged here since midnight, grouped by project. Anything else on your account — the web app, your phone, another computer — isn't in it. These are grouped folders, not a list of open repositories. |
| **E-24** | The neutral clock beside a project name (STEP_178) | **Most recent.** This project has the newest logged activity today. It doesn't mean the window is open or anything is running now. | **Most recent.** This project has the newest logged activity today. It doesn't mean the window is open or anything is running now. |

**How the test reads it.** `ExplanationRegistryTests` loads the fixture from the test bundle,
keeps every line that starts `| **E-`, and splits each on ` | ` into four cells. Then:

- every fixed row is compared to `ExplanationRegistry.card` for both tools, byte for byte; E-09 is
  compared to `sourceTagGlossary`, and the three Codex grain cells to their unfilled templates
  (`testEveryClaudeCellIsByteForByte`, `testEveryCodexCellIsByteForByte`);
- there are 23 fixed rows, one per element except E-08 (`testSpecTableHasTwentyThreeFixedRowsAndTheIDsMatch`);
- every live row matches `liveTemplate`, and every template the registry answers for has a row:
  no orphan in either direction (`testLiveRowsMatchTheRegistry` — 24 rows,
  `testNoRegistryTemplateIsMissingFromTheSpec`);
- a missing or empty fixture **fails**, never skips.

`testFixtureMatchesTheUISpec` compares the fixture with the private UI Spec. It runs only where a
`.kvotar-private` marker sits at the repository root, so in this repository it skips. Today this
page is a copy of the fixture, not what the test reads (see Known gaps).

**To change a card:** edit the registry, the fixture row and this table in one commit. Rows stay one
line each, with cells separated by ` | `; a ` | ` inside a cell would break the parse.

### Cards built outside the table

**The source-tag card (E-09)** is assembled from what the tag shows right now, so it can never
explain a term that is not on screen (`ExplanationRegistry.sourceTagCard`):

- the `exact:` sentence when the tag says `· exact` or `(exact)`;
- the `est.:` sentence when it carries `est.`, naming that tool's session logs;
- the `as of [t]:` sentence when it is the stale form, `[t]` taken from the tag;
- then, only if one of those applied, the freeze sentence: `Reconnecting…` on both tools,
  `sign-in expired` on Claude only. These are exactly the two reasons the verdict already puts into
  words, so the card never says more than the verdict. (`SourceFreeze`)

A tag with none of the three terms, such as the local session-log tag, is inert, even during a
freeze. (`testSourceTagCardExactOnly`, `testSourceTagCardBurnTotalNamesBothTerms`,
`testSourceTagCardAsOfFillsTheTime`, `testSourceTagCardFreezeReasonsInTheVerdictsWords`,
`testSourceTagCardIsInertWithoutItsTerms`)

**The two header-fact cards** replace the table's E-05 / E-21 and E-07 / E-19 text whenever a fact is
shown. Each names the period the fact is about: `[period]` below is the primary window's name in lower
case (`5-hour`), or `quota period` when its width is unknown. (`ExplanationRegistry.burnFactCard`,
`notSeenLocallyFactCard`; `DisplayFormatter.headerFacts`;
`testHeaderFactCardsCarryTheActualPeriodAndApprovedLimitations`)

- `Quota burn`, windowed: "**Quota burn.** How fast the [period] quota is being used, averaged over
  recent account readings. The rate is derived from changes in the account meter. The account
  reports whole percents, so very small changes are bounded rather than shown as zero."
- `Quota burn`, monthly: "**Quota burn.** How fast the monthly limit (Codex: credit limit) is being
  used right now, averaged over recent account readings. The rate is derived from changes in the
  account meter; tiny positive rates use a less-than bound instead of rounding to zero."
- `Not seen locally`: "**Not seen locally.** Estimated account usage not explained by local activity
  logs during this [period] period. It may come from other apps on this Mac, other devices, or
  missing or delayed data. It does not necessarily mean another device was used." `period` is not
  doubled when `[period]` already ends in it; on a monthly hero the phrase is `this monthly period`.

A fact that cannot apply on this shape (the low-allowance shape, the retrospective grain) is hidden,
not dashed, so its element never opens the table's text.

### The bridge line

Every card on an element that shows a quota percentage opens with
`*[left]% left · [used]% used*`, filled from the same utilization the element was drawn from: the
hero, the `OTHER LIMITS` rows, and the per-model warning box. `[left]` floors at 0; `[used]` is
uncapped, so an over-quota card reads `0% left · 106% used`. With no utilization the line drops.
Reason: every level on screen reads left, and Claude's own pages say used; the bridge keeps that
figure one hover away. Where a used figure may appear is
[display semantics](display-semantics.md#one-convention-the-number-says-what-is-left)'.
(`ExplanationRegistry.bridgeTemplate`, `bridgeLine`; `testBridgeLineReadsLeftThenUsed`,
`testBridgeLineDropsWithoutAUtilization`, `DisplayFormatterTests.testBridgeLineSitsOnEveryPercentageRowAndNowhereElse`,
`testHeroBridgeFollowsTheHeroFigureStaleOrMonthly`)

## The verdict anatomy

Clicking or resting on verdict line 1 shows how the verdict was decided: the inputs as rows, the
comparison it made, and a flip line (what line 1 will read next, and the one nearest condition
that gets there). Reason: the verdict is a calculation, and a calculation should show its work.

- **Built by the same branch walk as the verdict, never re-derived.** `headerVerdict` gathers the
  values it decided with into `AnatomyInputs` once, and the anatomy reads only those, so the block
  can never disagree with the line above it. (`DisplayFormatter+Anatomy.swift`)
- **Advice voice** in the comparison and flip; the rows are data. In a sentence "about" carries the
  estimate and is never doubled with `~`; row values and burn thresholds keep `~`.
- **Placement.** It hangs directly under the header, over the rows below, 13 pt in from each side,
  inside the popover's bounds. The popover never grows for it. (`HeaderSectionView`)
- **Gestures** as for cards: peek after 600 ms, pin on click. A pin stays across polls with live
  values and is released when the verdict family changes, since a new family is a different
  anatomy. (`AppViewModel.togglePinnedAnatomy`; `testPinSurvivesPollsAndReleasesOnFamilyChange`,
  `testTogglePinsAndSecondClickReleases`)
- **A verdict without an anatomy is inert:** no tell, no click. (`testToggleIsInertWithoutAnAnatomy`)

### Which verdicts open it

| Verdict line 1 | Shape |
|---|---|
| `Won't make it — …` (both credits forms) | A, exhaustion |
| `Safe at this pace — …`, `Safe, barely — …` | A, resets first |
| `Was on track to run out — safe if this pace holds`, short window | A, held |
| The same held row on a window a day or wider | A, long-window held |
| `Nothing burning` | A, nothing burning |
| `On pace`, `Above pace — N% used` (a window a day or wider) | C |
| `Stopped — weekly spent…`, `Stopped — both windows spent…` | B |

Every other verdict is a condition, not a calculation, and is inert: a five-hour `Stopped`,
`Running on credits`, `Measuring…`, the monthly family, `Spend limit reached`, `Reconnecting…`,
`sign-in expired`, `No active session` / `No active window`, `—`, and the removed rows.
(`DisplayFormatterAnatomyTests.testConditionFamiliesAreInert`, `testAnatomyAbsentOnAPrimaryBlock`,
`testAnatomyBlockingWeekly`)

Shape A is absent (line 1 inert) when the burn is unmeasured, and for the exhaustion, resets-first
and held kinds also when there is no runway or no time to the reset. Shape C is absent on an
unanchored window. Reason: an anatomy with no burn row would be showing work it did not do.

### Shape A — runway against the reset

Rows (`runwayAnatomy`):

| Row | Example |
|---|---|
| `Remaining` | `13% of window` |
| `Burn (last [span])`, or `Burn` with no span | `0.32% / min`; on a window a day or wider `4.0% / hr` |
| `Runway at this burn` | `~41m → stops ~4:12 pm`, or `∞` |
| `Reset` | `6:00 pm — 1h 48m away`, or `—` |
| `Pace`, only when the pace clock has a value | `87% used at 64% of the window — over pace` / `window just started` / `under pace` |

The span is the one the shown burn was averaged over ([forecast](forecast.md#runway)). The burn
prints two decimals per minute on a shorter window and one decimal per hour on a window a day or
wider, gaining a decimal rather than printing zero for a non-zero rate. (`Fmt.burnRate2`;
`testAnatomyBurnRowReadsPerHourOnALongWindow`, `testAnatomyLongWindowBurnNeverPrintsAZeroItDoesNotMean`,
`testBurnLabelWithoutSpan`)

| Kind | Comparison | Flip |
|---|---|---|
| Exhaustion | "At this speed you run out in about [R] — before the reset, which is [countdown] away." | "Turns to *Was on track to run out — safe if this pace holds* if you slow down below ~[b]." |
| Resets first, pace firing | "At this speed you have about [R] left — the reset, [countdown] away, comes first by about [margin]." | "Turns to *Won't make it* if you speed up past ~[b]." |
| Resets first, under pace | same | "Can't turn into a warning yet — you're under pace: [used]% used with [elapsed]% of the window gone." |
| Resets first, inside the pace grace | same | "Can't turn into a warning yet — the window just started." |
| Resets first, unanchored | same | none |
| Held, short window | same | "Reads *Safe at this pace* (or *Safe, barely* under a 30-minute margin) once this pace holds a few more minutes" |
| Held, long window | the resets-first sentence, or "Nothing is burning, so the reset comes first." | "Reads *Above pace* / *On pace* once this pace holds a few more minutes" |
| Nothing burning | "Nothing is burning, so the reset comes first." | "Changes as soon as usage is measured again." |

`[b]` is the burn at which runway equals the time to the reset: what is left ÷ minutes to the
reset. From `Won't make it` the next verdict is the held row, never `Safe`, because the colour is
held for a few calm polls ([state](state.md#calming-down-the-de-escalation-hold)). The pace clock
is never the exit from `Won't make it`: used and elapsed both move linearly while the burn holds,
so they never cross. The flip line never names a poll count. (`testAnatomyBurnExit`,
`testAnatomyHeldNamesTheActualNextRow`, `testAnatomyHeldOnLongWindowNamesThePaceFamily`,
`testAnatomySafeUnderPace`, `testAnatomySafeOverPace`, `testAnatomyGraceBandNeverClaimsUnderPace`,
`testAnatomyNothingBurning`, `testCodexExhaustionAnatomyEqualsClaude`)

### Shape B — the weekly block

Opened only from a `Stopped` verdict whose blocking limit is the weekly. Reason: that is the one
time the header speaks about a limit the reader was not watching. (`weeklyAnatomy` →
`longLimitAnatomy`; `testAnatomyBlockingWeekly`)

| Row | Example |
|---|---|
| `Weekly used` | `100%` |
| `Nearly-spent line` | `90% used` ([state](state.md#thresholds): `longLimitNearlySpentPct`) |
| `Week elapsed` | `43% · day 4 of 7` |
| `Weekly resets` | `Sep 9` |
| `[grain]` (the primary window's name), when the primary window has a reading | `22% — not the driver` |

- **Comparison:** "Weekly is at [used]%, past the 90% line — that's what sets the verdict whatever
  the pace; the [grain] window at [N]% isn't the problem."
- **Flip:** "Stays until the reset on [date] — usage can't go down before then." plus, while some
  of the week is left and at least a day remains, "[N]% left is about [n]% a day."

`longLimitAnatomy` also builds a form for a limit ahead of pace but under the line (an
`Even pace would be` row, "… points ahead of even pace", "Reads *on pace* again once the calendar
catches up") and monthly labels (`Nearly-reached line`, `Month elapsed`). No verdict reaches them
today: a weekly block is always past the line, and no monthly verdict carries an anatomy.
(`testAnatomyWeeklyAheadOfPace` pins the unreached form)

### Shape C — pace on a long window

| Row | Example |
|---|---|
| `Used` | `7%` |
| `Window elapsed` | `4% (day 1 of 7)` |
| `Resets` | `Sep 9` |

- **Comparison:** "You've used [n] points more than the calendar would by now", "… less than …", or
  "Level with the calendar".
- **Flip, On pace:** "Reads *Above pace* once you've used more than the calendar — [elapsed]% today,
  rising about [100 ÷ days]% a day."
- **Flip, Above pace:** "Reads *On pace* by about [t] if you pause — the calendar catches up with
  [used]%.", where `[t]` is now plus (used − elapsed) % of the window.

(`paceAnatomy`; `testAnatomyLongWindowOnPace`, `testAnatomyLongWindowAbovePace`)

## Since you last looked

One line at the top of a tab, shown on open only when something changed that the menu bar could
not have shown. Reason: the popover is glanced at many times a day and "what changed?" is the
question, but the menu bar already answers "how much?" all the time, so a bare percentage change
would repeat it.

### The look and the snapshot

- **Displaying a tab is a look.** A snapshot is taken every time a tab is shown: each open of the
  popover or the app window (including an open from a notification), and each real tab switch. A
  tap on the tab already showing is not a look; re-snapshotting would swallow a line that just
  rendered. (`AppViewModel.selectDefaultTab`, `selectTab`, `noteTabDisplayed`;
  `AppViewModelDeltaLineTests.testTapOnTheActiveTabIsNotANewLook`)
- **Only a tab with a render takes one.** The loading card, the welcome view and an idle card keep
  the previous snapshot, so the next real look compares with the last real look.
  (`testNoRenderMeansNoSnapshotAndNoLine`)
- **One snapshot per tool**, so looking at Claude never counts as looking at Codex. It is kept in
  memory and written on every look to the `settings` key `last_open_snapshot_<tool>`
  ([storage](storage.md#the-settings-table)), so it survives a relaunch. At launch the stored row
  fills only an empty slot. A row that does not decode reads as no snapshot.
  (`LastOpenSnapshot`; `AppDelegate`; `testSeedFillsOnlyAnEmptySlot`)
- **No previous snapshot, no line.** The first look at a tab only writes.
  (`testFirstDisplayWritesSnapshotAndShowsNoLine`)

The stored JSON, keys sorted so an unchanged snapshot writes nothing new
([storage](storage.md#the-settings-table)):

| Key | Holds |
|---|---|
| `taken_at` | When the look happened, unix seconds |
| `window_resets_at` | The primary window's reset, as its identity; `null` with no window |
| `used_pct` | The primary window's used percent; `null` when unknown |
| `verdict_family` | The verdict family of the render (`VerdictFamily`), not the words; `notStarted` when the row was removed for a window not yet started |
| `burn_tier` | The `Quota burn` fact's tier word: `none`, `low`, `mid`, `high`, or `—` |
| `agent_count` | Claude: subagents seen; Codex: threads |
| `pct_visible_in_menu_bar` | Whether the menu-bar mode showed this tool's percentage (both tools shown, or this tool only) |
| `off_machine_pct` | The Elsewhere share of the window, only on a fresh render with usage; else `null`. Older rows without the key read as unknown |

(`testSnapshotJSONRoundTripAndKeys`, `DeltaLineTests.testPctVisibleInMenuBarTable`)

### When it stays silent

Two separate lists, for two reasons:

- **The whole line is silent** when the current render is stale, or its family is `unknown` (`——`),
  `reconnecting`, `signInExpired` or `idle`. Those states already own the top of the popover. The
  snapshot is still written. (`AppViewModel.silentFamilies`;
  `testStaleRenderIsSilentButStillSnapshots`)
- **A verdict-family change does not count** when either side is `nullWindow`, `unknown`,
  `reconnecting`, `signInExpired`, `idle`, `measuring` or `notStarted`. `measuring` is about
  Kvotar's own empty burn buffer after a launch, not the account; `notStarted` and `nullWindow` are
  window news the boundary form reports better. Other triggers still fire.
  (`DeltaLine.excludedFamilies`; `testVerdictFamilyChangedAndExcludedFamilies`,
  `testMeasuringCrossingIsNotNews`, `testMeasuringDoesNotMuteTheOtherTriggers`)

### Triggers and tokens

If the window identity changed, the [boundary form](#the-boundary-form) wins and every other token
except the window facts is dropped: they compare across windows and mean nothing. A reset that
moved by 60 s or less is the same window; a window appearing or disappearing is a change.
(`DeltaLine.evaluate`, `windowChanged`; `testWindowBoundaryToleranceAndPrecedence`)

Otherwise the line reads `Since [t]: [tokens joined by " · "]`, `[t]` being the look's past clock
(`3:12 pm`, `yesterday 11:40 pm`, `Aug 14, 11:40 pm`; `Fmt.clockDayPast`). Tokens in this order,
each only when its trigger fired (`testTokenOrderWithDeltaAsContext`, `testClockDayPastForms`):

| Trigger | Token |
|---|---|
| A window fact recorded since the look: a window added, removed, a new width, or an early reset | `weekly window added`, `5-hour window removed`, `weekly window now 5-day`, `weekly window reset early`, or one folded `windows now 5-hour + weekly (was weekly)`. Plan changes are skipped |
| More subagents (Claude) or threads (Codex) than at the look | `1 subagent spawned` / `N subagents spawned`; `1 thread started` / `N threads started` |
| The burn tier **rose** | `burn low → high`; the stored `none` prints as `very low` |
| The verdict family changed, excluded families on neither side | `verdict changed` |
| The Elsewhere share rose by 5 points or more | `+14% off-machine` |
| The used percent moved by at least 1 point (context) | `14% burned` / `3% returned` |

- **A falling burn tier is silent.** Burn falling is the resting state arriving, and the fact below
  already says so. `—` on either side is not a rise. (`testBurnTierRoseAndUnknownExcluded`,
  `testBurnTierFallIsSilent`, `testBurnFallDropsItsTokenAndKeepsTheRestOfTheLine`)
- **The used-percent move is context, not news.** It is added last whenever the line renders. Alone,
  it fires the line only when the menu bar was not showing this tool's percentage at the look or now
  (the other tool's single-tool mode), and only at 5 points or more. Its words name the direction
  because every level on screen reads left ([display semantics](display-semantics.md#by-surface)).
  (`DeltaLine.pctWhenUnseen`, `deltaToken`; `testDeltaAloneOnlyWhenMenuBarDidNotShowIt`)
- **Only a rise of the Elsewhere share counts**, at the same 5 points: the estimate is coarse and
  can settle downward. (`testOffMachineRiseIsATrigger`)
- **Window facts** are read from the recorded window events after the look, one local read after
  the open, and folded the way History folds them ([History window](history.md)). They lead the line because
  they explain the rest. Widths are named, never sized.
  (`DeltaLine.windowFactTokens`; `testWindowFactTokensAreFoldedAndNamedByWidth`,
  `testAWindowFactFiresTheLineAndLeadsIt`, `testWindowFactsSinceTheLastLookRenderTheLine`)

| Constant | Value | Code |
|---|---|---|
| Used-percent move that fires alone, and Elsewhere rise | 5 points | `DeltaLine.pctWhenUnseen` |
| Reset wobble that is still the same window | 60 s | `DeltaLine.resetJitterTolerance` |

### The boundary form

The previous window's outcome comes from one local read after the open ([History window](history.md#the-quota-window-outcome-fold)
owns the outcome). If the popover closes or moves on before the read returns, the result is dropped.
(`DeltaLine.boundaryLine`, `appendingFacts`; `testBoundaryLineAwaitsTheWindowOutcomeRead`)

| Case | Line |
|---|---|
| A window is open now, previous one known | `New window since [t] — last one ended at [N]%` |
| A window is open now, previous one hit the limit | `New window since [t] — last one hit the limit at [t₁]` |
| A window is open now, previous one unknown | `New window since [t]` |
| No window open now (Claude, or a five-hour Codex window) | `Last window ended at [N]% — reset [t]` |
| No window open now, other Codex widths | `New window since [t]` (the previous reset) |
| No window open now, nothing recorded | no line (or the window facts alone, if any) |

`[t]` in the first three is the **current** window's start (its reset minus its width, five hours
when the width is missing), not the previous reset: a window starts on the first request after the
reset, usually after an idle gap. `[N]` is the previous window's highest used percent. Window facts
are appended after the boundary text. A window that is not started yet keeps its family, so the
`Last window ended at` form still shows at a rollover. (`testBoundaryPopulatedEndedAtHighWater`,
`testBoundaryPopulatedHitTheLimit`, `testBoundaryPopulatedUnknownPrevious`, `testBoundaryFreshNullForms`,
`testABoundaryKeepsTheFactsAfterItsOwnCopy`, `testRolloverIntoANotStartedWindowStillRendersTheBoundaryLine`)

### The band

Row 0 of the tab, above the header: blue text, 11 pt, on a blue wash, an `✕` at the right. A click
anywhere on it hides it for this open. It never updates while open: it describes the interval
that ended when the popover opened. It disappears when the popover closes, and the next look
compares against a fresh snapshot, so it never repeats. Data voice: no "you". Each tab has its own
line. (`DeltaLineView`; `AppViewModel.dismissDeltaLine`, `popoverDidClose`;
`testDismissAndCloseClearTheLine`, `testSecondDisplayWithASubagentSpawnedRendersTheLine`)

## The diagnostics snapshot

The diagnostics bundle's `explanation-snapshot.json` records, per tab, every tagged element except E-06 (see Known gaps) as
rendered, with its live line **or the reason it was dropped**, the anatomy, and the peek and grace
timings in force. Reason: on screen a dropped line is silent, so without the reason a card that said
nothing cannot be told from one that said the wrong thing. When it is written, and its privacy rules,
are [diagnostics](diagnostics.md#save-diagnostics)'. (`AppViewModel.explanationSnapshot`;
`AppViewModelExplanationSnapshotTests.testEveryTaggedElementOnTheRenderedTabIsRecorded`,
`testADroppedLiveLineRecordsItsReason`, `testTheVerdictAnatomyTravelsOnAComputedFamily`)

## Coach marks

Three one-time callouts in the popover were built once and then removed. No code for them remains:
no view, no setting, no test. A few code comments still mention them (see Known gaps). What the
first-run window teaches is [its page](first-run-window.md)'s.

## Rejected alternatives

- **An instant swap between neighbouring cards, and a 350 ms delay.** A pointer passing by opened a
  card on every row.
- **A card in a second window, or a popover that grows for the anatomy.** A taller popover was moved
  by AppKit; everything stays inside the popover's bounds.
- **A permanent explainer strip** for first-weeks content; its content lives in the cards.
- **A provenance footer or mode;** each derived card names its inputs in words instead.
- **`.help()` tooltips, a command palette, sound.**
- **A hover card for a counterfactual per-model burn.** No measured per-model rate exists; a
  published ratio shown as the user's would be a made-up rate.
- **A bare percentage change as a first-class trigger** for the delta line; the menu bar already
  shows it. Also rejected: putting the line in the verdict's line 2 (it would hide `stops ~[t]`),
  one snapshot for the active tab only, and a falling burn tier as news.
- **A separate live line repeating `[left]% left` on the hero;** the bridge line already says it.
- **The Elsewhere subtraction line (`E-07·live`) when the shares do not reconcile.** Printing three
  numbers a reader can add up and find short is worse than the concept text alone.

## Known gaps

| Gap | Today | Proposed fix |
|---|---|---|
| The test does not read this page | `ExplanationRegistryTests` reads the fixture; this page's table is a copy, and the private drift guard skips here. The fixture header and `ExplanationRegistry`'s doc comment still say to edit the private UI Spec first | A later contract points the test at this page's table (or checks fixture against page) and rewrites the fixture header and the doc comment |
| Header-fact cards are not in the table | `burnFactCard` and `notSeenLocallyFactCard` are built outside the registry table and checked by substring only | (Decided 1) Add both to the registry and the fixture, tested byte for byte, and update this page's table in the same step |
| Dead card text outside credits Decided 1 | The E-05 `Burn`, E-07 `Elsewhere` and E-21 `Spend rate` cells never render (the facts pass their own body). E-05 still says the burn shows `Measuring…`, which it no longer does | (Decided 1) The contract that adds the header-fact cards retires these cells and their fixture rows |
| Dead live lines | `E-07·live` and `E-07·none` are produced only by `DisplayFormatter.offMachineLive`, which nothing in the app calls; tests still pin it | Delete the two rows, the function and its test, or give the `Not seen locally` card a live line |
| Dead monthly split cards | E-18, E-19 body, E-20 | [Credits Decided 1](credits-and-monthly-limits.md#decided) |
| `calendar days` in E-13 | The figures are rolling 7 × 24 and 30 × 24 hours | [Estimated value — Known gaps](estimated-value.md#known-gaps) |
| `off-machine` in the delta line | The token reads `+14% off-machine` (`DeltaLine.evaluate`), a banned word | (Decided 2) Say `elsewhere`, with its test; the same gap is on [product scope](product-scope.md#known-gaps) |
| E-24 says "window" for an editor window | "It doesn't mean the window is open" (`ExplanationRegistry`, `.projectRecency`) | (Decided 3) Reword the card, its fixture row and this page's table row in one pull request |
| Unreached anatomy forms | `longLimitAnatomy`'s ahead-of-pace form and monthly labels have no verdict that reaches them | Delete them, or give the monthly family an anatomy in its own contract |
| E-06 missing from the diagnostics snapshot | The local-app rows are tagged on screen, but the snapshot walker does not record E-06 | Add E-06 (fixed site, no app names) to `ExplanationWalk.localActivity` |
| Two spellings of organization | E-15 says `organisation's`; E-12 `·orgManaged` and the verdict copy say `organization` | Pick one with the next copy change; a fixture row change |
| `quota period quota` | With no reported window width, the windowed burn card reads "How fast the quota period quota is being used" (`headerFacts` passes `quota period` to `burnFactCard`) | Pass a word that fits both cards, or let `burnFactCard` drop the period when it is unknown |
| A weekly hero's card has no live line | A weekly hero opens E-02 with the bridge line only; its tier line rides on the strip and the row | Decide whether a weekly hero carries the tier line too |
| Anatomy peek reads the constants | The anatomy's peek uses `ExplanationTiming` directly, not the view model's test-adjustable copies, so tests cannot shrink its delay | Read the view model's values |
| Live diagnostics can open the real database | When `KVOTAR_LIVE_DB` is unset, `ExplanationLiveDiagnostics` (line 145) falls back to the live database path but copies the file and opens only the copy (line 146); `HistoryExperienceLiveDiagnostics` (line 18) falls back to the live file and opens it. Core `LiveDiagnostics` opens the live file directly in four tests (lines 31, 52, 129, 160) and falls back at lines 201 and 254; only its window-outcomes test (line 313) demands a copy. They run only with `KVOTAR_LIVE` set | Require an explicit `KVOTAR_LIVE_DB` copy in all of them, and refuse the live path, as the window-outcomes test already does |
| Stale comments | `ExplanationElement` docs cite labels `5-hour used`, `Weekly used`, `Fable used` (rows now read left); the registry test's doc says "22 elements and 21 fixed rows" while it asserts 23; coach marks are still mentioned in `MenuBarController`, `AppViewModel` (two places) and `OnboardingView`; `HistoryViewModel` says the timings are 350/120 ms (peek is 600 ms) | Fix with the next change to each file |

## Code and tests

| What | Where |
|---|---|
| Elements, the copy, live lines, bridge line, source-tag and header-fact cards | `Packages/KvotarUI/Sources/KvotarUI/Model/ExplanationRegistry.swift` |
| Timing | `Packages/KvotarUI/Sources/KvotarUI/Model/ExplanationTiming.swift` |
| Peek, pin, grace, settle, release | `Packages/KvotarUI/Sources/KvotarUI/ViewModel/AppViewModel+ExplanationLayer.swift`; pin state, `togglePinnedAnatomy`, `handleEscape`, `releaseExplanationLayer` in `AppViewModel.swift` |
| The modifier, the card, the overlay, the tell | `Packages/KvotarUI/Sources/KvotarUI/Views/ExplanationLayer.swift` |
| Tag sites | `Views/Components.swift` (`RowView`, `SourceTagView`), `Views/Sections/HeaderSectionView.swift`, `OtherLimitsSectionView.swift`, `LocalActivitySectionView.swift` |
| Live values | `DisplayFormatter.swift` (`header`, `heroLive`, `primaryWindowLive`, `headerVerdict`, `overQuotaVerdict`, the credits cards), `DisplayFormatter+LimitSelection.swift` (`otherLimitRow`, `otherLimitLive`, `headerFacts`, `longLimitCardLive`, `secondaryLiveVariant`) |
| The anatomy | `Packages/KvotarUI/Sources/KvotarUI/Model/DisplayFormatter+Anatomy.swift`; `VerdictAnatomy`, `VerdictFamily` in `Model/PopoverDisplay.swift`; `VerdictAnatomyView` in `HeaderSectionView.swift` |
| The delta line | `Packages/KvotarUI/Sources/KvotarUI/Model/DeltaLine.swift`, `ViewModel/AppViewModel+DeltaLine.swift`, `Views/DeltaLineView.swift`; seed, persist and the two reads in `App/AppDelegate.swift` |
| Esc and open/close hooks | `App/MenuBarController.swift`, `App/QuotaWindowController.swift`, `App/QuotaSurfaceLifecycle.swift` |
| Diagnostics snapshot | `ViewModel/AppViewModel+ExplanationSnapshot.swift`; `Packages/KvotarCore/Sources/KvotarCore/Diagnostics/ExplanationSnapshot.swift` |
| Tests | `ExplanationRegistryTests` and `Fixtures/explanation_registry.md`; `DisplayFormatterAnatomyTests`; `DeltaLineTests`; `AppViewModelDeltaLineTests`; `AppViewModelExplanationSnapshotTests`; the peek, pin and Esc tests in `AppViewModelTests`; live-line tests in `DisplayFormatterTests`; `LongLimitSurfaceAgreementTests`. `ExplanationLiveDiagnostics` is a live, read-only check that runs only with `KVOTAR_LIVE` set |
