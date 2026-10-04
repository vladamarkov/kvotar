# STEP_248 — Newcomers learn what Kvotar is from one short page

**refs:**
- [docs/spec/INDEX.md](../docs/spec/INDEX.md) — where this page goes; the shared rules it links.
- [docs/spec/quota-readings.md](../docs/spec/quota-readings.md), [docs/spec/state.md](../docs/spec/state.md), [docs/spec/display-semantics.md](../docs/spec/display-semantics.md), [docs/spec/polling.md](../docs/spec/polling.md) — the shared rules; link them, never restate them.
- [ARCHITECTURE.md](../ARCHITECTURE.md), [PATTERNS.md](../PATTERNS.md), [VISION.md](../VISION.md).
- [README.md](../README.md) — the user-facing overview; link it, do not copy it.
- [AGENTS.md](../AGENTS.md) — the safety rules and the copy rule; link them.
- Code: `Packages/KvotarCore/Sources/KvotarCore/Tool.swift`, `Packages/KvotarCore/Sources/KvotarCore/ProductIdentity.swift`.

**Approval:** the maintainer, 2026-10-04. Documentation only; touches no
item on the [VISION.md](../VISION.md) approval list. A ruling the maintainer gives in review is
recorded on the page as a *Decided* entry.

**blocked_by:** none.

## Goal

A new contributor or agent learns in one short page what Kvotar does and does not do, which tools and account kinds it covers, and the few terms every other page assumes, with links to the overviews that already exist instead of a copy of them.

## Contract

1. Write `docs/spec/product-scope.md` describing what the code and tests do today, in the format of the
   existing spec pages: front matter `summary` and `read_when`; **Questions for owner** (or
   "None"); **Decided** if the maintainer ruled; **About this page**; the current rules with their
   reasons; rejected alternatives where they matter; **Known gaps** with a proposed fix per row;
   code and test pointers; last line `Checked against the code at <parent commit> + STEP_248`.
2. Link, never restate, a rule another page owns.
   - Brief: a map, not a second README. A term already defined on a shared page is linked, not redefined.
   - What Kvotar never does (the safety rules) is named only by linking `AGENTS.md` and the decision records.
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

README, VISION and ARCHITECTURE themselves; any app code. Other spec pages except `INDEX.md`.

## Definition of done

   - The proof items hold.
   - One commit, `STEP_248: …`, lands the page, the index change and this contract.
