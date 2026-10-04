# STEP_269 — The popover frame is one public spec page

**refs:**
- [docs/spec/INDEX.md](../docs/spec/INDEX.md) — where this page goes; the shared rules it links.
- [docs/spec/quota-readings.md](../docs/spec/quota-readings.md), [docs/spec/state.md](../docs/spec/state.md), [docs/spec/display-semantics.md](../docs/spec/display-semantics.md), [docs/spec/polling.md](../docs/spec/polling.md) — the shared rules; link them, never restate them.
- [ARCHITECTURE.md](../ARCHITECTURE.md), [PATTERNS.md](../PATTERNS.md), [VISION.md](../VISION.md).
- Pages to link: [display-semantics.md](../docs/spec/display-semantics.md), [state.md](../docs/spec/state.md) (tab dot), [forecast.md](../docs/spec/forecast.md), [credits-and-monthly-limits.md](../docs/spec/credits-and-monthly-limits.md) (card, Codex section, monthly content), [local-usage.md](../docs/spec/local-usage.md) (local figures, Today report), [estimated-value.md](../docs/spec/estimated-value.md) (value rows), [app-lifecycle.md](../docs/spec/app-lifecycle.md) (popover and app window lifecycle, routing), [menu-actions.md](../docs/spec/menu-actions.md) (the `⋯` twin, the setup card's menu item), [first-run-window.md](../docs/spec/first-run-window.md), [product-scope.md](../docs/spec/product-scope.md) (Decided 1: no footer, no Settings window); `account-summary.md` (STEP_272), `explanations.md`, `history.md`, `menu-bar.md`, `notifications.md` (this group).
- Code: `Packages/KvotarUI/Sources/KvotarUI/Views/PopoverView.swift`, `Packages/KvotarUI/Sources/KvotarUI/Views/ClaudePopoverContent.swift`, `Packages/KvotarUI/Sources/KvotarUI/Views/CodexPopoverContent.swift`, `Packages/KvotarUI/Sources/KvotarUI/Model/PopoverViewport.swift`, `App/PopoverHeightOverride.swift`, `Packages/KvotarUI/Sources/KvotarUI/Views/StatusCards.swift`, `Packages/KvotarUI/Sources/KvotarUI/Views/WelcomeView.swift`, `Packages/KvotarUI/Sources/KvotarUI/Views/Components.swift`, `Packages/KvotarUI/Sources/KvotarUI/Views/Theme.swift`, `Packages/KvotarUI/Sources/KvotarUI/Views/Sections/RecommendationSectionView.swift` and `DisplayFormatter.recommendation`, `Packages/KvotarUI/Sources/KvotarUI/Views/Sections/LocalActivitySectionView.swift`, `Packages/KvotarUI/Sources/KvotarUI/Model/LocalActivitySection.swift`, `Packages/KvotarUI/Sources/KvotarUI/Model/DisplayFormatter+LocalActivity.swift`, the slots of `CreditsCardSectionView` / `CreditsSpendSectionView`, `PopoverPhase` and the two display states in `Packages/KvotarUI/Sources/KvotarUI/Model/PopoverDisplay.swift`, the default-tab code in `Packages/KvotarUI/Sources/KvotarUI/ViewModel/AppViewModel.swift`. Tests: `AppViewModelTests` (default tab, detected tools), `PopoverViewportTests`, `AppViewModelViewportTests`, `DisplayFormatterLocalActivityTests`, `ThemeContrastTests`, the recommendation tests in `DisplayFormatterTests`, env-gated `PopoverCompositionSnapshots`.

**Approval:** the maintainer, 2026-10-04. Documentation only; touches no
item on the [VISION.md](../VISION.md) approval list. A ruling the maintainer gives in review is
recorded on the page as a *Decided* entry when the code does not follow it yet.

**blocked_by:** none.

## Goal

A contributor changing how the popover (and so the app window) is laid out finds the phases and their cards, the tabs and the default tab, the section order, sizing and scrolling, the recommendation, the Codex notes card, the local-activity layout and the slots for the credits sections — without re-deciding the content those sections show.

## Contract

1. Write `docs/spec/popover.md` describing what the code and tests do today, in the format of the
   existing spec pages: front matter `summary` and `read_when`; **Questions for owner** (or
   "None"); **Decided** if the maintainer ruled; **About this page**; the current rules with their
   reasons; rejected alternatives where they matter; **Known gaps** with a proposed fix per row;
   code and test pointers; last line `Checked against the code at <parent commit> + STEP_269`.
2. Link, never restate, a rule another page owns.
   - **Split (owner ruling):** this page is the frame; `account-summary.md` (STEP_272) takes the header and OTHER LIMITS, which share one value (`AccountLimitSelection`) built once per render and meet the rest only through two optional fields. Say this seam on the page and link `account-summary.md` for everything above OTHER LIMITS' last row.
   - Owns: one view for popover and app window (width 340); phases (loading, idle, setup card, welcome); tabs (detected tools only, dot, name) and the default tab (urgency → recent local activity → Claude; the remembered manual pick within a session; the single-tool display mode pin); the section order as the code builds it (delta line row 0 → header → Codex notes card → recommendation → OTHER LIMITS → local activity → value → credits slot → History footer); the one scroll body and the height budget; the recommendation (gate, copy, link labels); the Codex notes card; local-activity titles, empty and unavailable strings; palette tokens; the History footer and `N more projects ›` links.
   - Does not own: content of the credits sections, local figures, value rows (group C pages); hover cards, anatomy, delta line (`explanations.md`); the History window and destinations (`history.md`); app window and popover lifecycle (app-lifecycle). The footer (gear, pause, Quit) and a Settings window never shipped — product-scope Decided 1; never name a release stage.
   - Record the "opened from notification" highlight as never built (notifications links here). Notifications must link this page for the recommendation copy, not restate it.
   - Known disagreements: the default tab remembers the pick (the record says not kept); the always-show rule no longer holds; the History footer says `last 30 days` but opens the Weekly recap; the Codex notes card's position; dead builders (`quotaRows`, `offMachineLive`, `windowAccountingRows`, `modelRows`) still in code and tests.
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
   - One commit, `STEP_269: …`, lands the page, the index change and this contract.
