# STEP_270 — The explanation layer is one public spec page

**refs:**
- [docs/spec/INDEX.md](../docs/spec/INDEX.md) — where this page goes; the shared rules it links.
- [docs/spec/quota-readings.md](../docs/spec/quota-readings.md), [docs/spec/state.md](../docs/spec/state.md), [docs/spec/display-semantics.md](../docs/spec/display-semantics.md), [docs/spec/polling.md](../docs/spec/polling.md) — the shared rules; link them, never restate them.
- [ARCHITECTURE.md](../ARCHITECTURE.md), [PATTERNS.md](../PATTERNS.md), [VISION.md](../VISION.md).
- Pages to link: [display-semantics.md](../docs/spec/display-semantics.md) (the used-bridge line's orientation, the copy rule), [credits-and-monthly-limits.md](../docs/spec/credits-and-monthly-limits.md) (Decided 1: the dead split cards — link, never re-rule), [estimated-value.md](../docs/spec/estimated-value.md) (its E-13 Known gap), [local-usage.md](../docs/spec/local-usage.md), [forecast.md](../docs/spec/forecast.md), [state.md](../docs/spec/state.md) (the 90 % line), [product-scope.md](../docs/spec/product-scope.md) (the `off-machine` delta-token Known gap), [storage.md](../docs/spec/storage.md) (`last_open_snapshot_<tool>`), [diagnostics.md](../docs/spec/diagnostics.md) (`explanation-snapshot.json`), [app-lifecycle.md](../docs/spec/app-lifecycle.md) (open, close, Esc hooks), [first-run-window.md](../docs/spec/first-run-window.md); `popover.md`, `account-summary.md`, `menu-bar.md`, `history.md` (this group).
- Code: `Packages/KvotarUI/Sources/KvotarUI/Model/ExplanationRegistry.swift`, `Packages/KvotarUI/Sources/KvotarUI/Views/ExplanationLayer.swift`, `Packages/KvotarUI/Sources/KvotarUI/ViewModel/AppViewModel+ExplanationLayer.swift`, `Packages/KvotarUI/Sources/KvotarUI/Model/ExplanationTiming.swift`, `Packages/KvotarUI/Sources/KvotarUI/Model/DisplayFormatter+Anatomy.swift`, the anatomy types in `Packages/KvotarUI/Sources/KvotarUI/Model/PopoverDisplay.swift`, the anatomy peek/pin and `VerdictAnatomyView` in `Packages/KvotarUI/Sources/KvotarUI/Views/Sections/HeaderSectionView.swift`, the pin state in `Packages/KvotarUI/Sources/KvotarUI/ViewModel/AppViewModel.swift`, `Packages/KvotarUI/Sources/KvotarUI/Model/DeltaLine.swift`, `Packages/KvotarUI/Sources/KvotarUI/ViewModel/AppViewModel+DeltaLine.swift`, `Packages/KvotarUI/Sources/KvotarUI/Views/DeltaLineView.swift`, the snapshot walker `Packages/KvotarUI/Sources/KvotarUI/ViewModel/AppViewModel+ExplanationSnapshot.swift`. Tests: `ExplanationRegistryTests` and its fixture `Packages/KvotarUI/Tests/KvotarUITests/Fixtures/explanation_registry.md`, `DisplayFormatterAnatomyTests`, `DeltaLineTests`, `AppViewModelDeltaLineTests`, `AppViewModelExplanationSnapshotTests`, live `ExplanationLiveDiagnostics`.

**Approval:** the maintainer, 2026-10-04. Documentation only; touches no
item on the [VISION.md](../VISION.md) approval list. A ruling the maintainer gives in review is
recorded on the page as a *Decided* entry when the code does not follow it yet.

**blocked_by:** none.

## Goal

A contributor changing a hover card, the verdict anatomy or the "Since you last looked" line finds every element, its copy and live lines, the gesture rules, which verdicts open the anatomy and what it shows, and when the delta line speaks — without re-deciding which rows exist or what the numbers mean.

## Contract

1. Write `docs/spec/explanations.md` describing what the code and tests do today, in the format of the
   existing spec pages: front matter `summary` and `read_when`; **Questions for owner** (or
   "None"); **Decided** if the maintainer ruled; **About this page**; the current rules with their
   reasons; rejected alternatives where they matter; **Known gaps** with a proposed fix per row;
   code and test pointers; last line `Checked against the code at <parent commit> + STEP_270`.
2. Link, never restate, a rule another page owns.
   - Owns every hover card (element IDs, the copy table, live lines, the used-bridge template, the source-tag card, the two header-fact cards built outside the table), the gesture rules (peek 600 ms, pin, grace, settle, one card at a time, overlay placement), the verdict anatomy (which verdicts open it, rows, comparison, flip line) and the delta line (snapshot, gate, tokens, boundary form, the two silent sets).
   - The page carries the copy table, each `| **E-` row byte-identical to the test fixture today. Say how `ExplanationRegistryTests` reads the fixture and that its check against the old private spec is skipped in this repository. Pointing the test at the page is a later step (owner ruling) — at most a Known-gaps row, not a Question.
   - Credits Decided 1 covers E-18 / E-19 body / E-20: link it. The other dead text (E-05, E-07 and its live rows, E-21) is a Known gap, not a ruling.
   - Describe anatomy shape B as the code builds it (the 90 % line, opened only by the weekly-block `Stopped` verdict). Coach marks were built and then removed; no code remains (owner ruling) — describe them so, never imply they return.
   - Does not own: which rows exist and the verdict words (`popover.md` / `account-summary.md`), what numbers mean (group C pages, state), the bundle file (diagnostics), when surfaces open or close (app-lifecycle), the window outcome fold (`history.md`).
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
   - One commit, `STEP_270: …`, lands the page, the index change and this contract.
