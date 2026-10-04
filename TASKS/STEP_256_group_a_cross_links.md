# STEP_256 — The group A pages link to each other

**refs:**
- [docs/spec/product-scope.md](../docs/spec/product-scope.md), [docs/spec/credentials.md](../docs/spec/credentials.md), [docs/spec/storage.md](../docs/spec/storage.md) — the mentions to update.
- [docs/spec/INDEX.md](../docs/spec/INDEX.md) — which pages exist.

**Approval:** the maintainer, 2026-10-04. Documentation only; touches no item on the
[VISION.md](../VISION.md) approval list.

**blocked_by:** none.

## Goal

The group A pages drafted in parallel named each other as pending. Now that all five exist, each
mention is a link; topics without a page stay marked pending.

## Contract

1. In `product-scope.md`, `credentials.md` and `storage.md`, every mention of a published group A
   page as pending becomes a relative link. No rule or wording changes otherwise.
2. Each changed page's last line is `Checked against the code at <parent commit> + STEP_256`.

## Proof

1. Relative links and anchors resolve; `make check` passes.
2. No group A page names another published page as pending.

## Deliberately untouched

Any app code; the shared pages (STEP_255); mentions of topics that have no page yet.

## Definition of done

   - The proof items hold.
   - One commit, `STEP_256: …`, lands the page changes and this contract.
