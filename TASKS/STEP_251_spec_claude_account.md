# STEP_251 — The Claude account rules are one public spec page

**refs:**
- [docs/spec/INDEX.md](../docs/spec/INDEX.md) — where this page goes; the shared rules it links.
- [docs/spec/quota-readings.md](../docs/spec/quota-readings.md), [docs/spec/state.md](../docs/spec/state.md), [docs/spec/display-semantics.md](../docs/spec/display-semantics.md), [docs/spec/polling.md](../docs/spec/polling.md) — the shared rules; link them, never restate them.
- [ARCHITECTURE.md](../ARCHITECTURE.md), [PATTERNS.md](../PATTERNS.md), [VISION.md](../VISION.md).
- [docs/spec/quota-readings.md](../docs/spec/quota-readings.md) — its Known gap on model-scoped limit width, which this page settles.
- Code: `Packages/ClaudeAdapter/Sources/ClaudeAdapter/ClaudeAccountAdapter.swift`, `Packages/ClaudeAdapter/Sources/ClaudeAdapter/ClaudeResponses.swift`; `Packages/ClaudeAdapter/Tests/`.

**Approval:** the maintainer, 2026-10-04. Documentation only; touches no
item on the [VISION.md](../VISION.md) approval list. A ruling the maintainer gives in review is
recorded on the page as a *Decided* entry.

**blocked_by:** none.

## Goal

A contributor changing how Kvotar reads Claude quota sees which calls are made, which fields become a reading, how plans and account kinds differ (Pro/Max, Team, Enterprise), how model-scoped weekly limits and prepaid or extra-usage data are handled, and when a call is skipped.

## Contract

1. Write `docs/spec/claude-account.md` describing what the code and tests do today, in the format of the
   existing spec pages: front matter `summary` and `read_when`; **Questions for owner** (or
   "None"); **Decided** if the maintainer ruled; **About this page**; the current rules with their
   reasons; rejected alternatives where they matter; **Known gaps** with a proposed fix per row;
   code and test pointers; last line `Checked against the code at <parent commit> + STEP_251`.
2. Link, never restate, a rule another page owns.
   - Owns the provider parsing `quota-readings.md` left to it: the `five_hour` mapping, reset de-jitter, unreadable resets, model-scoped limits and whether one can be "not started".
   - Monthly spend and credits as a product belong to the later credits page; this page owns only decoding them. Cadence, 429s and the prepaid call's gating stay on `polling.md`.
   - Synthetic fixture figures only.
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

The credits and monthly-limits page, any app code. Other spec pages except `INDEX.md`.

## Definition of done

   - The proof items hold.
   - One commit, `STEP_251: …`, lands the page, the index change and this contract.
