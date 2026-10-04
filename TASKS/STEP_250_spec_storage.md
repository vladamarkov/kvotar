# STEP_250 — The database rules are one public spec page

**refs:**
- [docs/spec/INDEX.md](../docs/spec/INDEX.md) — where this page goes; the shared rules it links.
- [docs/spec/quota-readings.md](../docs/spec/quota-readings.md), [docs/spec/state.md](../docs/spec/state.md), [docs/spec/display-semantics.md](../docs/spec/display-semantics.md), [docs/spec/polling.md](../docs/spec/polling.md) — the shared rules; link them, never restate them.
- [ARCHITECTURE.md](../ARCHITECTURE.md), [PATTERNS.md](../PATTERNS.md), [VISION.md](../VISION.md).
- [docs/spec/diagnostics.md](../docs/spec/diagnostics.md) — owns the diagnostics tables; link it.
- Code: `Packages/KvotarCore/Sources/KvotarCore/Storage/`, `Packages/KvotarCore/Sources/KvotarCore/Lifecycle/RetentionScheduler.swift`, `Packages/KvotarCore/Sources/KvotarCore/Lifecycle/PIDLock.swift`, `Packages/KvotarCore/Sources/KvotarCore/Storage/LegacyDataMigrator.swift`; the migration tests.

**Approval:** the maintainer, 2026-10-04. Documentation only; touches no
item on the [VISION.md](../VISION.md) approval list. A ruling the maintainer gives in review is
recorded on the page as a *Decided* entry.

**blocked_by:** none.

## Goal

A contributor adding a table, a migration or a retention rule finds what the database holds and why, how long each kind of row lives, how migrations are numbered and pinned in tests, and which writers may touch the disk.

## Contract

1. Write `docs/spec/storage.md` describing what the code and tests do today, in the format of the
   existing spec pages: front matter `summary` and `read_when`; **Questions for owner** (or
   "None"); **Decided** if the maintainer ruled; **About this page**; the current rules with their
   reasons; rejected alternatives where they matter; **Known gaps** with a proposed fix per row;
   code and test pointers; last line `Checked against the code at <parent commit> + STEP_250`.
2. Link, never restate, a rule another page owns.
   - Diagnostics tables stay on `diagnostics.md`; poll tables are linked from `polling.md`; the launch restore from `quota-readings.md`.
   - State the migration-version rule a contributor must follow (the current version and the test files that pin it), read from the code.
   - The legacy AgentPilot import and lock are current behavior and stay.
3. `docs/spec/INDEX.md` lists the page under *Topic pages* with its code areas, and drops it from
   *Topics without a page yet*.

## Proof

1. A different agent than the writer checked every factual claim against the code and tests; every
   unresolved finding is on the page.
2. Relative links and anchors resolve; `make check` passes.
3. A fresh agent with only this repository reaches the page from `AGENTS.md` through the index for
   a representative task.
4. No personal or account data, private paths or credential material on the page.

## Deliberately untouched

The schema itself, retention values, any app code. Other spec pages except `INDEX.md`.

## Definition of done

   - The proof items hold.
   - One commit, `STEP_250: …`, lands the page, the index change and this contract.
