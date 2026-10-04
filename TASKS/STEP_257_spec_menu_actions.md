# STEP_257 — The right-click menu is one public spec page

**refs:**
- [docs/spec/INDEX.md](../docs/spec/INDEX.md) — where this page goes; the shared rules it links.
- [docs/spec/quota-readings.md](../docs/spec/quota-readings.md), [docs/spec/state.md](../docs/spec/state.md), [docs/spec/display-semantics.md](../docs/spec/display-semantics.md), [docs/spec/polling.md](../docs/spec/polling.md) — the shared rules; link them, never restate them.
- [ARCHITECTURE.md](../ARCHITECTURE.md), [PATTERNS.md](../PATTERNS.md), [VISION.md](../VISION.md).
- [docs/spec/product-scope.md](../docs/spec/product-scope.md) — Decided 1: settings live in this menu; a separate Settings window is planned future work with no release target. Link it.
- [docs/spec/first-run-window.md](../docs/spec/first-run-window.md), [docs/spec/diagnostics.md](../docs/spec/diagnostics.md) — own the behaviour behind several items; link them.
- Code: `App/MenuBarController.swift` (`contextMenu()` and its actions), `App/NotificationPermissionHint.swift`, `Packages/KvotarCore/Sources/KvotarCore/ProductIdentity.swift`; test `AppTests/NotificationPermissionHintTests.swift`.

**Approval:** the maintainer, 2026-10-04. Documentation only; touches no
item on the [VISION.md](../VISION.md) approval list. A ruling the maintainer gives in review is
recorded on the page as a *Decided* entry.

**blocked_by:** none.

## Goal

A contributor adding, renaming, reordering or hiding a right-click menu item finds the menu's order and copy, when each item shows or is greyed, what each action calls, and which page owns the behaviour behind it.

## Contract

1. Write `docs/spec/menu-actions.md` describing what the code and tests do today, in the format of the
   existing spec pages: front matter `summary` and `read_when`; **Questions for owner** (or
   "None"); **Decided** if the maintainer ruled; **About this page**; the current rules with their
   reasons; rejected alternatives where they matter; **Known gaps** with a proposed fix per row;
   code and test pointers; last line `Checked against the code at <parent commit> + STEP_257`.
2. Link, never restate, a rule another page owns.
   - The page owns the menu: both ways to open it (right-click on the status item, the `⋯` button in the app window), order, copy, when each item shows or is greyed, the caption row, the About panel's contents, Quit as an item, the **Open at Login** item and the Notify me permission hints.
   - Settings available today live in this menu; link product-scope Decided 1 for the planned Settings window. Name no release stage.
   - The behaviour behind items is linked: display modes `menu-bar.md` (pending); Notify me: only the permission-hint copy is owned here; the switch defaults are [first-run window](../docs/spec/first-run-window.md)'s, the permission and events `notifications.md`'s (pending); Set up and Welcome [first-run window](../docs/spec/first-run-window.md); Open in Window and quit `app-lifecycle.md` (STEP_258); History… `history.md` (pending); diagnostics items [diagnostics](../docs/spec/diagnostics.md); update items `updates-and-releases.md` (STEP_260).
   - "Quota window" means only the five-hour or weekly refill period. The separate window that shows the quota (`QuotaWindowController`, opened by **Open in Window**) is the **app window**. Monthly labels, if mentioned, are "This machine", "Elsewhere", "Not observed"; `offMachine` and `unattributed` are internal names.
   - Nothing tests the menu's build directly: a Known-gaps row with a proposed test.
3. `docs/spec/INDEX.md` lists the page under *Topic pages* with its code areas, and drops it from
   *Topics without a page yet*.

## Proof

1. A different agent than the writer checked every factual claim against the code and tests; every
   unresolved finding is on the page.
2. Relative links and anchors resolve; `make check` passes.
3. A fresh agent with only this repository reaches the page from `AGENTS.md` through the index for
   a representative task: "add an item to the right-click menu".
4. No personal or account data, private paths or credential material on the page.

## Deliberately untouched

Any app code. The Settings window decision. Other spec pages except `INDEX.md`.

## Definition of done

   - The proof items hold.
   - One commit, `STEP_257: …`, lands the page, the index change and this contract.
