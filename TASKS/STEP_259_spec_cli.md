# STEP_259 — The `kvotar` command-line tool is one public spec page

**refs:**
- [docs/spec/INDEX.md](../docs/spec/INDEX.md) — where this page goes; the shared rules it links.
- [docs/spec/quota-readings.md](../docs/spec/quota-readings.md), [docs/spec/state.md](../docs/spec/state.md), [docs/spec/display-semantics.md](../docs/spec/display-semantics.md), [docs/spec/polling.md](../docs/spec/polling.md) — the shared rules; link them, never restate them.
- [ARCHITECTURE.md](../ARCHITECTURE.md), [PATTERNS.md](../PATTERNS.md), [VISION.md](../VISION.md).
- [docs/spec/storage.md](../docs/spec/storage.md) — the CLI's read-only database use and the commands that write; link it.
- [docs/spec/diagnostics.md](../docs/spec/diagnostics.md) — owns `debug`, `capture`, `logs`, `import`; link it.
- [docs/spec/state.md](../docs/spec/state.md) and [docs/spec/display-semantics.md](../docs/spec/display-semantics.md) — the `kvotar status` state gap and the `CLIFormat` drift gap; link them.
- Code: `Packages/KvotarCLI/Sources/KvotarCLI/`, `scripts/cli.sh`; tests in `Packages/KvotarCLI/Tests/KvotarCLITests/`.

**Approval:** the maintainer, 2026-10-04. Documentation only; touches no
item on the [VISION.md](../VISION.md) approval list. A ruling the maintainer gives in review is
recorded on the page as a *Decided* entry.

**blocked_by:** none.

## Goal

A contributor adding or changing a `kvotar` command finds the command list, the global options, the text and JSON output contracts, exit codes, how the tool is built and installed, and what it never does.

## Contract

1. Write `docs/spec/cli.md` describing what the code and tests do today, in the format of the
   existing spec pages: front matter `summary` and `read_when`; **Questions for owner** (or
   "None"); **Decided** if the maintainer ruled; **About this page**; the current rules with their
   reasons; rejected alternatives where they matter; **Known gaps** with a proposed fix per row;
   code and test pointers; last line `Checked against the code at <parent commit> + STEP_259`.
2. Link, never restate, a rule another page owns.
   - The page owns the command tree and global options, `doctor`, `status` (text and `--json`; the JSON field names are a machine contract), version, exit codes and errors, build and install today, and what the CLI never does.
   - Database access is [storage](../docs/spec/storage.md)'s; the diagnostics commands stay on [diagnostics](../docs/spec/diagnostics.md), listed here in one line each.
   - The status-state gap on [state](../docs/spec/state.md#known-gaps) and the CLI drift on [display semantics](../docs/spec/display-semantics.md#known-gaps) are linked, not restated.
   - "Quota window" means only the five-hour or weekly refill period. The separate window that shows the quota (`QuotaWindowController`, opened by **Open in Window**) is the **app window**. Monthly labels, if mentioned, are "This machine", "Elsewhere", "Not observed"; `offMachine` and `unattributed` are internal names.
   - `status --json`'s monthly `runway_days` reuses `MonthlyLimit.runwayDays`; that rule is `credits-and-monthly-limits.md`'s (pending). List the field and link it.
3. `docs/spec/INDEX.md` lists the page under *Topic pages* with its code areas, and drops it from
   *Topics without a page yet*.

## Proof

1. A different agent than the writer checked every factual claim against the code and tests; every
   unresolved finding is on the page.
2. Relative links and anchors resolve; `make check` passes.
3. A fresh agent with only this repository reaches the page from `AGENTS.md` through the index for
   a representative task: "add a --tool filter to kvotar status".
4. No personal or account data, private paths or credential material on the page.

## Deliberately untouched

Any app code. Other CLI behaviour. Other spec pages except `INDEX.md`.

## Definition of done

   - The proof items hold.
   - One commit, `STEP_259: …`, lands the page, the index change and this contract.
