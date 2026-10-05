# STEP_253 — Two group A rulings say exactly what the maintainer decided

**refs:**
- [docs/spec/product-scope.md](../docs/spec/product-scope.md) — Decided 1 and its Known-gaps row.
- [docs/spec/storage.md](../docs/spec/storage.md) — Questions for owner, Decided, the lock rules and Known gaps.
- [docs/spec/first-run-window.md](../docs/spec/first-run-window.md) — where the notification switches live.

**Approval:** the maintainer, 2026-10-04. Documentation only; touches no item on the
[VISION.md](../VISION.md) approval list.

**blocked_by:** none.

## Goal

The product-scope and storage pages record the maintainer's rulings as given: no Settings window today,
the window planned with no release target, and a missing support folder treated as a lock
error.

## Contract

1. `product-scope.md` Decided 1: there is no Settings window today; settings live in the
   right-click menu; the Settings window is planned, with no release target. The Known gap on the four
   code comments names their obsolete "Step 30" promise; it does not propose deleting the future
   window.
2. `storage.md`: the open question on a missing support folder becomes Decided 2 — the app reports a
   lock error and does not poll — with today's unguarded run as a Known gap.
3. Both pages' last line is `Checked against the code at <parent commit> + STEP_253`.

## Proof

1. Relative links and anchors resolve; `make check` passes.
2. No personal or account data, private paths or credential material in the diff.

## Deliberately untouched

Any app code, including the four comments; other spec pages and `INDEX.md`.

## Definition of done

   - The proof items hold.
   - One commit, `STEP_253: …`, lands both page changes and this contract.
