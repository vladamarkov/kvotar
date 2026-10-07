---
summary: The popover frame, which the app window shares — one 340 pt view, the loading, idle, setup and welcome cards, the tabs and which tab opens, the section order, the one scroll body and its height budget, the recommendation box and its copy, the Codex notes card, the local-activity layout and strings, the History links, the palette tokens, and the glance row each open writes.
read_when: Changing PopoverView, ClaudePopoverContent, CodexPopoverContent, StatusCards (LoadingCardView, IdleCardView, FirstRunCardView), WelcomeView, PopoverViewport, PopoverHeightOverride or the popover height budget in MenuBarController and QuotaWindowController; AppViewModel's selectDefaultTab, selectTab, detectedTools, openSetup, openHistory or openProjectHistory; PopoverPhase, ClaudeDisplayState or CodexDisplayState; DisplayFormatter.recommendation or RecommendationSectionView; the Codex tier or null-window note; LocalActivitySectionView, LocalActivitySection's titles and strings; Theme or Components (SectionCard); the History footer; the popover_opens glance row.
---

# Popover

## Questions for owner

1. **Where should the Codex notes card sit?** Today it sits between the header and the
   recommendation, because both notes describe the account's own allowance. The record's order
   has the recommendation directly under the header. The maintainer keeps it where it is for now
   and will decide later: keep, or move it below the recommendation?
2. **Term: `LOCAL ACTIVITY · ESTIMATED VALUE`.** The value section's title says *estimated
   value*; [estimated value](estimated-value.md#rejected-alternatives) calls `Est. token value`
   the one label, and the Codex credits section uses it. This is one of the open term
   differences; the page describes today's code and does not settle it.
3. **Term: "Spend control" in recommendation copy.** The generic spend-control box reads
   `Spend control limit reached. …`, using the words as a condition, while
   [state](state.md#the-states) names a state *Spend control*. Also one of the open term
   differences; not settled here.

## Decided

The maintainer ruled on these on 2026-10-04. The code does not follow them yet; each has a row in
*Known gaps* below, which a later agreed issue closes.

1. **The History footer gets a label that matches what it opens.** Today it reads
   `History · last 30 days` but opens History's weekly recap, which is about completed weeks; the
   text predates the recap. Reason: a link must say where it goes.
   (`PopoverView.historyFooter`)
2. **Delete the dead builders and the tests that pin them**, beyond those already in
   [display semantics' Dead builders row](display-semantics.md#known-gaps): `offMachineLive`,
   `modelRows`, `modelTokenSum` and `totalTokens` draw nothing since the current section order shipped, and the `PillView`
   component and `SectionCard`'s `accent` have no caller. Reason: code no screen reads, pinned by
   tests, misleads the next reader about what the popover shows.

## About this page

This page is the specification for the popover's frame: what holds the content, in what order,
and how it fits the screen. The [app window](app-lifecycle.md#when-the-app-window-opens-and-closes)
draws the same view from the same view model, so every rule here holds there too. It replaces
the private Implementation Baseline §15 (Popover baseline: its section lists and the
always-show amendment, kept as history), §15.1 (Unified popover — tabbed layout) and the sizing
part of §15.2 (the approved account and local popover contract); the frame parts of the private
UI Spec's popover scope-and-appearance and readability amendments (layout, local activity,
appearance and fit), Part 1 §0.5–§0.7 (the
layout residue), §2, §2.1, §2.3, §2.5–§2.7, Part 2 §2 with its section, recommendation and
"opened from notification" subsections, and Part 3 §3 (the welcome and the setup card); and the
popover parts of the private records on the usage-credits order, the two-part local card and its
header grammar, the windowed Codex local card, and the not-started window. Change this page in
the same commit as the code it describes.

IDs such as REV-nn or STEP_nnn in code comments are private record IDs;
[REFERENCES.md](../REFERENCES.md) explains them.

**The popover is split across two pages.** The header and `OTHER LIMITS` share one value,
`AccountLimitSelection`, built once per render, so the two cannot name different limits. They
meet the rest of the popover only through two optional fields on each tool's display state,
`header` and `otherLimits`. Everything from the top of the header to the last `OTHER LIMITS` row
— which limit leads, the hero, caption and meter, the verdict lines, detail lines, header facts,
the long-limit strip, model warnings, the plan badge and email, the source tag and every
`OTHER LIMITS` row — is [account summary](account-summary.md). This page owns the frame around them.

What this page does **not** own:

| Topic | Page |
|---|---|
| The header and `OTHER LIMITS` (above) | [account summary](account-summary.md) |
| Percent left, colours (the tab dot's), unknown and stale wording, source-tag grammar, the copy rule | [Display semantics](display-semantics.md) |
| Which state each tool is in and the urgency order | [State](state.md#the-states) |
| When the app window or the popover opens, closes and which one is used | [App lifecycle](app-lifecycle.md#when-the-app-window-opens-and-closes) |
| The **Set up …** and **Open in Window** menu items, the `⋯` button | [Menu actions](menu-actions.md#the-menu-top-to-bottom) |
| The display modes that pin a tab | [menu bar](menu-bar.md) |
| The local figures (what is counted, the Today population, the shown projects) | [Local usage](local-usage.md#todays-local-report) |
| The value rows and the value note | [Estimated value](estimated-value.md#spans-and-where-each-figure-shows) |
| What the credits card and the Codex credits / spend section contain; the monthly near-cap box | [Credits and monthly limits](credits-and-monthly-limits.md) |
| The "since you last looked" line, hover cards, the verdict's anatomy | [explanations](explanations.md) |
| The History window and where a link lands | [History window](history.md) |
| Notification copy, and its **Open Kvotar** action | [notifications](notifications.md) |
| The first-run window, which opens instead of the welcome when a tool is found | [First-run window](first-run-window.md#when-it-opens) |
| The popover footer (rejected) and the Settings window (planned future work, no release target) | [Menu actions](menu-actions.md#rejected-alternatives); [product scope, Decided 1](product-scope.md#decided) |

## One view, two surfaces

- **One SwiftUI view, `PopoverView`, 340 pt wide.** The app window reads the same constant
  (`PopoverView.width`), so the two surfaces cannot disagree about the width. Reason: the app
  window exists so a user who cannot see the menu-bar item can still read the same thing, not a
  second design.
- **An opaque card.** The view paints `Theme.card` under everything, so the vibrant popover
  material never lets the desktop show through.
- **The popover hugs its content.** The hosting controller reports the content's size as its
  preferred size, so a short state is a short popover (up to the height budget below). The
  popover closes when focus leaves it (transient). (`App/AppDelegate.swift`)
- **Views draw; they do not decide.** Each tab body renders one display state
  (`ClaudeDisplayState`, `CodexDisplayState` in
  `Packages/KvotarUI/Sources/KvotarUI/Model/PopoverDisplay.swift`), built by
  `DisplayFormatter.claude` and `DisplayFormatter.codex`. Every string comes from the formatter
  ([display semantics](display-semantics.md#where-strings-are-built)).

## What fills the popover

`PopoverView` picks one of three bodies, in this order:

1. **A setup card**, when **Set up Claude Code…** or **Set up Codex…** asked for one
   (`AppViewModel.transientSetupTool`, set by `openSetup`). It shows that tool's setup card alone.
   The next ordinary open clears it, because the default-tab step clears it first. A setup open
   records no glance row and starts no freshness timer
   (`QuotaSurfaceLifecycle.willOpen`; test `testASetupCardFiresNoOpenHookAndStartsNoFreshnessTimer`).
2. **The welcome**, when neither tool is detected (`AppViewModel.bothUndetected`). It shows the
   Kvotar mark, `Welcome to Kvotar`, one sentence, and both tools' setup cards. It returns to the
   normal view as soon as either tool is detected, with no restart. Reason: a fresh install
   should open to guidance, not to an empty tab bar. (`WelcomeView`; tests
   `testBothUndetectedStillReportsWelcome`, `testDetectionRevertsBothUndetected`)
3. **The tool view:** the tab bar (when there are two tabs) above one scrolling body that holds
   the active tool's content and the History footer.

"Detected" means the tool has a credential or local session logs; a tool not yet classified
counts as detected, so a two-tool Mac keeps two tabs through startup
(`AppViewModel.detectedTools`; tests `testDetectedToolsDefaultsToBothWhileUnclassified`,
`testSingleToolMachineHasSingleDetectedTool`).

### The setup card

`FirstRunCardView`, one per tool, never shared copy between tools:

| | Claude | Codex |
|---|---|---|
| Title | `Claude Code not detected` | `Codex not detected` |
| Action | `Sign in to Claude Code once so its credentials exist, then re-check.` | `Install Codex Desktop and sign in, then re-check.` |
| What was checked | `Looked for the Keychain item “Claude Code-credentials” and session logs in ~/.claude/projects.` | `Looked for ~/.codex/auth.json and session logs in ~/.codex/sessions.` |
| Button | `Re-check` | `Re-check` |

**Re-check** polls that tool at once; why it may bypass the floor is on
[polling](polling.md#extra-polls). (`Packages/KvotarUI/Sources/KvotarUI/Views/StatusCards.swift`;
test `testApplyUndetectedRendersFirstRunPerTool`)

### Phases of a tool's content

Inside the tool view, each tab renders by its `PopoverPhase`:

| Phase | When | Shows |
|---|---|---|
| `loading` | From launch until the tool's first result | `Connecting…` with a spinner, then `Fetching account data. This takes a few seconds on first launch.` (Claude) or `Starting Codex app-server. This takes a few seconds on first launch.` (Codex) |
| `idle` | No reading at all and the state is Idle | `–– est`, then `No active session, or account data is temporarily unavailable. Local session data appears here when Claude Code is active.` (or `Codex`) |
| `content` | Any reading exists, fresh, stale or restored | The sections below |
| `firstRun` | The tool is not detected | The setup card. In practice this branch is not reached from a tab: an undetected tool has no tab, and the active tab moves off a tool that becomes undetected |

- **A stale reading stays on screen.** As long as any reading exists the phase is `content`, with
  the stale wording from [display semantics](display-semantics.md#fresh-and-stale). Only the
  no-data-at-all case is the idle card. Reason: wiping blanked the popover for hours on a run of
  refused polls ([quota readings](quota-readings.md#fresh-and-stale-readings)).
  (`DisplayFormatter.phase(for:)`; the `phase` line in `claude()` and `codex()`)
- Neither card mentions polling ([the copy rule](display-semantics.md#the-copy-rule-no-polling-words)).

## Tabs

- **One tab per detected tool, only when both are detected.** One detected tool: no tab bar, its
  content fills the popover. The bar reappears by itself when the second tool shows up.
  (`PopoverView`: `detectedTools.count > 1`; test `testDetectionAppearingRestoresTabWithoutRestart`)
- **A tab is a status dot and a name: `Claude`, `Codex`.** No percentage and no marker naming the
  tab the default rule picked. Reason: two numbers on one strip invited a comparison between
  limits that are not comparable, and the dot already carries the urgency; a marker would restate
  a choice the reader is looking at the result of. The dot's colour is the tool's status dot
  ([display semantics](display-semantics.md#colours)). (`PopoverView.tabButton`)
- **The active tab** has the card background, semibold primary text and a 2 pt neutral underline
  (`Theme.tabUnderline`). Inactive tabs sit on the chrome band in supporting text, with a hover
  fill. Selection is not a status, so the underline never uses a status hue.
- **VoiceOver** reads the name and the status word, for example `Claude — needs attention`; the
  dot itself is hidden from it.
- **A tab switch is a new look.** It releases a pinned hover card or anatomy
  (`AppViewModel.activeTab` `didSet`); what that means is [explanations](explanations.md)'s.
- **The tab bar stays outside the scroll body,** so the tabs stay visible however far the reader
  has scrolled.

## Which tab opens

Every ordinary open of the popover or the app window runs `AppViewModel.selectDefaultTab`, the
**Open Kvotar** action of a notification included. It decides in this order:

1. **One detected tool:** that tool. Checked first, so a pinned display mode cannot select a tab
   that does not exist.
2. **A single-tool display mode** (`Claude only`, `Codex only`) pins that tool's tab, over the
   pick and over urgency. The other tab can still be tapped.
3. **The remembered pick:** the tab the user last tapped in this session. Tapping the tab already
   open also records it.
4. **Urgency:** the tool whose state is more urgent in [state's](state.md#the-states) urgency
   order (`AppState.priorityRank`); on a tie, the tool with the more recent local activity; with
   no activity on either, Claude.

The pick lives in memory only: a relaunch clears it, a display-mode change clears it, and it is
dropped when its tool becomes undetected. The urgency winner is still computed while a pick
holds (`defaultTab`) and is never shown. A notification opens the default tab, not the tab of the
tool it was about (see *Never built* below).
(`AppViewModel.chooseDefaultTab`, `selectTab`, `setMenuBarDisplayMode`, `setUndetected`; tests
`testDefaultTabOpensMoreUrgentTool`, `testDefaultTabDefaultsToClaudeOnTie`,
`testDefaultTabBothLoadingDefaultsToClaude`, `testDefaultTabTieBrokenByRecentActivity`,
`testDefaultTabTieOneSidedActivityWins`, `testDefaultTabUrgencyStillBeatsActivity`,
`testRememberedPickWinsOverUrgencyButNotDefaultMarker`,
`testDisplayModeOverridesRememberedPickAndUrgency`, `testDisplayModeChangeClearsRememberedPick`,
`testSelectDefaultTabSingleCandidateWinsImmediately`, `testActiveTabMovesWhenItsToolBecomesUndetected`)

Why urgency first: the user should land on the tool that needs them. Why the pick wins once made:
a user who chose a tab should not have it taken away on the next open. The maintainer confirmed
(2026-10-04) that the pick holds for the whole session, even when the other tool is blocked or
red; the older record's "a manual switch is not kept" no longer applies.

## Section order

In the content phase each tab stacks its sections in this order, with no gaps between cards:

| # | Section | Shown | Content owned by |
|---|---|---|---|
| 0 | The "since you last looked" line | Only on the open where it passed its gate | [explanations](explanations.md) |
| 1 | Header | Always | [account summary](account-summary.md) |
| 2 | Codex notes card (Codex tab only) | On the low-allowance shape, or a null window without a monthly limit | This page, below |
| 3 | Recommendation | When the builder returns a sentence | This page, below |
| 4 | `OTHER LIMITS` | When there is any limit besides the hero | [account summary](account-summary.md) |
| 5 | `LOCAL ACTIVITY · TODAY` | Always | Layout here; figures [local usage](local-usage.md#todays-local-report) |
| 6 | `LOCAL ACTIVITY · ESTIMATED VALUE` | Always, every plan | Layout here; rows and note [estimated value](estimated-value.md#the-value-note) |
| 7 | Credits: `USAGE CREDITS` card (Claude) or `CREDITS / SPEND` (Codex) | When the reading carries a credits object (Claude), or the Codex plan is `enterprise` | [Credits and monthly limits](credits-and-monthly-limits.md#the-usage-credits-card-claude) |
| 8 | `History · last 30 days ›` footer | Always | This page, below |

(`Packages/KvotarUI/Sources/KvotarUI/Views/ClaudePopoverContent.swift`,
`Packages/KvotarUI/Sources/KvotarUI/Views/CodexPopoverContent.swift`, `PopoverView`)

- **The recommendation sits high** — under the header, or under the Codex notes card when it
  shows. Reason: in a critical state the action is the second thing seen, not the last.
- **Credits come last.** For most users credits are off, the least important fact; urgency about
  money is carried by the menu-bar glyph and the verdict, wherever the card sits.
- **Absent means not applicable, not "no data".** The header and the two local sections always
  render, with `—` for a missing value; the other sections are omitted when they have nothing to
  say. The older "always show every core section" rule no longer holds.
- **Section titles are drawn in capitals** by `SectionCard`, whatever case the source string
  uses (`Usage credits` draws as `USAGE CREDITS`). Each card has 13 pt side and 10 pt vertical
  padding and a hairline under it, so the stack reads as one card. (`Packages/KvotarUI/Sources/KvotarUI/Views/Components.swift`)
- **The hover-card context is set per tab** (which tool, the window name, the freeze reason), so
  every explainable row resolves its card for the right tool (`ExplanationContext`).

## One scroll body and the height budget

- **One scroll view.** The content and the History footer scroll together; nothing scrolls inside
  anything else. The tab bar is pinned above it. The hover-card overlay rides inside the scroll
  view, so the wheel still reaches it and a card travels with the row it explains. Reason: beside
  the scroll view, the card swallowed the wheel and the popover stopped scrolling.
- **Hug, then cap.** The body takes its natural height while it fits, and is capped at the budget
  less the tab bar's height once it does not (`PopoverViewport.bodyHeight`). Before the content
  has measured itself, or with no budget at all (previews, snapshots, tests), no frame is applied.
- **The popover's budget** is the room between the menu-bar button's bottom edge and the bottom
  of the screen's visible area (which excludes the Dock), less a 16 pt margin for the arrow and
  shadow, and never below 240 pt (`PopoverViewport.availableHeight`, `bottomMargin`,
  `minimumHeight`). It is measured from the screen actually showing the popover, before every
  open and again when the display set changes while it is up. Reason: a state taller than the
  space under the menu bar made AppKit move the whole popover instead of letting it scroll.
  (`App/MenuBarController.swift`: `measurePopoverHeightBudget`)
- **The app window's budget** is its own screen's visible height, less its title bar and the same
  margin, never below the same floor and never unbounded (`PopoverViewport.windowAvailableHeight`).
  It is measured on every open, when the display set changes and when the window moves to another
  screen. Reason: an unbounded window on a
  short display would itself be unreachable. (`App/QuotaWindowController.swift`: `measureHeightBudget`)
- **Heights are measured with a background geometry reader** writing into the view's state.
  Reason: preference values do not cross a macOS scroll view.
- **`KVOTAR_MAX_POPOVER_HEIGHT`** forces the budget for diagnostics on a tall display. It is read
  once, never stored and never shown; there is no height setting. (`App/PopoverHeightOverride.swift`)

Tests: `PopoverViewportTests` (`testAvailableHeightIsTheRoomUnderTheStatusItem`,
`testAvailableHeightNeverFallsBelowTheFloor`, `testWindowBudgetAlwaysCaps`,
`testShortContentHugs`, `testLongContentIsCappedBelowTheTabBar`,
`testNoTabBarSpendsTheWholeBudget` and the rest), `AppViewModelViewportTests`,
`PopoverCompositionSnapshots.testWriteConstrainedViewportSnapshots` (writes images only when
`KVOTAR_SNAPSHOT_DIR` is set).

## While it is open

- **Opening does not poll.** It refreshes the local daily report
  ([polling](polling.md#extra-polls)) and acknowledges the menu-bar reminders ([menu bar](menu-bar.md#acknowledgement)). (`PollCoordinator.popoverOpened`)
- **The age stamps keep moving.** Each ordinary open re-renders both tools against the current
  time, and a 30-second timer does it again while the surface stays up, so a source tag ages and
  turns amber in place ([display semantics](display-semantics.md#fresh-and-stale)).
  (`QuotaSurfaceLifecycle.freshnessInterval`, `AppViewModel.refreshFreshness`)
- **Every open starts with the explanation layer closed** (no hover card, no pinned anatomy).

## The recommendation

A short piece of advice, one to three sentences, in a tinted box with a warning triangle: red tint for `danger`, amber for
`warning`. It answers "what should I do?" in the advice voice
([display semantics](display-semantics.md#voice)). A link may follow the sentence.
(`DisplayFormatter.recommendation`; `RecommendationSectionView`)

**When it shows.** The builder checks, in order, and the first match wins:

1. **Monthly near-cap** (monthly layout, at least 90 % used, not reached). Copy and link are on
   [credits and monthly limits](credits-and-monthly-limits.md#dots-the-menu-bar-and-the-strip).
2. **Claude, credits paying** (`charging`, defined on
   [credits and monthly limits](credits-and-monthly-limits.md#money-states-claude)): whatever
   the state.
3. **The state**, in the table below. Every other state — Elevated, Limit nearly spent, Limit
   ahead of pace, Healthy, Null window, Idle — has no box. Reason: the header already says what
   those mean; a long-limit warning is said by the strip under the verdict, and a box repeating it
   would be a third copy of one fact.

| State or condition | Tool | Severity | Copy |
|---|---|---|---|
| Credits paying | Claude | warning | `Operating on usage credits. $3.20 of $20.00 used this month · still accruing. Window resets in 2h 10m.` The amounts clause falls back to the used amount alone, or to `Charges are accruing` |
| At risk | both | danger | `Finish your current task and pause new prompts. Quota resets at 4:10 pm — 58 minutes away.` |
| Bad timing | both | danger | `With 13% left and 3h 25m until reset, you risk hitting the limit before your quota refreshes.` |
| Over quota | Codex | danger | `New Codex requests are blocked until the weekly resets in 2 days.` |
| Over quota, credits used earlier, now off | Claude | danger | `Credits were used earlier this window ($3.20 of $20.00 · last observed). New requests are now blocked. Window resets in 48m.` |
| Over quota, no credits | Claude | danger | `New requests are blocked until the 5-hour window resets in 48m. Any task currently running can complete.` |
| Spend control, monthly layout | Codex | danger | `Monthly workspace limit reached. New requests are blocked until the limit resets Aug 1 — 16d away.` |
| Spend control with a monthly limit | Claude | danger | `Monthly spend limit reached — ask your workspace admin. Resets Aug 1.` |
| Spend control, otherwise | Codex (and, if reachable, Claude without a monthly limit) | danger | `Spend control limit reached. New Codex requests may be blocked until credits are replenished.` |
| Fast burn spike | Claude | warning | `2 subagents running on claude-sonnet-4-6 are driving fast usage. If unexpected, check Claude Code for a runaway tool loop.`; without both a subagent count and a model, `Usage is climbing quickly. If unexpected, check Claude Code for a runaway tool loop.` |
| Fast burn spike | Codex | warning | `Usage jumped +21% since the last check. If unexpected, check Codex for a runaway loop. At this pace the window exhausts in ~38 min.` (without a jump the first sentence reads `Usage is climbing quickly.`; the pace clause drops out when unknown) |
| Off-machine burn | Claude | warning | `Claude Code is idle on this machine. Usage may be from Claude Desktop here, claude.ai, mobile, or Claude Code on another machine.` |
| Off-machine burn | Codex | warning | `Codex is idle on all local surfaces. Usage is likely from another machine or Codex Web. 13% left · resets at 4:10 pm.` (the last sentence needs the percent and the reset) |
| Multi-surface | Codex | warning | `Desktop and CLI are both active. Desktop is the primary driver at ~0.8% / min. At this combined pace the window exhausts in ~72 min.` |

Figures above are invented. The rules behind the copy:

- **A block quotes the blocking limit's reset**, not the five-hour one, and names that limit:
  `the 5-hour window`, `the weekly`, `the monthly limit`, or `the window` for a primary that is
  not five hours wide or when no block episode names one ([state](state.md#blocks-are-episodes)).
  Reason: the five-hour reset frees nothing while a weekly holds.
- **Durations follow the distance:** below 48 hours the spaced countdown (`7h 24m`, `48m`), from
  48 hours whole days spelled out and rounded up (`3 days`). The At-risk sentence keeps
  `[N] minutes`, and a runway projection reads `~22 min` below 48 hours (`Fmt.runwayLong`). The
  two Codex monthly sentences (reached, near-cap) use the compact `16d` (`40h` under two days; `Fmt.dayScale`).
  ([display semantics](display-semantics.md#time-and-reset-wording))
- **Multi-surface names only the surfaces burning now** — a local event inside the idle gap
  [state](state.md#when-state-is-evaluated) uses — never `Unknown`, and all of them:
  two `are both active`, three or more `are all active`. The rate and pace sentences appear only
  when the primary's rate would print above `0.0` (at least 0.05 % a minute,
  `multiSurfaceMinNamedRate`). With fewer than two surfaces burning now (for example while the
  state is held), the box reads `Multiple Codex surfaces are active simultaneously.`
- **A missing input drops its clause; nothing is invented.**
- **The link is the near-cap link only:** `Manage in Claude web ↗` on Claude, `Request limit
  increase ↗` on Codex, shown when the monthly near-cap test holds.
- **[notifications](notifications.md) links here for this copy rather than restating it.**

Tests: `DisplayFormatterTests` (`testClaudeAtRiskHasRecommendation`,
`testAtRiskRecommendationWithClockTime`, `testBadTimingRecommendationFullSentence`,
`testOverQuotaCase1CreditsAccruing`, `testOverQuotaCase2LastObserved`,
`testOverQuotaCase3HardBlockCanComplete`, `testCodexOverQuotaCopy`,
`testClaudeFastBurnNamesSubagentsAndModel`, `testCodexFastBurnWithDeltaAndExhaustion`,
`testCodexOffMachineNamesPercentAndReset`, `testMultiSurfaceRecommendationNamesSurfaces`,
`testMultiSurfaceIdleDesktopIsNotNamed`, `testMultiSurfaceNeverNamesUnknown`,
`testMultiSurfaceDropsRateThatRoundsToZero`, `testMultiSurfaceThreeActiveAreAllNamed`,
`testHintCountdownBoundaryAt48Hours`, `testBlockBannerSpeaksInHoursBelow48h`,
`testBlockBannerNamesTheBlockingLimit`, `testAtRiskSpellsOutLongWindows`,
`testCodexOverQuotaSpellsOutLongWindows`, `testBadTimingUsesTheSameSpelledOutDayForm`),
`LongLimitSurfaceAgreementTests.testTheBlockHintQuotesTheBlockingLimitsReset`,
`testTheBlockBannerNamesTheWeeklyInHours`, `DisplayFormatterMonthlyTests.testMonthlyReachedPopover`.

## The Codex notes card

A plain card under the Codex header, in caption-size supporting text, holding up to two notes:

- **The tier note**, on the low-allowance shape ([state](state.md#what-is-not-inferred-from-incomplete-evidence))
  and nowhere else: `OpenAI doesn't publish this plan's Codex limit. In practice, one working
  session can use most of it.`, followed by the link `Upgrade plan ↗` to ChatGPT's pricing page.
  Reason: a percentage of a ceiling the provider will not state is unreadable without it, and a
  new user reaches a high percentage within minutes. It states an observation, not a number. It
  has no gate of its own beyond the shape, so it disappears by itself on an upgrade.
  (`CodexDisplayState.unpublishedLimitNote`, `upgradeLinkLabel`; tests
  `DisplayFormatterLowAllowanceTests.testTierNoteRendersVerbatimUnderTheHeader`,
  `testUpgradeLinkAccompaniesTheNote`, `testTierNoteAndLinkAreAbsentOffTheShape`,
  `testTierNoteAndLinkAreAbsentOnPlus`)
- **The null-window note**, when the Codex reading has no window
  ([quota readings](quota-readings.md#null-not-started-and-expired-windows)) and no monthly limit:
  `Account quota windows are null (healthy idle). Showing local token data.`
  (`DisplayFormatter.codex`; test `DisplayFormatterTests.testCodexNullWindow`)

It sits between the header and the recommendation because both notes describe the account's own
allowance, and a single-limit account draws no `OTHER LIMITS` to hang them under (Question 1).
Claude has no notes card.

## The local-activity sections

The figures, the Today population, which projects show and why the surface rows appear only on
Codex are [local usage's](local-usage.md#todays-local-report). This section owns what is drawn
and its strings. (`Packages/KvotarUI/Sources/KvotarUI/Model/LocalActivitySection.swift`,
`Packages/KvotarUI/Sources/KvotarUI/Views/Sections/LocalActivitySectionView.swift`)

**`LOCAL ACTIVITY · TODAY`**, top to bottom:

1. A status line, when there is no live summary:

   | Situation | Line |
   |---|---|
   | No report yet | `Loading local activity…` |
   | A successful read that found nothing today | `No local activity observed today` |
   | The read failed, nothing kept | `Local activity unavailable` |
   | The read failed, earlier numbers kept | `As of 9:47 pm · couldn’t refresh`, above the kept numbers |

   Reason: an empty day, a failed read and a stale read are three different facts; none is shown
   as a zero or as yesterday.
2. The summary row: the collector (`Claude Code` or `Codex`) on the left, `1.2M tokens · 3
   sessions` (Codex: `threads`) on the right.
3. Codex only, with two or more apps today: one indented row per app (`Desktop`, `CLI`,
   `IDE extension`, `Unknown app`), styled like a project's model rows.
4. With the summary: `Recent local rate` (`~2.3k tokens/min`, or `—`) and `Cache hit` (`71%`, or `—`).
5. `TOP PROJECTS · BY OBSERVED TOKENS`, then each shown project: its name (the full path in the
   tooltip), its tokens, and its model rows indented beneath (`(no project)`, `Unknown model`
   when a name is missing).
6. `N more projects ›` in action blue, when projects are hidden (see *Links to History*).
7. The source tag of the newest local event (`Source: Claude Code JSONL · 35s ago`; Codex
   `Source: Codex JSONL · originator field`).

**The recency marker** `◷` sits beside at most one project and at most one app: the one with the
newest event today. It is neutral grey, never a status colour, and VoiceOver reads it as `Most
recently observed activity`. Reason: it means observed recency, not a running process or editor
focus.

**`LOCAL ACTIVITY · ESTIMATED VALUE`** shows the `Today`, `7-day` and `30-day` rows and the value
note under them, on every plan. What the rows and the note say is
[estimated value's](estimated-value.md#spans-and-where-each-figure-shows). The title is
Question 2.

Tests: `DisplayFormatterLocalActivityTests` (`testNoReportYetIsLoading`,
`testFreshEmptyReadSaysNothingObservedNotZeroSessions`, `testUnavailableWithNothingRetained`,
`testFailedRefreshKeepsRetainedNumbersUnderADatedQualifier`,
`testPopulatedSummaryRowsMarkerAndOverflow`, `testCodexUsesThreadsAndSingularForms`,
`testOverflowLabelIsComposedAndAbsentWhenNothingIsHidden`, `testTwoAppDayNamesBothAndMarksTheMostRecent`,
`testUnknownBucketRendersAsUnknownApp`, `testClaudeRendersNoSurfaceRows`).

## Links to History

Both links close the active surface (popover or app window) before History opens.
(`App/AppDelegate.swift`: `viewModel.onOpenHistory`)

- **The footer**, `History · last 30 days` with a chevron, on the chrome band in supporting text,
  darker blue under the pointer. It opens History with no destination, which today is the weekly
  recap (`AppViewModel.openHistory`; `HistoryViewModel.prepareForOpen`). Its label is to
  change (Decided 1).
- **`N more projects ›`** opens History on this tool's local day, at the project breakdown. The day
  is the one the section's report describes, so the click and the numbers above it cannot name
  different days; with no report it is today. (`AppViewModel.openProjectHistory`)

Where each lands and what History shows there is [History window](history.md)'s.

## Palette

The popover uses its own reviewed light and dark palette; each token is a dynamic colour that
follows the Mac's appearance, with no appearance setting. What the status hues mean is
[display semantics'](display-semantics.md#colours). (`Packages/KvotarUI/Sources/KvotarUI/Views/Theme.swift`)

| Group | Tokens | Used for |
|---|---|---|
| Surfaces | `card`, `sectionFill`, `border`, `borderLight`, `hoverFill`, `rowHighlight`, `tabUnderline`, `meterTrack` | Base, chrome band (tab bar, footer), dividers, hover, the `OTHER LIMITS` row the long-limit strip is about, the active tab's underline, the meter track |
| Text | `textPrimary`, `textSecondary`, `textTertiary` | Primary, supporting, provenance |
| Status hues | `green`, `amber`, `red`, `blue`, `blueHover`, `grey` | Status text and dots; blue is action and information (links) |
| Tints | `greenBg`, `amberBg`, `redBg`, `blueBg` | Recommendation boxes and other status-tinted fills |
| Badge | `badgeText`, `badgeFill` | The neutral plan badge |

- **The chrome band takes supporting text, not tertiary.** Tertiary reads too faint on
  `sectionFill`, so the inactive tab labels and the footer use `textSecondary`.
- **Each tint is the strongest tint of its hue that still keeps that hue's text readable,** and the
  recommendation box gets its edge from a hairline in the severity hue rather than a darker fill.
- **Contrast is a test, not a review.** `ThemeContrastTests` resolves every token in both
  appearances and checks 4.5:1 for text (`testBodyTextOnThePopoverBase`,
  `testChromeBandTextIsSupportingNotTertiary`, `testEachTintCarriesItsOwnText`,
  `testTabUnderlineIsNeutralAndVisible`, `testEveryTokenResolvesDifferentlyInDarkMode` and the
  rest). Change a fill and its text together.
- The menu bar uses system colours instead; History has its own palette (`HistoryTheme`).

## The glance row

Each ordinary open, on either surface, writes one `popover_opens` row once the default tab is
chosen: the time, the tab shown, and per tool the state and the primary window's used percent as
the render showed it (after expired windows are dropped). The used percent is the primary's even
when the header names another limit, so the column keeps one meaning. A setup card writes none. A
failed write is logged and never blocks the open. The app never reads the table back; the CLI's
starter queries do. Retention is [storage's](storage.md#tables-by-purpose).
(`AppViewModel.glance`; `App/AppDelegate.swift`: `lifecycle.onOpen`; `SQLiteStore.writePopoverOpen`;
tests `AppViewModelGlanceTests`, `SQLiteStoreDiscontinuityTests`)

## Never built

- **Highlighting the section a notification was about.** The record listed, per notification, the
  sections to highlight when the popover opened from it. Nothing was built: an open carries only
  "default tab" or "setup card for a tool" (`QuotaDestination`), and a notification's open is an
  ordinary open. [notifications](notifications.md) links here for this.
- **A footer with a Settings gear, a pause switch and Quit.** Rejected
  ([menu actions](menu-actions.md#rejected-alternatives)).
- **A Settings window.** Not built yet; it remains planned future work with no release target,
  and settings available today live in the right-click menu
  ([product scope, Decided 1](product-scope.md#decided)).
- **A "window has reset, full quota available" recommendation.** Listed in the record; no state
  or copy produces it.

## Rejected alternatives

- **The inactive tab's percentage beside its dot.** Removed: two numbers on one strip compared
  limits that are not comparable.
- **An `auto` marker on the tab the default rule picked.** It restated the choice and, after a
  manual switch, sat on the other tab claiming something untrue.
- **A fixed popover height.** It left short states with a large empty area.
- **Nested scrolling** (for example a projects list that scrolls on its own). One body scrolls.
- **Releasing a hover card when its row scrolls out of view.** Dropped once the card moved inside
  the scroll body: a card glued to its row cannot be left behind.
- **An appearance picker.** The popover follows the Mac.
- **A weekly-elevated recommendation.** Retired with that state; the long-limit strip says it.
- **Always showing every core section with dashes.** A dogfooding rule (absence meant a bug); the
  current order shows a section only when it has something to say, except the header and the two
  local sections.

## Known gaps

| Gap | Today | Proposed fix |
|---|---|---|
| More dead builders and components | `quotaRows`, `quotaRowLabel` and `windowAccountingRows` are the [display semantics](display-semantics.md#known-gaps) row "Dead builders". Besides those, `offMachineLive` (pinned by `DisplayFormatterTests`), `modelRows`, `modelTokenSum` and `totalTokens` in `DisplayFormatter` have no production caller, and `PillView` and `SectionCard`'s `accent` have none either | Decided 2: delete them with the display-semantics row's builders, and the tests that pin only them, after moving any rule those tests still guard to the current builders |
| Footer label | `History · last 30 days` opens the weekly recap | Decided 1: a label that matches what it opens, in `PopoverView.historyFooter` |
| Stale code comments about the History destination | `AppViewModel.onOpenHistory` and the `App/AppDelegate.swift` wiring say a nil destination opens "Summary · All"; it opens the weekly recap | Fix with the next change to either file |
| Codex content comment | `CodexPopoverContent` says the recommendation sits directly under the header; on Codex the notes card can sit between | Fix with Question 1's answer |
| Two recommendation arms ignore staleness | The monthly near-cap box and the Claude credits-paying box are checked before the state and read the stale reading as if current; every other state-driven box goes, because a stale reading is Idle unless a block survives ([state](state.md#what-is-not-inferred-from-incomplete-evidence)) | Decide whether a stale reading may show them; if not, skip both arms while stale, with a test |
| Generic spend-control box names Codex | Claude in Spend control with no monthly limit falls through to `Spend control limit reached. New Codex requests may be blocked …`. The code comment says Claude reaches Spend control only with a monthly limit, so it may be unreachable | Give that arm a tool-neutral sentence, or assert it unreachable in a test |
| Tab-bar height survives the tab bar | The cap subtracts the last measured tab-bar height even after the bar disappears (the second tool goes undetected, or a setup card or the welcome replaces the tabs), so the body is capped that much short. Untested | Reset the measured height when the tab bar is not drawn |
| Null-window note says "null" | `Account quota windows are null (healthy idle).` puts an internal word in user copy | Reword in plain language, for example "No quota window is open right now." |
| `.info` box never produced | `RecommendationSectionView` has an info icon and `HintSeverity.info` a blue tint, but the builder returns only `danger` and `warning`. The `info` comment names null-window and credits cases that are drawn elsewhere | Keep for the credits card's sub-line (which uses it) and say so in the comment |
| Glance comment | `SQLiteStore+Discontinuities.swift` says `popover_opens` is read only by the History window; nothing in the app reads it | Fix the comment with the next change to that file |

## Code and tests

- Frame: `Packages/KvotarUI/Sources/KvotarUI/Views/PopoverView.swift` (`PopoverView`, `width`,
  `scrollingBody`, `tabBar`, `historyFooter`); `ClaudePopoverContent.swift`,
  `CodexPopoverContent.swift`; `StatusCards.swift`; `WelcomeView.swift`.
- State and tabs: `Packages/KvotarUI/Sources/KvotarUI/ViewModel/AppViewModel.swift`
  (`detectedTools`, `bothUndetected`, `transientSetupTool`, `selectDefaultTab`, `selectTab`,
  `openSetup`, `openHistory`, `openProjectHistory`, `popoverMaxHeight`, `glance`);
  `Packages/KvotarUI/Sources/KvotarUI/Model/PopoverDisplay.swift` (`PopoverPhase`, `HintSeverity`,
  `ClaudeDisplayState`, `CodexDisplayState`).
- Builders: `DisplayFormatter.claude`, `codex`, `phase(for:)`, `recommendation` in
  `Packages/KvotarUI/Sources/KvotarUI/Model/DisplayFormatter.swift`;
  `Packages/KvotarUI/Sources/KvotarUI/Model/DisplayFormatter+LocalActivity.swift`
  (`localActivitySection`).
- Sizing: `Packages/KvotarUI/Sources/KvotarUI/Model/PopoverViewport.swift`;
  `App/PopoverHeightOverride.swift`; `App/MenuBarController.swift`; `App/QuotaWindowController.swift`.
- Look: `Packages/KvotarUI/Sources/KvotarUI/Views/Theme.swift`, `Components.swift`,
  `Packages/KvotarUI/Sources/KvotarUI/Views/Sections/RecommendationSectionView.swift`,
  `LocalActivitySectionView.swift`.
- Tests: `AppViewModelTests` (default tab, detection, setup), `PopoverViewportTests`,
  `AppViewModelViewportTests`, `AppViewModelGlanceTests`, `DisplayFormatterLocalActivityTests`,
  `DisplayFormatterLowAllowanceTests`, the recommendation tests in `DisplayFormatterTests`,
  `ThemeContrastTests`, `AppTests/QuotaSurfacePresenterTests.swift`; env-gated
  `PopoverCompositionSnapshots` (`KVOTAR_SNAPSHOT_DIR`).
