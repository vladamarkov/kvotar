# STEP_272 — The popover's account summary is one public spec page

**refs:**
- [docs/spec/INDEX.md](../docs/spec/INDEX.md) — where this page goes; the shared rules it links.
- [docs/spec/quota-readings.md](../docs/spec/quota-readings.md), [docs/spec/state.md](../docs/spec/state.md), [docs/spec/display-semantics.md](../docs/spec/display-semantics.md), [docs/spec/polling.md](../docs/spec/polling.md) — the shared rules; link them, never restate them.
- [ARCHITECTURE.md](../ARCHITECTURE.md), [PATTERNS.md](../PATTERNS.md), [VISION.md](../VISION.md).
- Pages to link: [state.md](../docs/spec/state.md) (tiers, ranks, the model-warning constant), [forecast.md](../docs/spec/forecast.md) (runway, pace, `exhaustionRunwayMinutes` data, burn tiers), [display-semantics.md](../docs/spec/display-semantics.md) (percent, colours, voice tier, unknown and stale wording), [quota-readings.md](../docs/spec/quota-readings.md) (not-started and unanchored windows), [credits-and-monthly-limits.md](../docs/spec/credits-and-monthly-limits.md) (the monthly verdict family, monthly rows), [local-usage.md](../docs/spec/local-usage.md) (the Not seen locally estimate), [claude-account.md](../docs/spec/claude-account.md) and [codex-account.md](../docs/spec/codex-account.md) (plan strings, model-scoped limits); `popover.md`, `explanations.md`, `menu-bar.md` (this group).
- Code: `Packages/KvotarUI/Sources/KvotarUI/Model/AccountLimitSelection.swift`, `Packages/KvotarUI/Sources/KvotarUI/Model/DisplayFormatter+LimitSelection.swift`, the header and verdict functions of `Packages/KvotarUI/Sources/KvotarUI/Model/DisplayFormatter.swift` (`header`, `heroLive`, `headerVerdict`, `overQuotaVerdict`, `notStartedWithdrawn`, `planDisplayName`, `sourceTag`), the header types in `Packages/KvotarUI/Sources/KvotarUI/Model/PopoverDisplay.swift`, `Packages/KvotarUI/Sources/KvotarUI/Views/Sections/HeaderSectionView.swift` (not its anatomy code), `Packages/KvotarUI/Sources/KvotarUI/Views/Sections/OtherLimitsSectionView.swift`. Tests: `AccountLimitSelectionTests`, `DisplayFormatterOtherLimitsTests`, `DisplayFormatterScopedLimitsTests`, `DisplayFormatterNotStartedTests`, `DisplayFormatterLowAllowanceTests`, `DisplayFormatterWindowGrainTests`, `LongLimitSurfaceAgreementTests`, the header parts of `DisplayFormatterTests` and `DisplayFormatterV46Tests`.

**Approval:** the maintainer, 2026-10-04. Documentation only; touches no
item on the [VISION.md](../VISION.md) approval list. A ruling the maintainer gives in review is
recorded on the page as a *Decided* entry when the code does not follow it yet.

**blocked_by:** none.

## Goal

A contributor changing which limit leads the popover, the verdict lines, the header facts, the long-limit strip, model warnings or the OTHER LIMITS rows finds the selection rule and every non-monthly verdict template — without re-deciding tiers, runway numbers or the monthly family.

## Contract

1. Write `docs/spec/account-summary.md` describing what the code and tests do today, in the format of the
   existing spec pages: front matter `summary` and `read_when`; **Questions for owner** (or
   "None"); **Decided** if the maintainer ruled; **About this page**; the current rules with their
   reasons; rejected alternatives where they matter; **Known gaps** with a proposed fix per row;
   code and test pointers; last line `Checked against the code at <parent commit> + STEP_272`.
2. Link, never restate, a rule another page owns.
   - The popover splits in two (owner ruling): `popover.md` (STEP_269) is the frame, this page the account summary. The page opens by saying it covers display, not account decoding (that is [claude-account.md](../docs/spec/claude-account.md) / [codex-account.md](../docs/spec/codex-account.md)), and that the same view shows in the app window.
   - Owns which limit is the hero (`selectLimit`, `HeroReason`: only a blocking limit leaves the primary; no model hero), caption, meter and overflow, verdict lines 1 and 2 outside the monthly family (credits.md and forecast.md already hand them here), the not-started and low-allowance row removal, hero detail lines, header facts and their display gate, the long-limit strip and its highlighted row, model warnings, OTHER LIMITS rows and model groups, plan badge and email, the quota source tag.
   - Does not own: the anatomy and hover cards (`explanations.md` — their code sits in `HeaderSectionView`; say so), the monthly verdict family (credits), tiers and the model-warning constant (state), runway data (forecast), the menu-bar slot (`menu-bar.md`).
   - Known disagreements: weekly promotion is retired (only a block takes the hero); the `Quota:` source prefix never shipped; the inactive-tab percentage is gone; state.md's "promoted in the popover" line now means a model warning (list it as a wrong line, don't edit state.md).
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
   - One commit, `STEP_272: …`, lands the page, the index change and this contract.
