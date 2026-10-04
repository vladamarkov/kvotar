# STEP_267 — The notification rules are one public spec page

**refs:**
- [docs/spec/INDEX.md](../docs/spec/INDEX.md) — where this page goes; the shared rules it links.
- [docs/spec/quota-readings.md](../docs/spec/quota-readings.md), [docs/spec/state.md](../docs/spec/state.md), [docs/spec/display-semantics.md](../docs/spec/display-semantics.md), [docs/spec/polling.md](../docs/spec/polling.md) — the shared rules; link them, never restate them.
- [ARCHITECTURE.md](../ARCHITECTURE.md), [PATTERNS.md](../PATTERNS.md), [VISION.md](../VISION.md).
- Pages to link: [state.md](../docs/spec/state.md) (states, tiers, rank 5b, the two notice constants it hands here), [forecast.md](../docs/spec/forecast.md) (runway, pace inputs, `weeklyForNotifications`), [display-semantics.md](../docs/spec/display-semantics.md) (percent, clock, countdown, "resets"; its notification Known gaps), [first-run-window.md](../docs/spec/first-run-window.md) (screen 4, the four groups' defaults and keys), [menu-actions.md](../docs/spec/menu-actions.md) (Notify me submenu and hint copy), [app-lifecycle.md](../docs/spec/app-lifecycle.md) (the hidden menu-bar item notice; where Open Kvotar routes), [credits-and-monthly-limits.md](../docs/spec/credits-and-monthly-limits.md) (what spend control and money states mean), [local-usage.md](../docs/spec/local-usage.md) (off-machine and multi-surface signals), [capacity-learning.md](../docs/spec/capacity-learning.md) (the window-changed fact), [storage.md](../docs/spec/storage.md) (`notification_events` table, settings keys), [diagnostics.md](../docs/spec/diagnostics.md) (the authorization fact); `menu-bar.md` and `history.md` (this group).
- Code: `Packages/KvotarCore/Sources/KvotarCore/Notifications/` (`NotificationEngine.swift`, `NotificationTypes.swift`, `WeeklyLadder.swift`, `WindowFact.swift`), `Packages/KvotarCore/Sources/KvotarCore/Storage/SQLiteStore+Notifications.swift`, `QuotaSnapshot.weeklyForNotifications` in `Packages/KvotarCore/Sources/KvotarCore/Adapters/AccountAdapter.swift`; `App/UserNotificationPresenter.swift`, `App/NotificationFixture.swift`, the presenter wiring and authorization reads in `App/AppDelegate.swift`, the engine wiring and `NotificationSignal` in `App/PollCoordinator.swift`. Tests: `NotificationEngineTests`, `NotificationEngineLowAllowanceTests`, `NotificationGroupTests`, `WeeklyLadderTests`, `WeeklyLadderReplayFixtures`, `BlockEpisodeReplayTests`, `SQLiteStoreNotificationsTests`; `UserNotificationPresenterTests`, `NotificationFixtureTests`.

**Approval:** the maintainer, 2026-10-04. Documentation only; touches no
item on the [VISION.md](../VISION.md) approval list. A ruling the maintainer gives in review is
recorded on the page as a *Decided* entry when the code does not follow it yet.

**blocked_by:** none.

## Goal

A contributor changing when Kvotar sends a notification, what it says, or how it is delivered finds every event, its trigger and suppression rules, the weekly ladder, the caps and episodes, permission, delivery and every title and body — without re-deciding what a state, a tier or a pace input means.

## Contract

1. Write `docs/spec/notifications.md` describing what the code and tests do today, in the format of the
   existing spec pages: front matter `summary` and `read_when`; **Questions for owner** (or
   "None"); **Decided** if the maintainer ruled; **About this page**; the current rules with their
   reasons; rejected alternatives where they matter; **Known gaps** with a proposed fix per row;
   code and test pointers; last line `Checked against the code at <parent commit> + STEP_267`.
2. Link, never restate, a rule another page owns.
   - Owns which notifications Kvotar sends (eleven kinds today — the old records say six or nine), when each fires and is suppressed: both firing paths, arbitration, caps, cooldowns, block episodes, instance keys (`block_episode.*`, `nearly_spent.*`, `ladder.*`), the weekly ladder (50 → 25 → 10 → 0 % left, 15 on a seven-day primary), the low-allowance gate, the first-evaluation exemptions; the groups' effect inside the engine (a disabled group is dropped before arbitration and writes no row); when permission is requested and read; delivery (sound, Focus by standard delivery only, the one action, withdrawal at reset); every title and body.
   - Does not own: the hidden menu-bar item notice (app-lifecycle, launch-only — one line + link); the Notify me hint copy (menu-actions); group defaults and screen 4 (first-run-window); the table schema and retention (storage); what spend control, tiers, fast burn and off-machine burn mean (credits, state, local-usage); pace inputs (forecast); click routing (app-lifecycle); menu-bar reminders (`menu-bar.md`); the recommendation copy (`popover.md`).
   - State that History reads this page's `over_quota` rows for its Hard blocks (link `history.md`), so a switched-off Over quota group leaves History without blocks.
   - `KVOTAR_NOTIFICATION_FIXTURE` (Debug builds only) is the test aid for real banners without touching the database; document it.
   - Known disagreements to record, not settle: the never-built "opened from notification" highlight (link `popover.md`); the Claude fast-burn body has no subagent or off-machine variant; the Codex spend-control title and body differ from the old spec; countdowns print `45 min`; the project-name opt-out is a settings row with no UI; there is no Focus logic of Kvotar's own; `dismissed_at` means opened or dismissed. Time Sensitive delivery: deferred and absent (owner ruling) — say so; never describe it as planned.
3. `docs/spec/INDEX.md` lists the page under *Topic pages* with its code areas, and drops it from
   *Topics without a page yet*.

   - Terms: a *quota window* is the five-hour or weekly refill period only; the separate standalone window is the *app window* ([app-lifecycle.md](../docs/spec/app-lifecycle.md)). Monthly split labels are `This machine`, `Elsewhere`, `Not observed`; `offMachine` and `unattributed` are internal names only. Kvotar does not decode or store message, prompt or code content; it scans raw error-flagged lines for quota markers. Never name a release stage; never quote the balance in the fixture `prepaid_credits.json`; invented figures only.
   - Five term differences are open with the maintainer ("Spend control" as condition vs state; the popover title `ESTIMATED VALUE` vs `Est. token value`; History's whole dollars; "Organization plan"; `forecast_tier` vs `ForecastTier`). Where this page meets one, describe today's code and raise it under **Questions for owner**; do not settle it.
   - A group D page that has not landed is named by its bare file name in backticks (`x.md`).

## Proof

1. A different agent than the writer checked every factual claim against the code and tests; every
   unresolved finding is on the page.
2. Relative links and anchors resolve; `make check` passes.
3. A fresh agent with only this repository reaches the page from `AGENTS.md` through the index for
   a representative task.
4. No personal or account data, private paths or credential material on the page; invented figures only.

## Deliberately untouched

Other spec pages except `INDEX.md`, any app code, test fixtures.

## Definition of done

   - The proof items hold.
   - One commit, `STEP_267: …`, lands the page, the index change and this contract.
