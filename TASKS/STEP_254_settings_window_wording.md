# STEP_254 — The Settings window ruling names no release stage

**refs:**
- [docs/spec/product-scope.md](../docs/spec/product-scope.md) — Decided 1 and its Known-gaps row.

**Approval:** the maintainer, 2026-10-04. Documentation only; touches no item on the
[VISION.md](../VISION.md) approval list.

**blocked_by:** none.

## Goal

Kvotar already ships as a public beta, so the Settings window ruling must not name a release stage
the plan has passed. The decision itself does not change.

## Contract

1. `product-scope.md` Decided 1 and its Known-gaps row say: settings available today live in the
   right-click menu; a separate Settings window remains planned future work, with no release target
   assigned. No "Pre-Alpha" or "Alpha" wording remains on the page.
2. The page's last line is `Checked against the code at <parent commit> + STEP_254`.

## Proof

1. Relative links and anchors resolve; `make check` passes.

## Deliberately untouched

Any app code, including the four "Step 30" comments; other spec pages.

## Definition of done

   - The proof items hold.
   - One commit, `STEP_254: …`, lands the page change and this contract.
