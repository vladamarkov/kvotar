# STEP_255 — Shared spec pages link to the published account and credential rules

**refs:**
- [docs/spec/quota-readings.md](../docs/spec/quota-readings.md)
- [docs/spec/polling.md](../docs/spec/polling.md)
- [docs/spec/credentials.md](../docs/spec/credentials.md)
- [docs/spec/claude-account.md](../docs/spec/claude-account.md)
- [docs/spec/codex-account.md](../docs/spec/codex-account.md)

**Approval:** the maintainer requested the pending links on the shared pages be updated on
2026-10-04. Documentation only; no behavior or rule changes.

**blocked_by:** none.

## Goal

Readers of the shared pages reach the published Group A rules through working links instead of
being told those pages are pending.

## Contract

1. Replace references to the pending Claude account, Codex account and credentials pages in
   quota-readings and polling with links to the published pages and relevant sections.
2. Link the polling page's pre-request expiry check to the credentials page that owns it.
3. Keep references to pages that have not landed marked pending. Do not change any rule or app code.
4. Set each edited spec page's Checked against line to the parent commit plus STEP_255.

## Proof

1. The new relative links and anchors resolve.
2. `make check` passes.
3. No Group A page is called pending on a shared page.

## Definition of done

- One commit lands the two shared-page edits and this contract.
