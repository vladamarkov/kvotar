# STEP_249 — The credential rules are one public spec page

**refs:**
- [docs/spec/INDEX.md](../docs/spec/INDEX.md) — where this page goes; the shared rules it links.
- [docs/spec/quota-readings.md](../docs/spec/quota-readings.md), [docs/spec/state.md](../docs/spec/state.md), [docs/spec/display-semantics.md](../docs/spec/display-semantics.md), [docs/spec/polling.md](../docs/spec/polling.md) — the shared rules; link them, never restate them.
- [ARCHITECTURE.md](../ARCHITECTURE.md), [PATTERNS.md](../PATTERNS.md), [VISION.md](../VISION.md).
- [docs/credentials-and-privacy.md](../docs/credentials-and-privacy.md) — the user-facing explanation; link it.
- [docs/safety-checks.md](../docs/safety-checks.md), [decision 0001](../docs/decisions/0001-never-refresh-a-token.md), [decision 0002](../docs/decisions/0002-read-claude-credential-through-security.md) — the rules' reasons and their tests.
- Code: `Packages/ClaudeAdapter/Sources/ClaudeAdapter/KeychainTokenProvider.swift`, `Packages/CodexAdapter/Sources/CodexAdapter/CodexTokenProvider.swift`, the credential-expiry gate in `Packages/ClaudeAdapter/Sources/ClaudeAdapter/ClaudeAccountAdapter.swift`; `CredentialTreesUntouchedTests`.

**Approval:** the maintainer, 2026-10-04. Documentation only; touches no
item on the [VISION.md](../VISION.md) approval list. A ruling the maintainer gives in review is
recorded on the page as a *Decided* entry.

**blocked_by:** none.

## Goal

A contributor changing how Kvotar finds or reads a credential sees the current rules in one place: where each token is read, the read-only posture, what an expired or missing credential does, and what is never done.

## Contract

1. Write `docs/spec/credentials.md` describing what the code and tests do today, in the format of the
   existing spec pages: front matter `summary` and `read_when`; **Questions for owner** (or
   "None"); **Decided** if the maintainer ruled; **About this page**; the current rules with their
   reasons; rejected alternatives where they matter; **Known gaps** with a proposed fix per row;
   code and test pointers; last line `Checked against the code at <parent commit> + STEP_249`.
2. Link, never restate, a rule another page owns.
   - `docs/credentials-and-privacy.md` stays the user-facing explanation and the decision records stay the reasons; the page owns only the implementation rules. A disagreement between that doc and the code is a Known gap.
   - Any wording that could read as permission to refresh, write or prompt is a must-fix. The page changes no safety rule.
   - How often an expired credential is re-read stays on `polling.md`; link it.
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

`docs/credentials-and-privacy.md`, the decision records, the safety rules, any app code. Other spec pages except `INDEX.md`.

## Definition of done

   - The proof items hold.
   - One commit, `STEP_249: …`, lands the page, the index change and this contract.
