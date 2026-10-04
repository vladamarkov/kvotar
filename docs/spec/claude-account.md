---
summary: How Kvotar reads a Claude account — the three calls it makes and what each sends, how the usage response becomes a reading (the five-hour and weekly windows, reset de-jitter, unreadable resets, model-scoped weekly limits), how Pro/Max, Team and Enterprise seats are told apart, and how extra usage, monthly spend and the prepaid wallet are decoded.
read_when: Changing ClaudeAccountAdapter or ClaudeResponses (ClaudeUsageResponse, ClaudeProfileResponse, PrepaidCreditsResponse); what a Claude field maps to in QuotaSnapshot; the five_hour / seven_day / limits[] / extra_usage / spend decoding; reset de-jitter; the plan string; prepaid eligibility or the 401/403 latch; the headers sent to api.anthropic.com; or adding a Claude fixture.
---

# Claude account

## Questions for owner

1. **What should a model-scoped weekly limit with no reset show?** Today an entry with 0 % and no
   reset reads `not started`. That is accidental, not an adopted rule: every scoped limit gets a
   seven-day width, so it passes the display's model-window not-started test. An unparseable scoped
   reset also becomes "no reset" (silently), so a malformed value can produce the same label. No
   test covers it, two code comments say it cannot happen, and rule W (retracting a contradicted
   not-started claim) clears only the five-hour window. Proposed next step: first tell a missing
   reset apart from a malformed one in the adapter, then decide the intended display. Options for
   that decision, as context: read a missing reset as not started, read it as unknown, or extend
   rule W to model windows.

## About this page

This page is the specification for how Kvotar talks to a Claude account and turns the answers into
a reading. It replaces the private Baseline §7.1 and the endpoint, profile and spend-decoding parts
of §8.0.2–§8.0.4, the Claude account rows of the private UI Spec §6, and the adapter decisions of
the private decision record on Claude Enterprise monthly spend. Change this page in the same commit
as the code it describes.

What this page does **not** own:

| Topic | Page |
|---|---|
| What a reading, window, reset, null, not-started, expired or stale reading means; rule W; the shared 60 s tolerance | [quota-readings.md](quota-readings.md) |
| Finding and reading the Claude token, the expiry gate, never refreshing or writing it | [credentials](credentials.md) |
| When a call is made: cadence, cold polls, profile and prepaid timing, the latch's effect on polling, 429s and holds | [polling.md](polling.md) |
| Which state a reading puts the account in | [state.md](state.md) |
| Wording and colour; the plan badge is neutral | [display-semantics.md](display-semantics.md) |
| Plan display names (`DisplayFormatter.planDisplayName`) | `popover.md` (pending) |
| Usage credits, monthly spend and spend control as a product | [Credits and monthly limits](credits-and-monthly-limits.md) |
| What Kvotar is and the account kinds in brief | [product scope](product-scope.md) |
| Response capture for diagnostics | [diagnostics.md](diagnostics.md) |

## Calls and what is sent

Kvotar makes three calls, all `GET` to `api.anthropic.com`, all with the user's own Claude Code
access token. No other host or path is called for Claude.
(`ClaudeAccountAdapter.usageURL`, `profileURL`, `prepaidURL(orgId:)`; test
`NoRefreshNetworkSeamTests.testAFullCycleReachesOnlyTheQuotaEndpointsAndNeverSendsARefreshToken`)

| Call | Path | Purpose | Headers Kvotar sets |
|---|---|---|---|
| Usage | `/api/oauth/usage` | The quota reading, every poll | `Authorization: Bearer <token>`, `User-Agent` |
| Profile | `/api/oauth/profile` | Email, plan, organization id, prepaid eligibility | the same, plus `anthropic-beta: oauth-2025-04-20` |
| Prepaid wallet | `/api/oauth/organizations/<org id>/prepaid/credits` | Balance, auto-reload, wallet currency. Pro and Max only | the same as profile |

- **No request body** (the fetch seam is `GET` only). Besides the headers above, only URLSession's
  standard `Accept*` headers go out. (`HTTPFetcher`, `URLSessionFetcher`)
- **The session is ephemeral:** nothing is written to disk, but a cookie the host sets is kept in
  memory and sent back until Kvotar quits (Known gaps). The timeout is 10 s of idle time.
- **Kvotar names itself:** `User-Agent: Kvotar/<version>`. Reason: imitating Claude Code to get
  past a rate limiter risks a block and misidentifies the traffic.
- **The organization id comes only from the profile** (`organization.uuid`) and is held in memory
  for the current token.

**The usage call's outcome:**

| Outcome | What happens | Pointer |
|---|---|---|
| 2xx | The body is decoded into a reading | `checkUsageStatus` |
| 401 or 403 | The token is read again. If it changed, the call is retried **once** with the new token. Same token, a failed read, or a second 401/403: the poll ends as re-auth required (`reauthRequired`) | tests `test401RotationSelfHeals`, `test401SameTokenStillReauths`, `test401PersistsThrowsAfterOneRetry` |
| 429 | A refused poll: [polling.md](polling.md) | `checkUsageStatus` |
| Other status | The poll fails with that status; health becomes unknown | `checkUsageStatus` |
| Undecodable body | The poll fails as a decoding error; health becomes unknown | `fetchQuotaSnapshot` |
| Transport error | The poll fails; health is left as it was | `fetchQuotaSnapshot` |

Reason for the single retry: Claude Code can rotate the shared token between Kvotar's read and its
request, and that race once left the app asking for a sign-in nobody needed.

## From the usage response to a reading

**One usage response becomes one reading** (`QuotaSnapshot`, tool `.claude`, source `.oauth`).

| Reading field | From | Notes |
|---|---|---|
| Primary used percent | `five_hour.utilization` | Kept as sent, including 0 |
| Primary reset | `five_hour.resets_at` | Parsed, then de-jittered |
| Primary width | Always 18,000 s | The endpoint sends no width; the not-started test needs one |
| Secondary used percent, reset | `seven_day.utilization`, `seven_day.resets_at` | Reset de-jittered. No width set: the shared seven-day fallback applies |
| Rate limit reached | Primary used percent ≥ 100 | `nil` with no five-hour percent |
| Model allowances | `limits[]`, kind `weekly_scoped` | [Model-scoped weekly limits](#model-scoped-weekly-limits) |
| Extra usage, monthly limit, prepaid wallet | `extra_usage`, `spend`, the prepaid call | [Money fields](#money-fields-decoding-only) |
| Null-window source | `provider` when `five_hour` is absent or `null` | Diagnostics only |
| Email, plan | The profile, with fallbacks | [Profile, plan and account kind](#profile-plan-and-account-kind) |
| `rateLimitLimit`, `-Remaining`, `-Reset` | Headers `X-RateLimit-Limit`, `-Remaining`, `-Reset` (epoch seconds) | Stored with the poll; nothing branches on them |

(`fetchQuotaSnapshot`; tests `testHealthyNormalization`, `testResetTimestampsParsed`,
`testRateLimitReachedWhenOverHundred`, `testHeadersStoredInSnapshot`)

### The five-hour window: four shapes

`resets_at`, not `utilization`, says whether a window is open. A present object keeps its percent
even without a reset.

| Payload | Reading | Meaning | Test |
|---|---|---|---|
| `five_hour` absent or `null` | Used `nil`, reset `nil` | Null window; the normal case on an Enterprise seat | `testAbsentFiveHourStaysNullWindow`, `testBothWindowsNullDecodes` |
| Present, `resets_at: null` (sent with 0) | Used 0, reset `nil`, width 18,000 s | Not started | `testNullFiveHourWindowDecodesWithLiveWeekly`, `testPresentFiveHourWithNullResetIsNotStarted` |
| Present, `resets_at` unparseable | Used kept, reset `nil`, warning logged | Reset unreadable | `testUnparseableResetDegradesWindowInsteadOfFailing` |
| Present, `resets_at` parses | Used and reset kept | Live window | `testHealthyNormalization` |

`seven_day` is parsed the same way, on its own, so a bad five-hour reset never costs the weekly.
Timestamps parse as ISO 8601 with or without fractional seconds. (`parseReset`, `parseTimestamp`)
Reason for keeping the 0: it gives Claude the same not-started shape Codex has
([quota-readings.md](quota-readings.md), rejected alternatives).

### Reset de-jitter

**A reset that moves by 60 s or less between polls is the same reset; the earlier value is kept.**
A larger move is a new window and becomes the anchor. The five-hour and weekly windows each have an
anchor. A missing reset passes through as missing and leaves the anchor alone. A token change
clears both anchors. (`deJitter`, `resetJitterTolerance`; test `testResetsAtDeJitteredAcrossPolls`)

Reason: the endpoint's fractional-second `resets_at` rounds to two neighbouring whole seconds across
polls, and downstream code once read that as a rollover and re-sent the window-reset notification
every poll. Model-scoped resets are not de-jittered (Known gaps).

### Decoding: strict core, lenient newer fields

- **Unknown keys are ignored.** Obfuscated payload fields (for example `amber_ladder`,
  `omelette_promotional`, `nimbus_quill`) are never declared.
- **Strict:** `five_hour`, `seven_day`, `extra_usage`. Each may be absent, but a present value of
  the wrong shape fails the whole poll.
- **Lenient:** `spend`, `member_dashboard_available`, `limits`. A shape Kvotar does not expect
  becomes `nil` and the poll survives. Each is all-or-nothing: one malformed `limits[]` entry drops
  the whole array, with no log line. (`ClaudeUsageResponse.init(from:)`; tests
  `testLimitsUnexpectedShapeDegradesNeverFailsPoll`,
  `testSpendUnexpectedShapeDegradesToNilNeverFailsPoll`)

Reason: one strict field once made a whole provider response undecodable. Fields that arrived
later, without notice, get the lenient decode.

## Model-scoped weekly limits

`limits[]` carries the bars claude.ai's usage page draws. (`scopedLimits`,
`ClaudeUsageResponse.LimitEntry`; tests `testScopedWeeklyLimitMapped`,
`testNoLimitsArrayYieldsNoScopedLimits`)

- **Only `kind: "weekly_scoped"` is read.** `session` and `weekly_all` restate `five_hour` and
  `seven_day`, which stay the source of the two windows. `group`, `is_active` and `severity` are
  read by nothing.
- **The name is `scope.model.display_name`, as sent.** `scope.model.id` has always been `null`, so
  nothing keys on an id or on the name's value.
- **An entry with no model name is skipped**, including a surface-scoped one, and counted in a log
  line. Reason: a placeholder row states a fact about a limit nobody can name.
- **Used percent is the whole-number `percent`, verbatim.** It matches claude.ai's bar.
- **The reset is parsed like a window's;** an unparseable one becomes `nil`, silently.
- **The width is seven days,** because `weekly_scoped` names the period. No secondary window.
- A scoped reset and the weekly reset differ by microseconds, so the display compares them with
  the 60 s tolerance. (`DisplayFormatter.swift`, the scoped reset-row loop; test
  `DisplayFormatterScopedLimitsTests.testScopedResetWithinToleranceDrawsNoSecondResetRow`)
- `seven_day_opus` and `seven_day_sonnet` are not read: null since `limits[]` replaced them.

**No reset:** an entry with 0 % and no reset (missing or malformed) reads `not started` today. That
is accidental, not a rule, and rule W never retracts it (Question 1). Above 0 % with no reset, it is a real limit that cannot be dated.
Expiry of model windows is [quota-readings.md](quota-readings.md)'s.

## Profile, plan and account kind

### The profile

**Read once per token**, before the prepaid call, which needs its organization id. A failed or
non-2xx call is not retried for that token. Timing is [polling.md](polling.md)'s.
(`fetchProfileIfNeeded`; tests `testProfileFetchedOncePerToken`, `testEmailFromProfileEndpoint`,
`testEmailFallsBackToLocalConfigWhenProfileFails`)

| Field | Used for |
|---|---|
| `account.email` | The email shown. Fallback: `oauthAccount.emailAddress` in `~/.claude.json` |
| `account.has_claude_pro`, `has_claude_max` | The plan; prepaid eligibility |
| `organization.uuid` | The prepaid call's path |
| `organization.organization_type == "claude_enterprise"` or `seat_tier == "enterprise_usage_based"` | Either marks Enterprise |
| `organization.rate_limit_tier` | A plan fallback |

### The plan string

**A raw string, from the first source that answers:**

1. Profile: `has_claude_max` → `max`; `has_claude_pro` → `pro`; an Enterprise signal →
   `enterprise`; `rate_limit_tier` containing `max` or `pro` → that word.
2. The credential's `subscriptionType`, normalized the same way.
3. The credential's `subscriptionType` as stored.
4. None.

(`planType(from:)`, `normalizePlan`; tests `testPlanFromProfileProBoolean`,
`testPlanFromProfileMaxBoolean`, `testPlanFromKeychainSubscriptionWhenNoProfile`,
`testPlanNormalizesOddKeychainValue`, `testPlanRetainsRawUnrecognizedKeychainValue`,
`testProfilePlanTakesPrecedenceOverKeychain`, `testPlanNilWhenNoSource`)

**The profile never yields `team`.** A Team profile has no plan boolean, no Enterprise signal and a
tier with neither word, so its plan string is whatever the credential holds, which the code does
not show. The display expects `team` (Known gaps).

### Account kinds as decoded

"Account kind" is not a field. **What a seat's money data means is decided from the usage
payload's shape, never from the plan string.** Besides email and organization id, the profile
decides only the plan string, prepaid eligibility, and one tie-break for a switched-off Team meter.

| Kind | Profile | Usage payload | Kvotar builds |
|---|---|---|---|
| Pro / Max | A plan boolean true | Both windows; `extra_usage`; `spend` as a disabled stub (`enabled: false`, `limit: null`) | Windows; self-serve credits from `extra_usage`; the prepaid wallet |
| Team | No boolean, no Enterprise signal | Both windows; `spend` active, or switched off with `out_of_credits`; `extra_usage` as a minor-unit mirror | Windows; organization credits from `spend`; no prepaid call |
| Enterprise (usage-based) | An Enterprise signal | Windows absent or `null`; `spend` active; `extra_usage` as a minor-unit mirror | Null windows; a monthly limit from `spend`; no credits; no prepaid call |

(Fixtures `profile.json`, `profile_max.json`, `profile_team.json`,
`profile_enterprise_usage_based.json`, `usage_spend_promax_disabled.json`,
`usage_team_windowed_spend_*.json`, `usage_enterprise_spend.json`)

Reason: plan strings vary more than any list the code can test
([PATTERNS.md](../../PATTERNS.md), naming conventions), and the one payload field once read as a
plan signal (`spend` means Enterprise) turned out to be on Pro and Max payloads too, as a stub.

### A token change is treated as a possible new account

A rotated token cannot be told from a different account. When the token differs from the one the
profile was last read for, the adapter clears the reset anchors, organization id, cached wallet and
its fetch time, prepaid eligibility, the prepaid latch and its log flag, and the Enterprise flag,
then reads the profile again. (`fetchQuotaSnapshot`, the token-transition block; test
`testTokenChangeReopensThePrepaidGate`) The plan and email are not cleared (Known gaps).

## Money fields: decoding only

`ExtraUsage` holds both **self-serve credits** (Pro/Max, from `extra_usage`) and **organization
credits** (Team, from `spend`, `managedByOrganization` true). `MonthlyLimit` holds an Enterprise
seat's monthly spend. What the app does with them is on
[credits and monthly limits](credits-and-monthly-limits.md).

### Which source wins

Decided **after** the profile call, so the arm that reads the profile is right on the first poll.

- **Active meter:** `spend` present, `spend.enabled` not `false`, and `spend.limit` an object.
- **Windowed seat:** `five_hour` or `seven_day` present (a not-started window counts).

| Arm | When | `ExtraUsage` | `MonthlyLimit` |
|---|---|---|---|
| Organization credits | Active meter, windowed seat | From `spend` | None |
| Organization credits, switched off | Windowed seat, no active meter, `spend.disabled_reason == "out_of_credits"`, profile said **not** Pro/Max | Off, no amounts | None |
| Self-serve and monthly | Everything else | From `extra_usage`; none if the meter is active | From `spend` when it maps |

(Tests `testWindowedSeatSpendMapsToOrgManagedCredits`, `testSwitchedOffTeamCreditsStayOrgManaged`,
`testSwitchedOffShapeNeedsANonProMaxProfile`, `testProMaxDisabledStubIsUnchangedUnderEveryProfile`,
`testEnterpriseSpendMapsToMonthlyLimit`)

Reasons:

- **An active meter suppresses `extra_usage`,** even when `spend`'s money objects are corrupt. On
  such seats `extra_usage` mirrors `spend` in minor units; read as decimal dollars it once showed a
  used amount a hundred times too large. (`testSpendCurrencyMismatchDropsMonthlyKeepsMirrorSuppressed`)
- **On a windowed seat the meter is credits, not a quota.** It pays for work past the plan limits.
  Only a window-less seat has its quota in `spend`.
- **The switched-off arm needs the profile.** About a day after an organization's cap is reached
  the meter switches off, a shape indistinguishable by its fields from the Pro/Max stub. With no
  profile answer the self-serve arm applies until a poll has one; the plan is never guessed.

### `extra_usage` (self-serve credits)

| Field | Decoded as |
|---|---|
| `is_enabled` | Required boolean (Known gaps) |
| `monthly_limit` | Integer, minor units (`2000` is 20.00) |
| `used_credits` | Major units, decoded as a number and converted to `Decimal` from its printed form |
| `utilization`, `currency`, `disabled_reason` | Passed through; `disabled_reason` is a free string |

Absent `extra_usage` gives no credits. `is_enabled: false` with every other field `null` is normal.
(`resolveExtraUsage`; tests `testExtraUsageEnabledShape`, `testExtraUsageDisabledAllNull`,
`testMissingExtraUsageObjectDecodesAsNil`)

**Last-observed credits.** While credits are on, the last non-zero `used_credits` is kept with the
five-hour reset it was seen in. If credits are switched off in that window, the reading carries the
kept value marked `usedCreditsIsCached`, never as live. It is dropped when the five-hour reset
changes or disappears. Reason: whether the endpoint keeps sending `used_credits` after switch-off
was never confirmed. Organization credits never use this rule; a member cannot switch them.
(`CreditsCache`; tests `testCase2CachedCreditsSurfacedThenInvalidatedOnReset`,
`testNullWindowInvalidatesCreditsCache`)

### `spend` → monthly limit (window-less seat)

Built only when `spend.enabled` is not `false`, `used.amount_minor`, `limit.amount_minor` and
`percent` are present, and `used` and `limit` share currency and exponent. Otherwise none, a
warning on a mismatch, never a failed poll. (`monthlyLimit(from:now:)`, `spendMoneyIsCoherent`;
tests `testEnterpriseSpendMapsToMonthlyLimit`, `testSpendDisabledBuildsNoMonthly`)

| `MonthlyLimit` field | From |
|---|---|
| Limit, used | `limit.amount_minor`, `used.amount_minor`, raw minor units |
| Remaining percent | 100 − `spend.percent`, kept exact |
| Unit | Money in `limit.currency` (else `USD`), `limit.exponent` (else 2) |
| Reset | Start of the next calendar month in UTC, computed on the Mac; source `derived_calendar_month_utc` |

The payload has no reset for this pool; the calendar-month cycle was checked against claude.ai's
own page, and the reset is never shown as payload data. Example (invented): used `2500`, limit
`10000`, exponent 2, percent 25 reads 25.00 of 100.00, 75 % remaining.

### `spend` → organization credits (windowed seat)

| `ExtraUsage` field | From |
|---|---|
| Enabled | `spend.enabled` not `false` |
| Monthly limit | `limit.amount_minor` (minor units), exponent beside it |
| Used credits | `used.amount_minor` ÷ 10^exponent, as `Decimal` |
| Utilization, disabled reason | `spend.percent`, `spend.disabled_reason` |
| Currency, exponent | `spend.limit` (exponent else 2; currency may be `nil`) |

Mismatched money objects give no credits and never fall back to the mirror. Switched off, there are
no amounts; currency and exponent come from `spend.used`. (`orgManagedExtraUsage`,
`orgSwitchedOffExtraUsage`; test `testWindowedSeatSpendMismatchDropsCredits`)

**Logged or decoded, never acted on:** `spend.severity` and `member_dashboard_available` go to the
poll log line only; `can_toggle` and `can_purchase_credits` are decoded and unread; `cap`,
`balance`, `auto_reload` and `disclaimer` are not decoded.

### The prepaid wallet

| Field | Decoded as |
|---|---|
| `amount` | Balance in minor units (`2500` is 25.00) |
| `auto_reload_settings` | Non-null means auto-reload is on; nothing inside is read |
| `currency` | Lenient: a bad shape becomes `nil`, the balance survives |

`amount` and `auto_reload_settings` are strict: a bad shape fails that call. The wallet carries its
own time (`asOf`, the fetch attempt). (`PrepaidCreditsResponse`, `fetchPrepaid`; tests
`testPrepaidSuccessFoldsWalletIntoSnapshot`, `testPrepaidCurrencyOfAnUnexpectedShapeDegradesToNil`)

- **Eligibility is the profile's two plan booleans.** Only `has_claude_pro` or `has_claude_max`
  allows the call; Team, Enterprise and an unanswered profile never call.
- **A 401 or 403 latches for the token.** From the next poll the reading carries no wallet until
  the token changes. An ineligible seat carries none either.
- **Any other failure keeps the last good wallet** and never touches the reading's health.
  (`testPrepaidFailureDoesNotBlockQuotaPoll`)

Why, how often, and the tests for the gate: [polling.md](polling.md), "Claude's secondary calls".

## Rejected alternatives

- **A separate model for monthly spend.** One `MonthlyLimit` with a unit keeps one formatter path.
- **Inferring money units from `extra_usage.decimal_places`.** `spend` is canonical; a heuristic on
  the mirror invites the next unit bug.
- **Reading `limits[]` for the two main windows.** Deferred; `five_hour` and `seven_day` stay.
- **Decoding the obfuscated fields.** Their meaning is unknown.
- **Calling the prepaid endpoint on every seat except Enterprise** (a deny-list). A Team seat got
  through and drew 403s; replaced by the Pro/Max allow-list.
- **Anthropic's admin or analytics APIs.** They need an admin-created key; Kvotar reuses the user's
  sign-in with no setup.

## Known gaps

| Gap | Today | Proposed |
|---|---|---|
| Scoped "not started" is accidental | Reads `not started` at 0 % with no reset, whether the reset was missing or malformed; no test. `selectLimit` (`DisplayFormatter+LimitSelection.swift`) and the `AdditionalRateLimit.primaryWindowSeconds` doc say Claude scoped limits have no width | Question 1: first tell a missing reset from a malformed one, then decide the display; fix both comments to match the decision |
| Team plan string not decoded | `planType(from:)` returns only `max`, `pro`, `enterprise` or nil; `organization_type == "claude_team"` is unread. The display (`planDisplayName`, `isOrganizationPlan`) and previews expect `team`. With no `subscriptionType` the badge reads `—` and the seat is not treated as an organization plan; a string containing `pro` or `max` would mislabel it | Map `claude_team` to `team` in `planType(from:)` after the booleans and Enterprise signals, tested on `profile_team.json` |
| The Enterprise mirror can reach the decimal path | On a window-less seat, if `spend` is present but not an active meter, **or failed to decode**, `extra_usage` is read as decimal dollars although it is in minor units. Not seen live; the bad-`spend` test has no `extra_usage` | On a window-less seat, read `extra_usage` only if `spend` decoded as a disabled stub; test with a mirror plus a bad `spend` |
| `extra_usage.is_enabled` is required | An `extra_usage` object without it fails the whole poll | Decode it as optional, or decode `extra_usage` leniently |
| One bad `limits[]` entry drops them all | The array decodes with one lenient step; a fractional `percent` in any entry removes every scoped limit, silently | Decode entries one by one; count bad ones in the existing log line |
| Scoped resets: no de-jitter, silent parse failure | `scopedLimits` parses raw; failure gives `nil` with no log | De-jitter keyed by name; log a failure. Low risk: readers use the 60 s tolerance |
| Unreadable reset at 0 % reads not started | Same shape as not started; the warning says "treating window as null" though the percent is kept | Fix the log text; tell a malformed reset from a missing one (as for scoped limits, Question 1) so a malformed one reads unknown |
| Cookies kept in memory | The ephemeral session accepts and returns host cookies until quit | If wanted: `httpShouldSetCookies = false`, `httpCookieAcceptPolicy = .never`, `urlCache = nil` |
| Plan and email survive a token change | Not cleared with the other per-token caches; a failed profile call keeps the previous account's plan | Clear them too |
| Money unit guessed | `monthlyLimit(from:)` falls back to `USD` and exponent 2; `orgManagedExtraUsage` falls back to exponent 2 and passes a missing currency as `nil`. Two missing currencies pass the coherence check | Build nothing when the currency is missing |
| Enterprise flag written, never read | `cachedIsEnterprise`; its comment says it drives the prepaid skip and badge | Remove it, or fix the comment |
| Stale code comments | Adapter type doc names `PollEngine` (it is `PollCoordinator`); `coldPollThreshold` cites a 300 s cadence (120 s); `ClaudeUsageResponse.limits` cites a private polling document; `QuotaSnapshot.primaryWindowSeconds` says `nil` on Claude (always 18,000); `HTTPFetcher` and the `ClaudeResponses` header say two endpoints (three); `ExtraUsageResponse.usedCredits` cites a nonexistent `decimalUsedCredits` (it is `decimal(from:)`) | Fix with the next change to each file |

## Code and tests

| What | Where |
|---|---|
| Calls, status, mapping, de-jitter, money arms, profile, prepaid | `Packages/ClaudeAdapter/Sources/ClaudeAdapter/ClaudeAccountAdapter.swift` |
| Response shapes | `Packages/ClaudeAdapter/Sources/ClaudeAdapter/ClaudeResponses.swift` |
| Fetch seam, headers, timeout | `Packages/ClaudeAdapter/Sources/ClaudeAdapter/Seams.swift`, `Packages/ClaudeAdapter/Sources/ClaudeAdapter/URLSessionFetcher.swift` |
| Reading fields | `Packages/KvotarCore/Sources/KvotarCore/Adapters/AccountAdapter.swift` |
| Tests | `Packages/ClaudeAdapter/Tests/ClaudeAdapterTests/ClaudeAccountAdapterTests.swift`, `Packages/ClaudeAdapter/Tests/ClaudeAdapterTests/NoRefreshNetworkSeamTests.swift` |
| Fixtures | `Packages/ClaudeAdapter/Tests/ClaudeAdapterTests/TestFixtures/` |

Checked against the code at 595b1b9 + STEP_266
