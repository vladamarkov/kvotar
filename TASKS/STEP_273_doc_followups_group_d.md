# STEP_273 — Every spec page links to the pages it names, and the wrong lines group D found are fixed

**refs:**
- [docs/spec/INDEX.md](../docs/spec/INDEX.md) — every planned topic now has a page.
- The pages written last, which other pages still name as pending:
  [notifications.md](../docs/spec/notifications.md), [menu-bar.md](../docs/spec/menu-bar.md),
  [popover.md](../docs/spec/popover.md), [explanations.md](../docs/spec/explanations.md),
  [history.md](../docs/spec/history.md), [account-summary.md](../docs/spec/account-summary.md).
- The pages with a wording fix: [state.md](../docs/spec/state.md),
  [display-semantics.md](../docs/spec/display-semantics.md),
  [claude-account.md](../docs/spec/claude-account.md),
  [credits-and-monthly-limits.md](../docs/spec/credits-and-monthly-limits.md),
  [storage.md](../docs/spec/storage.md), [diagnostics.md](../docs/spec/diagnostics.md).
- [STEP_266_doc_followups_groups_b_c.md](STEP_266_doc_followups_groups_b_c.md) — the first step of
  this kind.

**Approval:** the maintainer, 2026-10-05. Documentation only; touches no item on the
[VISION.md](../VISION.md) approval list.

**blocked_by:** none.

## Goal

The last six pages were written after the others, so earlier pages still name them as pending, and
about ten lines send topics that now live on the account-summary page to the popover page. The
checks on those six pages also found lines on earlier pages that no longer match the code. Now
every mention is a link to the right page, and each of those lines says what the code does today.

## Contract

1. **Links.** Every mention of a spec page that is marked pending, or named only in backticks,
   becomes a relative link. No pending mention remains.
2. **Right page.** A line that sends an account-summary topic (plan display names, verdict copy
   outside the monthly family, burn tiers, the burn figure and its display gate, the cold-start
   verdict, the hero) to the popover page points at the account-summary page instead.
3. **Wording fixes,** each checked against the code first:
   - `state.md`, constants: a per-model allowance at 85 % turns into a model warning; it is never
     promoted to the header.
   - `state.md`, first evaluation: the silent first evaluation applies to a tool with no saved
     reading. On a usual relaunch the saved reading is restored as stale, so the first fresh poll is
     an ordinary transition and can notify; notices on the poll signal need no transition. The
     rules stay on the notifications page.
   - `display-semantics.md`: the hero equals the menu-bar number except while the bar shows a
     long-limit shape; a stale block keeps its red only while the bar can draw the block (a weekly
     block whose five-hour window has ended draws grey, a known gap on the menu-bar page); the
     History row names the Weekly recap's weekly lines; the "pages not written yet" sentence links
     the pages.
   - `claude-account.md`: the scoped-reset 60-second comparison sits in a builder nothing calls;
     say so. Today's account summary shows each model limit's own reset and compares nothing.
   - `credits-and-monthly-limits.md`: the Codex section's title is drawn upper case.
   - `storage.md`: `popover_opens` is written by popover and app-window opens; `history_rollups` is
     read by History and by capacity learning.
   - `diagnostics.md`: the explanation snapshot records every tagged element except one (E-06, a
     known gap on the explanations page).
4. Each changed page's last line is `Checked against the code at 00ed0b1 + STEP_273`.

## Proof

1. Relative links and anchors resolve; `make check` passes.
2. No page names another spec page as pending or only in backticks.
3. A different agent checked each change against the code and the rulings.

## Deliberately untouched

Any app code; the first-run window's copy (a code step); the term differences still open for the
maintainer; lines that wait on an open question, such as the History recap's whole-dollar form.

## Definition of done

   - The proof items hold.
   - One commit, `STEP_273: …`, lands the page changes and this contract.
