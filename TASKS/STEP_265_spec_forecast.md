# STEP_265 — The forecast rules are one public spec page

**refs:**
- [docs/spec/INDEX.md](../docs/spec/INDEX.md) — where this page goes; the shared rules it links.
- [docs/spec/quota-readings.md](../docs/spec/quota-readings.md), [docs/spec/state.md](../docs/spec/state.md), [docs/spec/display-semantics.md](../docs/spec/display-semantics.md), [docs/spec/polling.md](../docs/spec/polling.md) — the shared rules; link them, never restate them.
- [ARCHITECTURE.md](../ARCHITECTURE.md), [PATTERNS.md](../PATTERNS.md), [VISION.md](../VISION.md).
- Pages to link: [docs/spec/state.md](../docs/spec/state.md) (states, the long-limit tiers, the pace gate's use; it already defers the pace clock here), [docs/spec/quota-readings.md](../docs/spec/quota-readings.md), [docs/spec/polling.md](../docs/spec/polling.md) (the burn-tier session-start trigger), [docs/spec/storage.md](../docs/spec/storage.md) (`forecast_log`), [docs/spec/display-semantics.md](../docs/spec/display-semantics.md), `capacity-learning.md` (this group).
- Code: `Packages/KvotarCore/Sources/KvotarCore/Forecast/Forecast.swift`, `ForecastEngine.swift`, `ForecastLogRecorder.swift`, `ShadowForecast.swift`, `ShadowPolicy.swift`, `ShadowTables.swift`, `ShadowTablesReader.swift`, `QuotaSnapshot.paceExceeded` in `Packages/KvotarCore/Sources/KvotarCore/Adapters/AccountAdapter.swift`, the forecast and shadow wiring in `App/PollCoordinator.swift`, `Packages/KvotarCore/Sources/KvotarCore/Storage/SQLiteStore+ForecastLog.swift`; `ForecastEngineTests`, `ShadowForecastTests`, `ShadowTablesTests`, `ShadowTablesReplayTests`, `ForecastLogRecorderTests`, `SQLiteStoreForecastLogTests`, `BurnTierTrackerTests`.

**Approval:** the maintainer, 2026-10-04. Documentation only; touches no
item on the [VISION.md](../VISION.md) approval list. A ruling the maintainer gives in review is
recorded on the page as a *Decided* entry when the code does not follow it yet.

**blocked_by:** none.

## Goal

A contributor changing how Kvotar estimates burn, runway or pace finds the forecast tiers, the burn buffer and its limits, the runway formulas per tool, the pace clock and its grace, the blended rate that drives Claude's five-hour runway today, the shadow outputs and the forecast log that grades them, and cold start.

## Contract

1. Write `docs/spec/forecast.md` describing what the code and tests do today, in the format of the
   existing spec pages: front matter `summary` and `read_when`; **Questions for owner** (or
   "None"); **Decided** if the maintainer ruled; **About this page**; the current rules with their
   reasons; rejected alternatives where they matter; **Known gaps** with a proposed fix per row;
   code and test pointers; last line `Checked against the code at <parent commit> + STEP_265`.
2. Link, never restate, a rule another page owns.
   - Owns window forecasts (five-hour and weekly): burn, runway, the pace clock and its 2 % grace, the blend, shadows, `forecast_log` and its grading inputs, cold start. **Describe the current blend; leave its future grading and retention open.**
   - The long-limit tiers (`LongLimitAssessment`) stay on state.md; this page owns only the pace inputs they read. The monthly spend rate and the monthly forecast are `credits-and-monthly-limits.md`'s.
   - The verdict's words and layout are `popover.md` / `explanations.md` (pending); this page owns the numbers they are built from.
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

state.md's tiers, other spec pages, any app code. Other spec pages except `INDEX.md`.

## Definition of done

   - The proof items hold.
   - One commit, `STEP_265: …`, lands the page, the index change and this contract.
