# STEP_268 — The menu-bar item is one public spec page

**refs:**
- [docs/spec/INDEX.md](../docs/spec/INDEX.md) — where this page goes; the shared rules it links.
- [docs/spec/quota-readings.md](../docs/spec/quota-readings.md), [docs/spec/state.md](../docs/spec/state.md), [docs/spec/display-semantics.md](../docs/spec/display-semantics.md), [docs/spec/polling.md](../docs/spec/polling.md) — the shared rules; link them, never restate them.
- [ARCHITECTURE.md](../ARCHITECTURE.md), [PATTERNS.md](../PATTERNS.md), [VISION.md](../VISION.md).
- Pages to link: [display-semantics.md](../docs/spec/display-semantics.md) (orientation, colours, unknown and stale forms, the spoken-string Known gap), [state.md](../docs/spec/state.md) (tiers, ranks, glyph hysteresis, Decided 1: a stale *Limit nearly spent* keeps red), [forecast.md](../docs/spec/forecast.md) (runway numbers), [credits-and-monthly-limits.md](../docs/spec/credits-and-monthly-limits.md) (money states, the monthly slot rule), [menu-actions.md](../docs/spec/menu-actions.md) (the display-mode submenu), [app-lifecycle.md](../docs/spec/app-lifecycle.md) (clicks, the hidden item, the open hook, the app window), [first-run-window.md](../docs/spec/first-run-window.md) (screen 3's strip), [storage.md](../docs/spec/storage.md) (settings rows, migration v21); `notifications.md`, `popover.md`, `explanations.md` (this group).
- Code: `Packages/KvotarUI/Sources/KvotarUI/Model/MenuBarDisplay.swift`, `Packages/KvotarUI/Sources/KvotarUI/Model/MenuBarWidth.swift`, `Packages/KvotarUI/Sources/KvotarUI/Model/MenuBarReminder.swift`, `Packages/KvotarUI/Sources/KvotarUI/Model/ReminderEpisode.swift`, `Packages/KvotarUI/Sources/KvotarUI/Views/MenuBarItemView.swift`, the menu-bar functions of `Packages/KvotarUI/Sources/KvotarUI/Model/DisplayFormatter.swift` (`toolMenuBar`, `staleMenuBar`, `loadingMenuBar`, `menuBarRender`, `reminderString`, `longLimitBlockShape`, `menuBarTimeSlot`, `moneyGlyphSymbol`, dormant `compactReset`), the reminder clock and acknowledgement in `Packages/KvotarUI/Sources/KvotarUI/ViewModel/AppViewModel.swift`, the status-item and width parts of `App/MenuBarController.swift` (not `contextMenu()`), migration `v21_retire_menu_bar_modes`. Tests: `MenuBarRenderTests`, `MenuBarWidthTests`, `MenuBarReminderTests`, `MenuBarMotionTests`, `MenuBarExhaustionAgreementTests`, `AppViewModelReminderScheduleTests`, `LongLimitSurfaceAgreementTests`, env-gated `MenuBarSnapshots`.

**Approval:** the maintainer, 2026-10-04. Documentation only; touches no
item on the [VISION.md](../VISION.md) approval list. A ruling the maintainer gives in review is
recorded on the page as a *Decided* entry when the code does not follow it yet.

**blocked_by:** none.

## Goal

A contributor changing what the menu-bar item shows finds the display modes and their stored setting, the per-tool string and its shapes, the runway slot gate, the money glyph's drawing, the width and motion, and the amber reminder's schedule, episode and acknowledgement — without re-deciding colours, tiers or runway numbers.

## Contract

1. Write `docs/spec/menu-bar.md` describing what the code and tests do today, in the format of the
   existing spec pages: front matter `summary` and `read_when`; **Questions for owner** (or
   "None"); **Decided** if the maintainer ruled; **About this page**; the current rules with their
   reasons; rejected alternatives where they matter; **Known gaps** with a proposed fix per row;
   code and test pointers; last line `Checked against the code at <parent commit> + STEP_268`.
2. Link, never restate, a rule another page owns.
   - Owns the three display modes and `menu_bar_display_mode` (default, migration v21's rewrite, the empty item for an undetected single tool), the per-tool string in its shapes (steady, amber reminder, the held red shape for a blocked or nearly spent long limit), the under-60-minute runway slot gate, how the money glyph is drawn (position, colour, symbol set, width), the width reservation and the motion, and the amber reminder (7 s, 60 s → 10 min → hourly, never in red, `reminder_episode.<tool>.<limit>`, silenced by opening the popover or the app window).
   - Does not own: the mode submenu (menu-actions), clicks and the hidden item (app-lifecycle), MoneyState meaning and the monthly slot rule (credits), tiers (state), colours (display-semantics), runway numbers (forecast), the delta line's reading of the mode (`explanations.md`), the single-tool tab pin (`popover.md`).
   - Name the stale bar's consequence of state.md Decided 1 by linking it; do not re-rule it.
   - A constants table with the code's values; whether they are final stays a Question for owner.
   - Known gaps to consider: stale code comments (five-second reminder, three pulses, the deleted gauge, "quota window" for the app window), the money glyph dropped while stale, an unverified edge (a long block with no five-hour percent), dormant `compactReset`.
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
   - One commit, `STEP_268: …`, lands the page, the index change and this contract.
