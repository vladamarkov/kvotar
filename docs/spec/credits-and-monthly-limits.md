---
summary: Credits and monthly spend as a product — the Claude money states, when the money glyph arms, the usage-credits card (self-serve and organization), the prepaid wallet's rows, the Codex credits / spend section, spend control as a condition, the monthly layout's content, the monthly forecast (pace, runway and their gates), the trailing spend rate, and the monthly attribution split.
read_when: Changing MoneyState, MoneyGlyph or MoneyModel (moneyState, etaTo100Minutes, isImminent, moneyGlyphInstant); MonthlyLimit's derivations (usedPercentExact, cycleStart, pacePerDay, runwayDays); MonthlySpendRate; MonthlyAttributionEstimator or MonthlyAttribution; QuotaSnapshot.monthlyReached; the monthly and credits parts of DisplayFormatter (monthlyLayoutLimit, monthlyForecastDot, monthlyForecastGateMet, monthlyConfidenceMet, monthlyMenuBarSlot, monthlyVerdict, monthlyNearCap, monthlyBurnTier, monthlyAmount, creditsCard, orgManagedCreditsCard, codexCreditsSpend, credits* helpers, prepaidBalance) and DisplayFormatter+LimitSelection (monthlyMetaLine, orgCreditsSpentLine, the monthly candidate, the monthly strip, the monthly header facts); CreditsCardSectionView or CreditsSpendSectionView; the CLI's runway_days.
---

# Credits and monthly limits

## Questions for owner

None.

## Decided

The maintainer ruled on these on 2026-10-04 (STEP_263). The code does not follow them yet; each
has a row in *Known gaps* below, which a later agreed issue closes.

1. **The monthly split's hover cards are deleted, and its rows do not come back.** Delete the
   `This machine` and `Unattributed` cards and the unused `Elsewhere` card text (keeping the
   element id, which the `Not seen locally` fact still uses), and fix `MonthlyAttribution`'s doc
   comment. Reason: the rows went away with the retired Monthly section, and only the elsewhere
   share is shown; a card nothing can open, one titled with an internal name, is dead copy.
   Today: the three card texts are still in `ExplanationRegistry`, none renders, and the doc
   comment still describes rows on a Monthly card.

## About this page

This page is the specification for what Kvotar does with usage credits, monthly limits and spend
control once they are decoded. It replaces the product half of the private Implementation
Baseline §8.0.4 (Claude Enterprise monthly spend: the monthly layout, the glyph and copy
posture), the monthly and money parts of §11 (forecast engine) and §13 (state engine), the
money-glyph half of §13.4 (display hysteresis) with the private UI Spec §1.6 (money glyph), the
UI Spec §2.4a (Usage credits card) and Part 2 §2.4 (Credits / spend section, Enterprise), and the
product decisions of the private records on Codex Enterprise monthly limits, Claude Enterprise
monthly spend, monthly attribution on both tools, and Claude Team spend as usage credits. Change
this page in the same commit as the code it describes.

What this page does **not** own:

| Topic | Page |
|---|---|
| How `extra_usage`, `spend` and the prepaid wallet decode; the active meter, the windowed seat and the three arms; self-serve versus organization credits; the prepaid call, its Pro/Max gate and its 401/403 latch | [Claude account, money fields](claude-account.md#money-fields-decoding-only) |
| How the Codex monthly limit, spend-control flag and credits balance decode; the plan-gated monthly supplement; Decided 1–2 | [Codex account](codex-account.md#decided) |
| What a monthly limit is, its cycle end, its expiry, the spend-control flag's expiry | [Quota readings](quota-readings.md#expired) |
| The Spend control state, its rank, the long-limit tiers (incl. the monthly), the monthly layout's amber hand-off, the glyph's escalate-now / demote-later hold | [State](state.md#long-limits-as-states), [the hold](state.md#calming-down-the-de-escalation-hold) |
| Percent left, `<1%` (Decided 3), money and credit number forms, the money glyph's colours, stale wording | [Display semantics](display-semantics.md#rounding-and-number-forms) |
| Where `monthly_attrib_accum_<tool>` and the monthly columns are stored | [Storage](storage.md#the-settings-table) |
| How the money glyph and the monthly slots are drawn in the menu bar | [menu bar](menu-bar.md) |
| Where the credits card, the Codex section and the monthly rows sit in the popover | [popover](popover.md) |
| Verdict copy outside the monthly family | [account summary](account-summary.md#verdict-lines-outside-the-monthly-family) |
| The spend-control and over-quota notifications, the long-limit notifications | [notifications](notifications.md) |
| The five-hour forecast, the forecast tiers, the `fullRunway` tier | [Forecast](forecast.md) |
| The burn tier shown beside the rate (`DisplayFormatter.burnTier`) | [account summary](account-summary.md#header-facts) |
| Local activity, the 8-minute liveness gap, the monthly layout's local-day grain | [Local usage](local-usage.md) |
| Est. token value rows | [Estimated value](estimated-value.md) |
| The CLI as a whole (it links here for `runway_days`) | [CLI](cli.md) |

## Terms used here

| Term | Meaning on this page |
|---|---|
| **Usage credits** | Money a Claude seat pays for work past its five-hour or weekly limit. **Self-serve** on Pro and Max (the member's own switch); **organization** credits on Team (the organization pays and sets the cap). Which is which is decoded on [Claude account](claude-account.md#which-source-wins) |
| **Monthly limit** | As in [quota readings](quota-readings.md#the-vocabulary): money on a window-less Claude seat, credits on Codex (`MonthlyLimit`) |
| **Monthly layout** | A reading with a monthly limit and **no** primary used percent. The monthly limit then owns the hero, the verdict, the menu bar and the dot (`DisplayFormatter.monthlyLayoutLimit`) |
| **Money state** | The Claude credits situation, one of seven (`MoneyState`) |
| **Spend control** | The monthly pool is reached: the provider's flag, or used at 100 % or more (`QuotaSnapshot.monthlyReached`) |
| **Prepaid wallet** | A Pro/Max balance and auto-reload setting, read by a second call (`PrepaidCredits`) |

## Which account shows what

**Every money surface is decided by what the reading carries, never by the plan string** — with
one exception, the Codex section's plan gate, which [Codex account Decided 1](codex-account.md#decided)
rules out.

| Account | Credits card | Codex credits / spend | Monthly layout | Money glyph |
|---|---|---|---|---|
| Claude Pro / Max | Self-serve, with wallet rows | — | No | Can arm |
| Claude Team | Organization | — | No (no monthly limit is built) | Can arm |
| Claude Enterprise, window-less | None (no credits object) | — | Yes, money | Never |
| Codex Enterprise | — | Yes (full, or slimmed when a monthly limit exists) | When a monthly limit arrives and no primary window | Never |
| Codex Business and other plans | — | None today (plan gate) | When a monthly limit arrives and no primary window | Never |

(`DisplayFormatter.creditsCard`, `codexCreditsSpend`, `monthlyLayoutLimit`;
`MoneyModel.moneyGlyphInstant`; tests `DisplayFormatterTests.testCodexNonEnterpriseHasNoCreditsSection`,
`LongLimitSurfaceAgreementTests.testTheTeamFramesHaveNoMonthlyAnywhere`)

## Money states (Claude)

**One function turns the credits object into one of seven states,** tested in this order
(`MoneyModel.moneyState`):

| State | Condition | Means |
|---|---|---|
| `absent` | No credits object | No card |
| `capReached` | Credits on and used ≥ the cap; **or** organization credits off with reason `out_of_credits` | Nothing more can be charged |
| `charging` | Credits on and a window spent | Money is leaving now |
| `armed` | Credits on, no window spent | Headroom before any charge |
| `lastObserved` | Credits off, with a kept non-zero amount marked cached | Credits were on earlier this five-hour window |
| `blocked` | Credits off, a window spent | Hard block |
| `noBackstop` | Credits off, no window spent | A 100 % crossing will be a block, not a charge |

- **"A window is spent" means the five-hour or the weekly at 100 % or more.** Credits start the
  moment either runs out, so the card and the glyph read one test (`MoneyModel.windowSpent`;
  test `MoneyStateTests.testSpentWeeklyWithCreditsOnIsCharging`).
- **The cap test comes before charging.** A spent cap charges nothing whatever the windows say.
  The cap is compared in the units the used amount is stated in (`ExtraUsage.monthlyLimitMajor`).
  (Tests `testCapReachedIsTestedBeforeCharging`, `testCapComparisonRidesTheExponent`)
- **The switched-off organization shape is `capReached` too.** About a day after an organization's
  cap is reached the provider switches the meter off; it is the same fact
  (`testOrgCreditsSwitchedOffIsCapReached`).
- **For every forecast question `capReached` is `noBackstop`:** a 100 % crossing is a hard stop.
  It differs only in copy.
- **Codex has no money state.** The state engine passes none for Codex
  (`StateEngine`, `StateChange.moneyState`).

**Display-only.** The money state never changes the state, the default tab, or whether a
notification fires. It picks copy on four surfaces: the credits card (below), the exhaustion
verdict (`you'll be blocked` when credits are off or the cap is spent, otherwise `slow down or
you'll stop`), the over-quota verdict and recommendation while credits are paying (running on credits),
and the over-quota notification's variant (`NotificationEngine.overQuotaVariant`: `capReached` is
the hard-block variant). The wording of the last three is the [account summary](account-summary.md#verdict-lines-outside-the-monthly-family)'s,
the [popover](popover.md#the-recommendation)'s and [notifications](notifications.md)'s. (Tests `MoneyStateTests.testMoneyStateArmedChargingNoBackstopBlocked`,
`testMoneyStateLastObservedAndAbsent`, `DisplayFormatterTests.testOverQuotaCase1CreditsAccruing`)

### Imminence: one test for the card and the glyph

- **Minutes to 100 %** (`etaTo100Minutes`) is `(100 − used) ÷ burn`, on the **five-hour** window
  only, and only when the forecast is the full-runway tier and the burn is above 0.05 % a minute
  (`MoneyModel.armBurnFloor`). Otherwise it is unknown.
- **Imminent** (`isImminent`) is true when the five-hour window is at 98 % used or more
  (`noBurnArmFloor`, the fallback for no measurable burn), or when minutes to 100 % is less than
  minutes to the five-hour reset.

Reason: the card's amber and the glyph must agree poll for poll, so they read one number.
(Tests `testEtaTo100`, `testImminentByForecastAndByNoBurnFallback`,
`DisplayFormatterTests.testCrossSurfaceGlyphCardAgreement`)

### The money glyph

**When it arms** (`MoneyModel.moneyGlyphInstant`):

| Glyph | When |
|---|---|
| none | Credits off; or the cap is spent; or no window spent and not imminent |
| armed (amber) | Credits on, no window spent, imminent |
| charging (red) | Credits on, cap not spent, a window spent |

- **Credits off never lights the menu bar.** A crossing is a block, not a charge; the card alone
  says so. (`testGlyphOffAlwaysNone`)
- **A spent cap shows no glyph:** nothing is left to charge. (`testCapReachedWithWindowsFineHasNoGlyph`)
- **A window-less Enterprise seat never shows one,** because it has no credits object. Reason:
  what happens past that seat's limit has not been observed, and an armed or charging claim from
  an unverified source would be a false money claim.
- **The glyph is display-only;** it never changes the state.

**The glyph's hold.** A hotter glyph is adopted at once. A cooler one is adopted only after 2
consecutive poll-triggered evaluations agree (`StateEngine.glyphDemotePolls`); local-file and
poll-failure evaluations may escalate but never count toward calming. The one bypass is a window
reset or a withdrawn window: a red glyph measured against a window that no longer exists must not
outlive it. Unlike the state's hold ([state](state.md#calming-down-the-de-escalation-hold)) there
is no bypass on a drop to Idle or on resumed local activity. (`StateEngine.resolveGlyphHysteresis`;
tests `MoneyStateTests.testGlyphEscalatesImmediately`, `testGlyphJsonlDeltaDoesNotAdvanceDemoteStreak`) Its colours are
[display semantics](display-semantics.md#colours)'; its symbol and drawing are
[menu bar](menu-bar.md#the-money-glyph-drawn)'s. (Tests `testGlyphChargingArmedCoast`, `testGlyphDemotesOnlyAfterTwoConfirmingPolls`)

## The usage credits card (Claude)

**The card renders whenever the reading carries a credits object, including when credits are off.**
The off shape is the card's most useful state: it says a 100 % crossing will stop work. It is
suppressed only when there is no object at all, which is the window-less Enterprise seat.
(`DisplayFormatter.creditsCard`; `CreditsCardSectionView`) Its place in the popover is
[popover](popover.md)'s.

The amounts are billed money, not an estimate, so the card is exempt from the Est. token value
grammar and may say `charging`.

### Self-serve card (Pro / Max)

| Row | Shown when | Value |
|---|---|---|
| `Usage credits` (status) | Always | `armed` and `capReached` → `On · not charging` (neutral); `charging` → `On · charging` (red); `lastObserved` → `Off · was on earlier this window` (neutral); `noBackstop` → `Off` (neutral, **amber when imminent**); `blocked` → `Off` (neutral) |
| `This month` | Credits on, or `lastObserved` | `[used] of [cap]` (red while charging); the used amount alone when no cap is reported; `[used] (last observed)` when cached |
| `Auto-reload` | The wallet was read, its setting is known, and credits are on or the wallet reported a balance (zero included) | `On` (amber) / `Off` |
| `Prepaid balance` | The wallet was read and its balance is above zero | The balance |
| Sub-line | `noBackstop` | `Blocks in ~[eta] — usage credits are off` (amber) when imminent with a number; `Hard-block at 100% — usage credits are off` otherwise (amber when imminent by the 98 % fallback, muted when not) |
| Sub-line | Credits off with a reason, not `noBackstop` | `Off: [reason]`, the provider's string passed through, never switched on |
| `Manage in Claude web ↗` | Always | Opens the Claude usage settings in the browser. Kvotar only launches the page; it never changes an account setting |

- **`blocked` stays neutral on the card.** The block's message belongs to the verdict and the
  hint; the card stays minimal.
- **`armed` is neutral, not green:** credits being on is not a reason to spend freely.
- The hover card's live line names what the setting means: the stop at 100 % when off, the
  wallet balance when on (`ExplanationRegistry`, variants `on` / `off`).

(Tests `testCardArmedNoSpend`, `testCardCharging`, `testCardChargingAutoReload`,
`testCardNoBackstopCalm`, `testCardNoBackstopImminent`, `testCardLastObserved`,
`testCardPrepaidCallAbsent`, `testUsageCreditsLiveFollowsTheSetting`)

### Organization card (Team)

Same card, with these differences (`orgManagedCreditsCard`):

- **Title** `Usage credits · set by your organization`.
- **Status:** `On · not charging` (neutral); `Charging now` (red) with the sub-line
  `Paid by your organization at API rates.`; at the cap `Spent for [month]` (**neutral**) with the
  sub-line `You stop when a window runs out.`; anything else `Off`, with no sub-line.
- **`This month`** reads `[used] of [cap] · resets [date]`. On the switched-off shape, which
  carries no amounts, it reads `resets [date]` alone. The date is the next calendar-month start
  in UTC; the month name is read in UTC like the reset.
- **No `Manage` link, no `Auto-reload`, no `Prepaid balance`:** the member can neither switch
  credits nor top up.
- **Never the raw reason string.** A member cannot act on the organization's reason.

Reasons: the cap is neutral because on this seat a spent cap stops the extra charge, not the
work; the work stops when a window runs out. Printing `€0.00` for an absent amount would invent a
figure. (Tests `LongLimitSurfaceAgreementTests.testFrameAWeeklySpentCharging`,
`testFrameBWeeklySpentCapReached`, `testFrameBSwitchedOffIsStillTheOrganizationsCard`,
`testOrgCardNeverPrintsARawReason`, `testFrameCCapReachedWindowsFine`)

**A line under a block.** When a Team seat is blocked and its credits are at `capReached`, the
header gains one muted line: `Usage credits spent for [month] — [cap] cap, set by your
organization`, without the cap clause when none is reported. It answers "why am I stopped when
credits are on". (`DisplayFormatter+LimitSelection.swift`: `orgCreditsSpentLine`)

### The prepaid wallet's display

- **Rows:** `Auto-reload` and `Prepaid balance`, as above. Auto-reload is on/off only: nothing
  inside the setting is read, so no amount or "about to charge" warning is ever stated.
- **Currency:** the wallet's own; the credits' currency when the wallet sent none
  (`prepaidBalance`; test `testPrepaidBalanceCurrencyFallsBackToTheCredits`).
- **Its own age.** The source tag reads `Credits: Claude account · [age] · Balance/reload:
  prepaid · [age]`: the wallet is fetched on its own clock and auto-reload is changed outside
  Kvotar. With no wallet, or on a stale reading, the tag collapses to the single Claude-account
  stamp (`creditsSourceTag`).
- **No wallet, no wallet rows;** the credits rows stay. Which seats are read, and the latch, are
  [Claude account](claude-account.md#the-prepaid-wallet)'s.

Money is printed in the provider's currency through one formatter
([display semantics](display-semantics.md#rounding-and-number-forms)); the card uses the
credits' own currency and exponent (`creditsUsed`, `creditsUsedOfCap`, `creditsCap`; tests
`testCardRendersTheProvidersCurrency`, `testCreditsCardGroupsThousands`).

## The Codex credits / spend section

**Shown only when the plan string is exactly `enterprise`** (case-insensitive). That gate is
ruled to change: [Codex account Decided 1](codex-account.md#decided). (`codexCreditsSpend`;
`CreditsSpendSectionView`, titled `Credits / spend` and drawn `CREDITS / SPEND`, since
`SectionCard` upper-cases its title)

| Row | Full section | Slimmed section |
|---|---|---|
| `Plan` | The plan's display name | Same |
| `Credit balance` | `$X remaining`, or `unavailable` when missing (see below) | Not shown |
| `Spend control` | `Reached` (red) / `Active · not reached`; absent when the provider sent no flag | `Limit reached · resets [date]` (red) / `Active · not reached`; absent without a flag |
| `Est. token value · today`, `· 30-day` | When local value exists ([estimated value](estimated-value.md)) | Not shown |

**The credits balance's meaning is unknown.** Captured payloads send `credits.balance` as the
string `"0"`, beside `hasCredits: false` and `unlimited: false`. The decoder reads only a number,
so `"0"` becomes missing and the row says `unavailable`
([codex account, Known gaps](codex-account.md#known-gaps)); the two flags are not decoded. A
number would print as dollars through the estimated-value formatter, though nothing says the
balance is money rather than credits. The maintainer ruled on 2026-10-04 to decide nothing until
a capture with a non-zero balance exists; the unit and the wording are then picked together.

**The section is slimmed whenever the reading has a monthly limit,** even when windows are also
present. Reason: the wallet balance is not the monthly user limit, and showing both side by side
confused the two; the quota story lives on the monthly limit itself.
(Tests `DisplayFormatterTests.testCodexEnterpriseCreditsCard`,
`DisplayFormatterMonthlyTests.testMonthlyHealthyPopover`, `testMonthlyReachedPopover`)

## Spend control as a condition

**The monthly pool is reached when the provider's spend-control flag is true, or the monthly used
amount is at 100 % of the limit or more.** It is one property in Core, read by the state engine,
the display and the notification engine. (`QuotaSnapshot.monthlyReached`;
`DisplayFormatter.monthlyReached` is a thin copy that takes a monthly limit in hand; test
`StateEngineTests.testMonthlyAtTheCeilingIsSpendControlWithoutAFlag`)

- Reason: the Claude adapter never sets the flag, so before the rule moved to Core a Claude monthly
  at 100 % read `Spend limit reached` on screen while the state engine showed nothing.
- **What reaching the limit actually stops on a Claude seat has not been observed.** The copy says
  only what is known: `Spend limit reached` for money, `Monthly limit reached` for credits
  (`Spend limit reached` is claude.ai's own wording).
- The state it raises, its rank and its survival while stale are [state.md](state.md#the-states)'s;
  its expiry with the monthly cycle is [quota readings](quota-readings.md#expired)'; its banner is
  [notifications](notifications.md)'s.
- With a monthly limit present, a spend-control block puts the monthly limit in the hero
  (`selectLimit`; test `AccountLimitSelectionTests.testSpendControlIsTheMonthlyBlockWhereAMeterExists`).

## The monthly layout

**The monthly limit takes over the header when it exists and no primary window has a used
percent.** A populated window takes the hero, verdict, menu bar and dot back at once (window
precedence); the monthly limit then sits in `OTHER LIMITS` as an ordinary row. Detection reads the
data, never the plan. (`monthlyLayoutLimit`; `selectLimit`; tests
`DisplayFormatterMonthlyTests.testMonthlyWindowsPrecedence`, `testClaudeMonthlyWindowsPrecedence`,
`AccountLimitSelectionTests.testWeeklyAndMonthlyWithNoFiveHourKeepsTheMonthlyLayoutAndListsTheWeekly`)

Reason: a monthly limit with no window is the whole quota story for these seats; a dash would
claim no reading while one is held.

### The hero and its lines

- **Caption:** `Monthly spend limit left` (Claude, money) or `Monthly usage limit left` (Codex,
  credits). The `OTHER LIMITS` row is named `Monthly spend limit` / `Monthly usage limit`; the
  strip says `Monthly spend` / `Monthly usage`.
- **Percent left** comes from the amounts (`MonthlyLimit.usedPercentExact`), not from the
  provider's remaining percent. Above 99.5 % used see
  [display semantics Decided 3](display-semantics.md#decided) (`<1%`).
- **Verdict** (`monthlyVerdict`), first match wins:

| Case | Line 1 | Line 2 | Colour |
|---|---|---|---|
| Reached | `Spend limit reached — resets [date]` / `Monthly limit reached — resets [date]` | `blocked · resets [date] · ↻ [days]`, or `· as of [time]` when stale | Red, fresh or stale |
| Stale, sign-in expired | `Claude sign-in expired — open Claude Code to reconnect.` | `as of [time] · [used] of [limit] · lower bound` | Grey |
| Stale, refused | `Reconnecting…` | same | Grey |
| Stale, other | `No fresh reading — showing last known` | same | Grey |
| Forecast runs out early | `At this pace, runs out in ~[runway] — [lead] before reset` | detail | Forecast dot |
| 90 % used or more | `Nearly at the monthly limit — resets [date]` | detail | Red |
| Otherwise | `On pace — resets [date] ([days])` | detail | Forecast dot |

  The detail is `[pace]/day · [used] of [limit]`, plus `workspace pool` for credits only. Money
  never names a pool, because whether a Claude spend limit is per seat or shared has not been
  verified.
- **Meta line** under the hero (`monthlyMetaLine`): `Set by your organization` (Claude) or
  `Workspace limit · shared across ChatGPT and Codex` (Codex), then `spend limit reached` /
  `spend control reached`, `pace suspended` while stale, or the pace word (`runs out ~[date]`
  when the forecast gate is met, else `on pace`; nothing in the first day of the cycle, when there
  is no pace yet). Under the hero the per-day amount is left out,
  since the verdict above states it; on an `OTHER LIMITS` row it is included.
- **Stale:** the kept percent is a lower bound (a month's usage only rises), and every pace claim
  is suspended. A month that rolled over unseen falls to the unknown form, by the expiry rule of
  [quota readings](quota-readings.md#expired). (Tests `testMonthlyStaleKeepsLowerBoundAndSuspendsPace`,
  `testMonthlyRolledOverUnseenDegradesToUnknownForm`)

### Dots, the menu bar and the strip

- **The forecast dot** (`monthlyForecastDot`): red when reached or at 90 % used or more; amber
  when the forecast gate is met (below); else green. On a fresh monthly layout whose state is
  Null window it paints the menu-bar dot and the tab dot. A higher-rank state keeps its own
  colour; a stale reading keeps grey, or red for a block. The hand-off between this dot and the
  long-limit tiers is [state.md](state.md#the-states)'s.
- **Row cue:** the long-limit tier where one is assessed and the reading is fresh; the forecast dot
  otherwise (`tieredCue`).
- **Menu-bar slot** (`monthlyMenuBarSlot`): `◔~[runway]` when the reading is fresh, the pool is not
  reached, the confidence half holds, the runway ends before the reset, and the runway is at most
  7 days; otherwise `↻[days to reset]`, or no slot once the reset has passed. A reached pool always shows the reset slot. The number is
  percent left of the monthly limit. Drawing is [menu bar](menu-bar.md)'s. (Tests
  `testMonthlyPaceMenuBarRunwaySlot`, `testMonthlyReachedMenuBarAlwaysResetSlot`,
  `testMonthlyStaleMenuBarNeverShowsRunwaySlot`)
- **Long-limit strip** for a monthly in the amber or red tier while it is not the hero: a money
  meter states the amount left (`[name] … — €3.90 left for 12 days, resets [date]`), and an amber
  monthly whose forecast gate is met ends `runs out ~[date]` instead of the reset
  (`longLimitStrip`).
- **Near-cap recommendation** (`monthlyNearCap`, at 90 % used or more, not reached, monthly
  layout only): Codex `Monthly workspace limit nearly reached — [left] left with [days] until
  reset. You can request a limit increase from ChatGPT settings → Usage.` with a link to ChatGPT's
  usage settings; Claude `Monthly spend limit nearly reached — ask your workspace admin. Resets
  [date].` with the `Manage in Claude web` link. Recommendation only: no state and no
  notification of its own. (Tests `testMonthlyNearCapRecommendationAndRed`,
  `testClaudeMonthlyNearCapRecommendationAndRed`)

### Header facts on a monthly hero

- **`Quota burn`** is the trailing spend rate, in the meter's units (`~$4.10/hr`,
  `~14 credits/hr`), with a tier word. No rate yet, or a stale reading: the fact is not shown.
  A measured zero reads `No measurable burn`; a positive rate below one unit reads `<1 credit/hr`
  or `<$0.01/hr`. (`headerFacts`; test `testMonthlyBurnDistinguishesZeroFromASubPrecisionPositive`)
- **`Not seen locally`** is the split's Elsewhere amount: `≈[amount] (est.)`, `<1 credit (est.)`
  for a positive amount below one unit, hidden at zero, `—` when unknown or stale.
  (test `testMonthlyNotSeenLocallyHidesZeroAndBoundsASmallPositive`)

## The monthly forecast

**Pace and runway are worked out from the provider's own amounts only, never from local tokens.**
Reason: the pool's denominator is set by the provider and shared beyond this Mac, so local token
counts can never explain it.

| Quantity | Rule | Code |
|---|---|---|
| Cycle start | The reset minus one calendar month, in UTC (28–31 days, never a fixed 30) | `MonthlyLimit.cycleStart` |
| Days elapsed | Now minus the cycle start | `daysElapsedInCycle` |
| Pace | Used ÷ days elapsed; unknown under one day | `pacePerDay` |
| Runway | (Limit − used) ÷ pace, floored at 0; unknown while pace is unknown or zero | `runwayDays` |

(Tests `MonthlyLimitTests.testPaceAfterFifteenDays`, `testPaceNilUnderOneDayElapsed`,
`testRunwayDaysNilWhilePaceUnavailable`, `testRunwayDaysFlooredAtZeroWhenOverLimit`,
`testDerivationsAreUnitIndependent`)

**The gates** (`DisplayFormatter` constants):

| Gate | Rule | Constant |
|---|---|---|
| Confidence | At least 7 days elapsed, **or** at least 25 % used | `monthlyConfidenceMinDaysElapsed`, `monthlyConfidenceMinUsedPct` |
| Forecast (amber, `runs out` copy) | Confidence, a runway, and the runway ends at least 2 days before the reset | `monthlyForecastMinLeadDays` (`monthlyForecastGateMet`) |
| Red | Reached, or at least 90 % used | `monthlyRedUsedPct` |
| Menu-bar runway slot | Fresh, not reached, confidence, runway before the reset, runway ≤ 7 days | `monthlyRunwaySlotDays` |

These are starting values from dogfooding, not measured optima. Reason for the confidence half:
a single reading early in the month gives a pace that is arithmetic, not a forecast.

**One derivation, three surfaces.** The menu-bar slot, the forecast dot and the verdict all read
`runwayDays`, so they cannot disagree about the number (test
`testCrossSurfaceAgreementFreshStaleAndReached`). They do differ on the gate (Known gaps).

**The CLI's `runway_days`** is `MonthlyLimit.runwayDays` on the last saved reading, reported when
the CLI's window is the monthly one (no primary used percent). It needs no burn history, so the
CLI can state it from one row. Today it applies none of the gates above (Known gaps).
(`Packages/KvotarCLI/Sources/KvotarCLI/CLIFormat.swift`: `CLIFormat.displayWindow`, `detail`;
`Status.swift`: `runway_days`)

## The monthly spend rate

**A trailing rate over saved polls, not a two-poll rate** (`MonthlySpendRate.compute`):

- Samples are the saved polls of the last 65 minutes that carry a monthly used amount, this poll
  included (`SQLiteStore.readMonthlyUsedSamples`, called from `PollCoordinator`).
- Only samples of the newest sample's cycle count (reset within 60 s).
- The rate is (newest used − oldest used) ÷ the time between them, per hour, in the meter's raw
  units. Samples in between do not change it.
- **Unknown, never zero,** when the span is under 30 minutes (`monthlyRateMinSpan`, 1800 s) or
  the newest used amount is below the oldest (dips in between do not matter). A measured zero over enough span is zero.

Reason: providers update these meters in lumps (Codex in steps of ten credits on the web, and its
pooled counter dips back a little at rest), so a two-poll rate is noise and a trailing one stays
honest. (Tests `MonthlySpendRateTests.testBelowMinSpanIsNilNeverZero`,
`testNegativeDeltaIsNilNeverNegative`, `testMeasuredZeroOverSufficientSpanIsZero`,
`testCrossRolloverSamplesExcludedFromSpan`, `testCodexTenCreditLumpsSmoothOverMinSpan`)

**The tier word is anchored to break-even** (`monthlyBurnTier`): `r = rate ÷ (remaining ÷ hours to
reset)`, so 1.0 is exactly the rate that spends the pool at the reset. Shown as `Very low` (a
positive rate below one raw unit an hour, green), `Low` below 0.5, `Mid` below 1.0, `High` from
1.0; a measured zero reads `No measurable burn`. Green below 1.0; from 1.0 red when the pool is already at 90 % or would run
out within 48 hours, else amber. A spent pool is `high`, red. Reason: one set of numbers works in
dollars and credits alike. The rate (now) may disagree with the pace (the month's average); that is
by design.

## The monthly attribution split

**Each poll's rise in the monthly meter is filed whole to this Mac or to elsewhere**
(`MonthlyAttributionEstimator.record`):

- The rise is `max(0, used − the highest used seen this cycle)`; the high-water mark stops a
  dipping meter from counting twice.
- If priced local activity over the last 8 minutes is above zero, the rise is **this machine**;
  otherwise it is **elsewhere**. The 8 minutes match the local-liveness gap, so a long turn that
  writes nothing until it ends is not read as idle ([local usage](local-usage.md)).
- **The residual** (`unattributedAmount`) is used minus the two buckets. It holds what was already on the
  meter when Kvotar started watching this cycle (an install mid-month, a long gap). It is never
  guessed into a bucket.
- The three always sum to the used amount (`MonthlyAttribution`).
- A reset that moves by more than 60 s is a new cycle and starts the buckets at zero.
- The running totals are saved per tool under `monthly_attrib_accum_<tool>`
  ([storage](storage.md#the-settings-table)) because a month outlives many launches.
- It runs on every successful poll whose reading has a monthly limit, windows or not. Between polls
  the stored split is read without advancing (`current(for:)`), so nothing is filed to an
  interval no poll measured.

(Tests `MonthlyAttributionEstimatorTests.testIdleIntervalsAccumulateOffMachine`,
`testActiveIntervalsAccumulateLocal`, `testDownwardWobbleDoesNotDoubleCount`,
`testMidCycleFirstObservationIsUnattributed`, `testAnchorAdvanceStartsFresh`,
`testSumInvariantAcrossMixedSequence`, `testPersistenceResumesMidCycle`,
`testPerToolAccumulatorsAreIndependent`)

**What users see.** Only the elsewhere share, as the `Not seen locally` fact on a monthly hero
(above), always hedged `≈ … (est.)`: each rise is exact but which bucket it lands in is inferred
from timing, and how promptly the Claude meter updates is unverified. The diagnostics bundle's
explanation snapshot carries all three amounts. No surface shows the split's own labels, and the
rows do not return (Decided 1). `offMachine` and `unattributed` are internal names
([product scope](product-scope.md#terms-a-newcomer-needs) defines Elsewhere).

## Rejected alternatives

- **Choosing the monthly layout from the plan string.** Detection is the data: an active meter or
  a reported monthly limit, and no populated window.
- **Gating the credits card on credits being on or on spend.** The off shape is the card's most
  valuable state.
- **Red for an organization's spent cap.** On that seat it stops the extra charge, not the work.
- **A two-poll monthly rate.** Noise under lumpy meter updates; a trailing rate was chosen instead.
- **Monthly pace from local tokens.** The pool's denominator is the provider's alone.
- **Guessing spend seen before Kvotar watched into a bucket,** or naming the residual "Before
  install" (wrong after a mid-month gap).
- **The worst limit's colour on the menu bar.** The limit the bar displays owns the dot.

## Known gaps

| Gap | Today | Proposed fix |
|---|---|---|
| Orphan split cards | `ExplanationElement.thisMachine` and `.unattributed` have cards but no row uses them, and the `.monthlyOffMachine` registry body never renders (the `Not seen locally` fact passes its own body). `MonthlyAttribution`'s doc still describes rows on a Monthly card | (Decided 1) Delete the `This machine` and `Unattributed` cards and the unused `Elsewhere` text, keeping the element id; fix the doc |
| An internal name as user copy | The `.unattributed` card text opens `**Unattributed.**` (`ExplanationRegistry`), the internal name the maintainer ruled out of copy | (Decided 1) Deleted with the card |
| Codex credits balance | `"0"` decodes as missing and reads `unavailable`; a number prints with `Fmt.dollarValue` (the estimated-value formatter) as dollars; `hasCredits` and `unlimited` are not decoded | Decide nothing until a capture with a non-zero balance exists (ruled 2026-10-04); then pick the unit and wording. The decoding fix is [Codex account](codex-account.md#known-gaps)'s |
| Codex section gated on a plan string | Shown only for exactly `enterprise` | [Codex account Decided 1](codex-account.md#decided) |
| Menu-bar slot and verdict use different gates | The `◔` slot needs only runway before the reset; the amber verdict needs a 2-day lead. With a runway ending 1 day before the reset the bar reads `◔~[n]d` while the verdict reads `On pace` in green (below 90 % used) | Make the slot also require `monthlyForecastGateMet`, with a test |
| CLI `runway_days` is ungated | The CLI prints `runway ~[n]d` for any monthly reading with a pace: while stale, before the confidence half holds, when the runway outlasts the reset, and `~0h` when reached. No CLI test covers the monthly path | Apply the confidence and before-reset gates (or print the reset instead) in `CLIFormat.detail`; add tests. [CLI](cli.md) links here |
| Unknown local value counts as elsewhere | `record` files a rise to elsewhere when the local value is `nil` (a failed value read), not only when it is zero | Treat `nil` as not observed, or skip the rise, with a test |
| Glyph cannot warn ahead of a weekly | Imminence reads the five-hour window only, while "a window is spent" includes the weekly, so a weekly about to run out never arms the glyph | Decide whether the weekly should arm it; if so, extend `isImminent` |
| Two 90 % constants | `monthlyRedUsedPct` (forecast dot, verdict, near-cap) and `StateEngine.longLimitNearlySpentPct` (the long-limit red tier) are separate | Read one constant, or record why they may differ |
| Provider remaining percent unused | `MonthlyLimit.remainingPercent` is decoded and stored, but no display reads it; its doc says the row layer does | Fix the doc, or drop it with an agreed issue |
| Unreachable grey burn tier | `monthlyBurnTier`'s `—` grey for a missing rate cannot be reached: `headerFacts` hides the fact before calling it (the `—` for a passed reset can) | Remove the missing-rate branch or fix its doc |
| Stale comments | `QuotaSnapshot.extraUsage` says always `nil` for Codex (the adapter sends the disabled shape); `PollCoordinator` says the monthly amounts go in as Claude dollars (they are minor units); `CreditsSpendSectionView` lists every row, not the slimmed form | Fix with the next change to each file |

## Code and tests

| What | Where |
|---|---|
| Money states, imminence, the glyph's instant rule | `Packages/KvotarCore/Sources/KvotarCore/State/MoneyState.swift` |
| `MonthlyLimit` derivations, `ExtraUsage`, `PrepaidCredits`, `QuotaSnapshot.monthlyReached` | `Packages/KvotarCore/Sources/KvotarCore/Adapters/AccountAdapter.swift` |
| Trailing spend rate | `Packages/KvotarCore/Sources/KvotarCore/Forecast/MonthlySpendRate.swift` |
| Monthly attribution split | `Packages/KvotarCore/Sources/KvotarCore/Forecast/MonthlyAttributionEstimator.swift` |
| Wiring (split, rate, money state on the change) | `App/PollCoordinator.swift`, `Packages/KvotarCore/Sources/KvotarCore/State/StateEngine.swift` |
| Credits card, Codex section, monthly verdict, dot, slot, burn tier, money helpers | `Packages/KvotarUI/Sources/KvotarUI/Model/DisplayFormatter.swift` |
| Monthly candidate, meta line, strip, header facts, organization line | `Packages/KvotarUI/Sources/KvotarUI/Model/DisplayFormatter+LimitSelection.swift` |
| Views | `Packages/KvotarUI/Sources/KvotarUI/Views/Sections/CreditsCardSectionView.swift`, `CreditsSpendSectionView.swift` |
| CLI `runway_days` | `Packages/KvotarCLI/Sources/KvotarCLI/CLIFormat.swift`, `Status.swift` |
| Tests | `MoneyStateTests`, `MonthlySpendRateTests`, `MonthlyAttributionEstimatorTests`, `MonthlyLimitTests`, `StateEngineTests` (`Packages/KvotarCore/Tests/KvotarCoreTests/`); `DisplayFormatterMonthlyTests`, `DisplayFormatterTests`, `LongLimitSurfaceAgreementTests`, `AccountLimitSelectionTests` (`Packages/KvotarUI/Tests/KvotarUITests/`) |
