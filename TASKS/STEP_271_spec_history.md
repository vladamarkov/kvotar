# STEP_271 — The History window is one public spec page

**refs:**
- [docs/spec/INDEX.md](../docs/spec/INDEX.md) — where this page goes; the shared rules it links.
- [docs/spec/quota-readings.md](../docs/spec/quota-readings.md), [docs/spec/state.md](../docs/spec/state.md), [docs/spec/display-semantics.md](../docs/spec/display-semantics.md), [docs/spec/polling.md](../docs/spec/polling.md) — the shared rules; link them, never restate them.
- [ARCHITECTURE.md](../ARCHITECTURE.md), [PATTERNS.md](../PATTERNS.md), [VISION.md](../VISION.md).
- Pages to link: [display-semantics.md](../docs/spec/display-semantics.md) (the History `% used` exception, HistoryTheme), [capacity-learning.md](../docs/spec/capacity-learning.md) (work-per-1% series math), [estimated-value.md](../docs/spec/estimated-value.md) (pricing, the `≈` mark, the not-a-bill line), [local-usage.md](../docs/spec/local-usage.md) (token counting, project grouping), [forecast.md](../docs/spec/forecast.md) (shadow tables read the fold), [state.md](../docs/spec/state.md) (critical states, Hard block), [storage.md](../docs/spec/storage.md) (tables and retention), [menu-actions.md](../docs/spec/menu-actions.md) (the History… item), [app-lifecycle.md](../docs/spec/app-lifecycle.md) (a footer link closes the app window first); `notifications.md`, `popover.md`, `explanations.md` (this group).
- Code: `Packages/KvotarCore/Sources/KvotarCore/History/HistoryReport.swift`, `Packages/KvotarCore/Sources/KvotarCore/History/HistoryReportReader.swift`, `Packages/KvotarCore/Sources/KvotarCore/History/QuotaWindowOutcomes.swift`, `Packages/KvotarCore/Sources/KvotarCore/Storage/SQLiteStore+History.swift`; `Packages/KvotarUI/Sources/KvotarUI/Model/HistoryExperience.swift`, `Packages/KvotarUI/Sources/KvotarUI/Model/HistoryDisplay.swift`, `HistoryDisplay+Experience.swift`, `HistoryDisplay+Recap.swift`, `HistoryDisplay+Quota.swift`, `Packages/KvotarUI/Sources/KvotarUI/Model/HistoryWeeks.swift`, `Packages/KvotarUI/Sources/KvotarUI/Model/HistoryDestination.swift`, `Packages/KvotarUI/Sources/KvotarUI/ViewModel/HistoryViewModel.swift`, `Packages/KvotarUI/Sources/KvotarUI/Views/History/`; `App/HistoryWindowController.swift`. Tests: `HistoryReportReaderTests`, `HistoryReportWeeklyLimitsTests`, `QuotaWindowOutcomesTests`, `HistoryExperience*Tests`, `HistoryDayHoverTests`, `HistoryWeeksTests`, `HistoryViewModel*Tests`; env-gated `HistoryExperienceSnapshots` and `HistoryExperienceLiveDiagnostics` (point them at a copy of the database, never the live file).

**Approval:** the maintainer, 2026-10-04. Documentation only; touches no
item on the [VISION.md](../VISION.md) approval list. A ruling the maintainer gives in review is
recorded on the page as a *Decided* entry when the code does not follow it yet.

**blocked_by:** none.

## Goal

A contributor changing the History window finds how it opens and lives, its four modes with their copy and evidence rules, the 30-day report it reads, and the window-outcome fold — without re-deciding token counting, pricing or the work-per-1% math.

## Contract

1. Write `docs/spec/history.md` describing what the code and tests do today, in the format of the
   existing spec pages: front matter `summary` and `read_when`; **Questions for owner** (or
   "None"); **Decided** if the maintainer ruled; **About this page**; the current rules with their
   reasons; rejected alternatives where they matter; **Known gaps** with a proposed fix per row;
   code and test pointers; last line `Checked against the code at <parent commit> + STEP_271`.
2. Link, never restate, a rule another page owns.
   - Owns the History window's lifecycle (`HistoryWindowController`: one lazy window, stays an accessory app, close hides, reload on open and focus, frame autosave) — app-lifecycle owns only the app window, so nobody else claims it; typed `HistoryDestination` arrivals; the four modes (Weekly recap, Explore quota, Explore usage, Hard blocks) with their copy and evidence rules; the 30-day report; the window-outcome fold (`QuotaWindowOutcomes`, `WeeklyLimitOutcome`), which forecast's shadow tables also read; the work-per-1% display gate in the UI (the series is capacity-learning's).
   - State that Hard blocks read `notification_events` `over_quota` rows (link `notifications.md`): turning off Over quota notifications leaves Hard blocks empty — state it plainly (owner ruling). Raise "Should History keep an independent record of blocks?" as a Question for owner, never a Decided entry.
   - Name the two near-twins plainly: History's *Weekly recap* vs the popover's idle recap; History's window outcome vs the popover's "Last window ended" line (`explanations.md`).
   - Known disagreements: the coverage note says weekly-only exhaustion may not appear (state now treats a spent weekly as Over quota); a block's lockout uses the five-hour reset only (unverified — needs a fixture before it is called wrong); comments still say History opens on "Summary · All"; dead `HistoryDisplay` helpers; the window lifecycle has no test.
   - Open term mismatch: the recap's whole dollars and the `$9 – $13 of work per 1%` form are not on display-semantics — describe, raise, don't settle.
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
   - One commit, `STEP_271: …`, lands the page, the index change and this contract.
