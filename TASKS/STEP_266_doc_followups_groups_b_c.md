# STEP_266 — The published pages link to each other, and six wording slips are fixed

**refs:**
- [docs/spec/INDEX.md](../docs/spec/INDEX.md) — which pages exist.
- Every page under `docs/spec/` that names a published page as pending, and the pages with a wording fix: [first-run-window.md](../docs/spec/first-run-window.md), [product-scope.md](../docs/spec/product-scope.md), [polling.md](../docs/spec/polling.md), [quota-readings.md](../docs/spec/quota-readings.md), [storage.md](../docs/spec/storage.md), [display-semantics.md](../docs/spec/display-semantics.md).
- [TRADEMARK.md](../TRADEMARK.md) and [updates-and-releases.md](../docs/spec/updates-and-releases.md) — the fork rule.
- [STEP_265_spec_forecast.md](STEP_265_spec_forecast.md) — its sentence on the blend.
- [capacity-learning.md](../docs/spec/capacity-learning.md), [forecast.md](../docs/spec/forecast.md), [local-usage.md](../docs/spec/local-usage.md) — the Known-gaps rows this step closes.

**Approval:** the maintainer, 2026-10-04. Documentation only; touches no item on the
[VISION.md](../VISION.md) approval list.

**blocked_by:** none.

## Goal

The pages of two groups were drafted in parallel and named each other as pending, and their checks
found six places where an earlier page says something the code or a later ruling does not. Now that
the pages exist, each mention is a link, and each slip is corrected. Topics without a page stay
marked pending.

## Contract

1. Every mention of a published page as pending becomes a relative link. No rule changes.
2. Wording fixes:
   - `first-run-window.md`: the surface opened when the menu-bar item is hidden is the *app
     window*, not the quota window (a quota window is a five-hour or weekly refill period).
   - `product-scope.md`, *Local activity*: message, prompt and code content is never decoded or
     stored; error-flagged lines are scanned raw for quota markers. The *Est. token value*
     definition's conditional "would cost" stays ("cost" is banned only as the figure's label).
   - `polling.md`: a quota 429 row is recorded and nothing reads it today; it needs a used percent
     for the primary window, not a five-hour one.
   - `quota-readings.md`: a stale reading shows no forecast; the state check still computes one and
     writes it to `forecast_log`.
   - `storage.md`: the CLI page owns the CLI's commands only; the `v11` row no longer reads as if a
     learned ceiling were live.
   - `display-semantics.md`: the CLI example has seven spaces between `Healthy` and `42%`, as
     `StatusReport.humanText` prints it.
3. `TRADEMARK.md` says a distributed fork changes `SUFeedURL` and `SUPublicEDKey`, or removes the
   updater, as `updates-and-releases.md` does.
4. `TASKS/STEP_265_spec_forecast.md` describes the current blend and leaves its future grading and
   retention open.
5. The Known-gaps rows that named these slips for a follow-up step are removed.
6. Each changed page's last line is `Checked against the code at <parent commit> + STEP_266`.

## Proof

1. Relative links and anchors resolve; `make check` passes.
2. No page names a published page as pending.
3. A different agent checked each wording fix against the code and the rulings.

## Deliberately untouched

Any app code; mentions of topics that have no page yet; five smaller term differences between pages
that stay open for the maintainer.

## Definition of done

   - The proof items hold.
   - One commit, `STEP_266: …`, lands the page changes, the contract edit and this contract.
