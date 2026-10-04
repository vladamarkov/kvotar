# STEP_264 — The estimated-value rules are one public spec page

**refs:**
- [docs/spec/INDEX.md](../docs/spec/INDEX.md) — where this page goes; the shared rules it links.
- [docs/spec/quota-readings.md](../docs/spec/quota-readings.md), [docs/spec/state.md](../docs/spec/state.md), [docs/spec/display-semantics.md](../docs/spec/display-semantics.md), [docs/spec/polling.md](../docs/spec/polling.md) — the shared rules; link them, never restate them.
- [ARCHITECTURE.md](../ARCHITECTURE.md), [PATTERNS.md](../PATTERNS.md), [VISION.md](../VISION.md).
- Pages to link: [docs/spec/product-scope.md](../docs/spec/product-scope.md) (the term *Est. token value*), [docs/spec/display-semantics.md](../docs/spec/display-semantics.md) (the `$12.00` USD format, the copy rule), [docs/spec/storage.md](../docs/spec/storage.md) (`unpriced_models`), [docs/spec/codex-account.md](../docs/spec/codex-account.md) (`isOrganizationPlan` points here), `local-usage.md` (which tokens are counted).
- Code: `Packages/KvotarCore/Sources/KvotarCore/Pricing/EstimatedValueEngine.swift`, `Packages/KvotarCore/Sources/KvotarCore/Pricing/PricingModels.swift`, `Resources/pricing.json`, `Packages/KvotarCore/Sources/KvotarCore/Storage/SQLiteStore+EstimatedValue.swift`, `Packages/KvotarCore/Sources/KvotarCore/Storage/SQLiteStore+UnpricedModels.swift`, the value note and `isOrganizationPlan` in `Packages/KvotarUI/Sources/KvotarUI/Model/DisplayFormatter+LocalActivity.swift`; `EstimatedValueEngineTests`, `ShippedPricingTableTests`, `SQLiteStoreEstimatedValueTests`, `UnpricedModelsTests`.

**Approval:** the maintainer, 2026-10-04. Documentation only; touches no
item on the [VISION.md](../VISION.md) approval list. A ruling the maintainer gives in review is
recorded on the page as a *Decided* entry when the code does not follow it yet.

**blocked_by:** none.

## Goal

A contributor changing the bundled price list or the estimated token value finds the table's schema and versioning, how a model is matched to a price, what happens to a model with no price, how the value is computed and over which span, and the wording rule that it is an estimate, never a cost.

## Contract

1. Write `docs/spec/estimated-value.md` describing what the code and tests do today, in the format of the
   existing spec pages: front matter `summary` and `read_when`; **Questions for owner** (or
   "None"); **Decided** if the maintainer ruled; **About this page**; the current rules with their
   reasons; rejected alternatives where they matter; **Known gaps** with a proposed fix per row;
   code and test pointers; last line `Checked against the code at <parent commit> + STEP_264`.
2. Link, never restate, a rule another page owns.
   - Owns: the price table and its version, model matching, unpriced models, the value computation and span, "Organization pays" wording, and why the value is never called cost. **Links product-scope's *Est. token value* term**; does not redefine it.
   - Token counting (what is counted, deduplication) is `local-usage.md`'s; the monthly attribution that prices local tokens is `credits-and-monthly-limits.md`'s.
   - Updating prices is data work under this page's rules; the page does not list every price (it points at `Resources/pricing.json`).
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

Other spec pages, any app code, `Resources/pricing.json`. Other spec pages except `INDEX.md`.

## Definition of done

   - The proof items hold.
   - One commit, `STEP_264: …`, lands the page, the index change and this contract.
