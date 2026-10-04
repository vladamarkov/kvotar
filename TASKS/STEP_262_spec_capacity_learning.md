# STEP_262 — The capacity-learning rules are one public spec page

**refs:**
- [docs/spec/INDEX.md](../docs/spec/INDEX.md) — where this page goes; the shared rules it links.
- [docs/spec/quota-readings.md](../docs/spec/quota-readings.md), [docs/spec/state.md](../docs/spec/state.md), [docs/spec/display-semantics.md](../docs/spec/display-semantics.md), [docs/spec/polling.md](../docs/spec/polling.md) — the shared rules; link them, never restate them.
- [ARCHITECTURE.md](../ARCHITECTURE.md), [PATTERNS.md](../PATTERNS.md), [VISION.md](../VISION.md).
- Pages to link: [docs/spec/polling.md](../docs/spec/polling.md) (a refused poll versus a quota 429, and when a quota 429 is recorded), [docs/spec/storage.md](../docs/spec/storage.md) (`quota_limit_events`), [docs/spec/quota-readings.md](../docs/spec/quota-readings.md), [docs/spec/codex-account.md](../docs/spec/codex-account.md) (its note that `LimitsDatabaseAdapter` has no runtime caller), `forecast.md` (this group).
- Code: `Packages/KvotarCore/Sources/KvotarCore/Limits/LimitsDatabaseAdapter.swift`, `Packages/KvotarCore/Sources/KvotarCore/Limits/LimitsModels.swift`, `Packages/KvotarCore/Sources/KvotarCore/Storage/SQLiteStore+QuotaLimitEvents.swift`, `writeQuota429Events` in `App/PollCoordinator.swift`, `LocalDeltaSignal.quota429Observations` in `Packages/KvotarCore/Sources/KvotarCore/Adapters/LocalAdapter.swift`, `Packages/KvotarCore/Sources/KvotarCore/History/WorkPerPercentSeries.swift` and its caller in `Packages/KvotarCore/Sources/KvotarCore/History/HistoryReportReader.swift`; `LimitsDatabaseAdapterTests`, `SQLiteStoreQuotaLimitEventsTests`, `WorkPerPercentSeriesTests`.

**Approval:** the maintainer, 2026-10-04. Documentation only; touches no
item on the [VISION.md](../VISION.md) approval list. A ruling the maintainer gives in review is
recorded on the page as a *Decided* entry when the code does not follow it yet.

**blocked_by:** none.

## Goal

A contributor touching the community limit table, the quota 429s seen in session logs, the personal observed ceiling or the work-per-1% series finds what each one is for, what the app actually uses today, and what is built but not wired.

## Contract

1. Write `docs/spec/capacity-learning.md` describing what the code and tests do today, in the format of the
   existing spec pages: front matter `summary` and `read_when`; **Questions for owner** (or
   "None"); **Decided** if the maintainer ruled; **About this page**; the current rules with their
   reasons; rejected alternatives where they matter; **Known gaps** with a proposed fix per row;
   code and test pointers; last line `Checked against the code at <parent commit> + STEP_262`.
2. Link, never restate, a rule another page owns.
   - Owns: what the community table and the personal ceiling are, what a `quota_limit_events` row is for (polling owns *when* it is written and *where*), the 50 % observation floor, and the work-per-1% series (its computation; the History chart is `history.md`'s, pending).
   - **Describe today's code: verified at the base, nothing in the app calls `LimitsDatabaseAdapter` at runtime** (`AppDelegate` says the seed load was removed with the retired Inferred-runway ceiling) **and nothing reads `quota_limit_events` back** (`readQuotaLimitUtilizations` has no caller outside tests). Quota 429 rows are written and never used. Say so plainly; do not describe the ceiling as live.
   - polling.md's table says a quota 429 "feeds the learned ceiling": wrong today. Record it as a Known gap here naming the exact correction for a follow-up step; polling.md is not edited in this step. Describe the feature as dormant (keep, wire or remove is decided later).
3. `docs/spec/INDEX.md` lists the page under *Topic pages* with its code areas, and drops it from
   *Topics without a page yet*.

   - Terms: a *quota window* is the five-hour or weekly refill period; the separate UI surface is an *app window* (the standalone quota display window belongs to group B). Pending links on published pages are updated in a separate step after group C lands, not in this step's commit.

## Proof

1. A different agent than the writer checked every factual claim against the code and tests; every
   unresolved finding is on the page.
2. Relative links and anchors resolve; `make check` passes.
3. A fresh agent with only this repository reaches the page from `AGENTS.md` through the index for
   a representative task.
4. No personal or account data, private paths or credential material on the page; invented figures only.

## Deliberately untouched

Other spec pages (including polling.md's wording), any app code, the History chart. Other spec pages except `INDEX.md`.

## Definition of done

   - The proof items hold.
   - One commit, `STEP_262: …`, lands the page, the index change and this contract.
