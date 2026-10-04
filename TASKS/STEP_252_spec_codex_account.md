# STEP_252 — The Codex account rules are one public spec page

**refs:**
- [docs/spec/INDEX.md](../docs/spec/INDEX.md) — where this page goes; the shared rules it links.
- [docs/spec/quota-readings.md](../docs/spec/quota-readings.md), [docs/spec/state.md](../docs/spec/state.md), [docs/spec/display-semantics.md](../docs/spec/display-semantics.md), [docs/spec/polling.md](../docs/spec/polling.md) — the shared rules; link them, never restate them.
- [ARCHITECTURE.md](../ARCHITECTURE.md), [PATTERNS.md](../PATTERNS.md), [VISION.md](../VISION.md).
- [docs/spec/quota-readings.md](../docs/spec/quota-readings.md) — its Decided 1 (rule W for Codex) and the parsing it left to this page.
- Code: `Packages/CodexAdapter/Sources/CodexAdapter/` (`CodexAccountAdapter`, `CodexRPCClient`, `CodexWhamHTTPClient`, the response types), `Packages/KvotarCore/Sources/KvotarCore/Adapters/CodexBinaryCandidates.swift`; `Packages/CodexAdapter/Tests/`.

**Approval:** the maintainer, 2026-10-04. Documentation only; touches no
item on the [VISION.md](../VISION.md) approval list. A ruling the maintainer gives in review is
recorded on the page as a *Decided* entry.

**blocked_by:** none.

## Goal

A contributor changing how Kvotar reads Codex quota sees how the app-server is found and spoken to, when the web fallback is used, which fields become a reading, the placeholder-reset rule, and how plan types (Free, Go, Plus, Pro, Enterprise) shape the reading.

## Contract

1. Write `docs/spec/codex-account.md` describing what the code and tests do today, in the format of the
   existing spec pages: front matter `summary` and `read_when`; **Questions for owner** (or
   "None"); **Decided** if the maintainer ruled; **About this page**; the current rules with their
   reasons; rejected alternatives where they matter; **Known gaps** with a proposed fix per row;
   code and test pointers; last line `Checked against the code at <parent commit> + STEP_252`.
2. Link, never restate, a rule another page owns.
   - Owns the provider parsing `quota-readings.md` left to it: the placeholder-reset rule and when it applies (after any poll that did not look like a placeholder, not only the first), the anchor-pair handling, plan_type strings.
   - Rule W for Codex is linked (quota-readings Decided 1), not restated. Credits as a product and local session logs belong to later pages.
   - Binary discovery: the candidates and approval flags, from the code.
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

Credits and local usage, any app code. Other spec pages except `INDEX.md`.

## Definition of done

   - The proof items hold.
   - One commit, `STEP_252: …`, lands the page, the index change and this contract.
