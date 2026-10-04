# STEP_258 — Launch, second opening and quit are one public spec page

**refs:**
- [docs/spec/INDEX.md](../docs/spec/INDEX.md) — where this page goes; the shared rules it links.
- [docs/spec/quota-readings.md](../docs/spec/quota-readings.md), [docs/spec/state.md](../docs/spec/state.md), [docs/spec/display-semantics.md](../docs/spec/display-semantics.md), [docs/spec/polling.md](../docs/spec/polling.md) — the shared rules; link them, never restate them.
- [ARCHITECTURE.md](../ARCHITECTURE.md), [PATTERNS.md](../PATTERNS.md), [VISION.md](../VISION.md).
- [docs/spec/storage.md](../docs/spec/storage.md) — *The single-instance lock* and its Decided 1 and 2; link them, never restate them.
- [docs/spec/polling.md](../docs/spec/polling.md#known-gaps) — the "polls" wording in the already-running copy is its Known gap; link that row.
- [docs/spec/first-run-window.md](../docs/spec/first-run-window.md), [docs/spec/diagnostics.md](../docs/spec/diagnostics.md) (`app_lifecycle_events`).
- Code: `App/AppDelegate.swift`, `App/LaunchSource.swift`, `App/SecondInstanceAction.swift`, `App/HandoffInbox.swift`, `App/HiddenItemMonitor.swift`, `App/HiddenItemDetection.swift`, `App/QuotaSurfaceLifecycle.swift`, `App/QuotaSurfacePresenter.swift`, `App/QuotaWindowController.swift`, `Packages/KvotarUI/Sources/KvotarUI/Views/AlreadyRunningView.swift`; tests in `AppTests/` (`LaunchSourceTests`, `SecondInstanceActionTests`, `HandoffInboxTests`, `HiddenItemDetectionTests`, `QuotaSurfacePresenterTests`) and `AlreadyRunningViewTests`.

**Approval:** the maintainer, 2026-10-04. Documentation only; touches no
item on the [VISION.md](../VISION.md) approval list. A ruling the maintainer gives in review is
recorded on the page as a *Decided* entry.

**blocked_by:** none.

## Goal

A contributor changing what happens at launch, when Kvotar is opened again while running, when the menu-bar item is hidden, or at quit finds the order of launch work, every second-opening path and its copy, the hidden-item detection and its notice, and what quit releases.

## Contract

1. Write `docs/spec/app-lifecycle.md` describing what the code and tests do today, in the format of the
   existing spec pages: front matter `summary` and `read_when`; **Questions for owner** (or
   "None"); **Decided** if the maintainer ruled; **About this page**; the current rules with their
   reasons; rejected alternatives where they matter; **Known gaps** with a proposed fix per row;
   code and test pointers; last line `Checked against the code at <parent commit> + STEP_258`.
2. Link, never restate, a rule another page owns.
   - The page owns launch order, launch source (opened by the user or at login), reopen while running, a second copy's hand-off, the AgentPilot conflict window, hidden menu-bar item detection and its notice, when the app window opens and closes, and quit.
   - The lock and its two Decided rulings are [storage](../docs/spec/storage.md)'s: link them; describe only what the user sees today. The legacy AgentPilot lock and its message are current behaviour and stay.
   - The "polls" wording in the conflict copy is a Known gap on [polling](../docs/spec/polling.md#known-gaps): link that row, do not open a second one. Launch polls are polling's.
   - The first-run checkbox is [first-run window](../docs/spec/first-run-window.md)'s and the menu item `menu-actions.md`'s (STEP_257); this page owns how a login launch behaves.
   - "Quota window" means only the five-hour or weekly refill period. The separate window that shows the quota (`QuotaWindowController`, opened by **Open in Window**) is the **app window**. Monthly labels, if mentioned, are "This machine", "Elsewhere", "Not observed"; `offMachine` and `unattributed` are internal names.
3. `docs/spec/INDEX.md` lists the page under *Topic pages* with its code areas, and drops it from
   *Topics without a page yet*.

## Proof

1. A different agent than the writer checked every factual claim against the code and tests; every
   unresolved finding is on the page.
2. Relative links and anchors resolve; `make check` passes.
3. A fresh agent with only this repository reaches the page from `AGENTS.md` through the index for
   a representative task: "opening Kvotar from Finder while it runs should show the quota".
4. No personal or account data, private paths or credential material on the page.

## Deliberately untouched

Any app code. Other spec pages except `INDEX.md`.

## Definition of done

   - The proof items hold.
   - One commit, `STEP_258: …`, lands the page, the index change and this contract.
