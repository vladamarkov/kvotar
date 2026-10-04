# STEP_263 — The credits and monthly-limit rules are one public spec page

**refs:**
- [docs/spec/INDEX.md](../docs/spec/INDEX.md) — where this page goes; the shared rules it links.
- [docs/spec/quota-readings.md](../docs/spec/quota-readings.md), [docs/spec/state.md](../docs/spec/state.md), [docs/spec/display-semantics.md](../docs/spec/display-semantics.md), [docs/spec/polling.md](../docs/spec/polling.md) — the shared rules; link them, never restate them.
- [ARCHITECTURE.md](../ARCHITECTURE.md), [PATTERNS.md](../PATTERNS.md), [VISION.md](../VISION.md).
- Pages to link: [docs/spec/claude-account.md](../docs/spec/claude-account.md) (decoding: self-serve and organization credits, the active meter and windowed seat, the prepaid wallet and its latch), [docs/spec/codex-account.md](../docs/spec/codex-account.md) (the monthly supplement, its plan gate, Decided 1–2, the credits-balance string gap), [docs/spec/state.md](../docs/spec/state.md) (long-limit tiers, the monthly layout's amber, glyph hysteresis), [docs/spec/display-semantics.md](../docs/spec/display-semantics.md) (Decided 3, `<1%`, and money formats), [docs/spec/quota-readings.md](../docs/spec/quota-readings.md), [docs/spec/polling.md](../docs/spec/polling.md), [docs/spec/storage.md](../docs/spec/storage.md) (`monthly_attrib_accum_<tool>`), `local-usage.md` and `estimated-value.md` (this group).
- Code: `Packages/KvotarCore/Sources/KvotarCore/State/MoneyState.swift`, `Packages/KvotarCore/Sources/KvotarCore/Forecast/MonthlySpendRate.swift`, `Packages/KvotarCore/Sources/KvotarCore/Forecast/MonthlyAttributionEstimator.swift`, the monthly and credits parts of `Packages/KvotarUI/Sources/KvotarUI/Model/DisplayFormatter.swift` (`monthly*`, `creditsCard`, `codexCreditsSpend`, `credits*`) and `DisplayFormatter+LimitSelection.swift` (`monthlyMetaLine`), `Packages/KvotarUI/Sources/KvotarUI/Views/Sections/CreditsCardSectionView.swift`, `CreditsSpendSectionView.swift`; `MoneyStateTests`, `MonthlySpendRateTests`, `MonthlyAttributionEstimatorTests`, `MonthlyLimitTests`, `DisplayFormatterMonthlyTests`.

**Approval:** the maintainer, 2026-10-04. Documentation only; touches no
item on the [VISION.md](../VISION.md) approval list. A ruling the maintainer gives in review is
recorded on the page as a *Decided* entry when the code does not follow it yet.

**blocked_by:** none.

## Goal

A contributor changing how Kvotar shows and acts on usage credits, a monthly spend limit, the prepaid wallet or spend control finds the money states, the credits card and the monthly layout's content, the monthly forecast and attribution split, and when each appears for which account — without re-deciding how the providers' fields are decoded.

## Contract

1. Write `docs/spec/credits-and-monthly-limits.md` describing what the code and tests do today, in the format of the
   existing spec pages: front matter `summary` and `read_when`; **Questions for owner** (or
   "None"); **Decided** if the maintainer ruled; **About this page**; the current rules with their
   reasons; rejected alternatives where they matter; **Known gaps** with a proposed fix per row;
   code and test pointers; last line `Checked against the code at <parent commit> + STEP_263`.
2. Link, never restate, a rule another page owns.
   - Owns credits and monthly spend **as a product**: the money states, when the credits card or the credits / spend section appears and what it says, the monthly layout's content, the monthly forecast (the spend rate and its gates — state.md already points here for the monthly amber), the monthly split shown as `This machine` / `Elsewhere` / `Not observed` (`offMachine` and `unattributed` are internal names only, never user-facing), spend control as a condition. **Decoding stays on the account pages** (Claude's active meter, windowed seat and arms; Codex's plan-gated supplement and codex-account Decided 1–2): link, never restate.
   - A Codex credits balance sent as the string `"0"`: today the decoder treats it as missing; its meaning is unknown. Say that, and make it a question for owner if the page needs it; never invent a meaning.
   - The `<1%` ruling is display-semantics Decided 3; link it for monthly meters, do not restate it.
   - The CLI's `runway_days` reuses `MonthlyLimit.runwayDays`: this page owns that rule; the [CLI page](../docs/spec/cli.md) links here.
   - **Never quote the balance in the public fixture `prepaid_credits.json`**; it looks real and a separate cleanup step replaces it. Invented figures only.
   - How the money glyph is drawn is `menu-bar.md`'s (pending); section layout is `popover.md`'s (pending); the spend-control notification is `notifications.md`'s (pending).
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

The account pages' decoding, other spec pages, any app code, the fixture itself. Other spec pages except `INDEX.md`.

## Definition of done

   - The proof items hold.
   - One commit, `STEP_263: …`, lands the page, the index change and this contract.
