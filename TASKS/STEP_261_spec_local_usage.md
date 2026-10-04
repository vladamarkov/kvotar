# STEP_261 — The local-usage rules are one public spec page

**refs:**
- [docs/spec/INDEX.md](../docs/spec/INDEX.md) — where this page goes; the shared rules it links.
- [docs/spec/quota-readings.md](../docs/spec/quota-readings.md), [docs/spec/state.md](../docs/spec/state.md), [docs/spec/display-semantics.md](../docs/spec/display-semantics.md), [docs/spec/polling.md](../docs/spec/polling.md) — the shared rules; link them, never restate them.
- [ARCHITECTURE.md](../ARCHITECTURE.md), [PATTERNS.md](../PATTERNS.md), [VISION.md](../VISION.md).
- Pages to link: [docs/spec/storage.md](../docs/spec/storage.md) (the local-usage tables, the `jsonl_*` settings keys, retention), [docs/spec/quota-readings.md](../docs/spec/quota-readings.md) (window start and width), [docs/spec/polling.md](../docs/spec/polling.md) (the session-start poll and the quota-429 record), [docs/spec/state.md](../docs/spec/state.md) (the off-machine and active-surface conditions), [docs/spec/product-scope.md](../docs/spec/product-scope.md) (the terms Local activity, Surface, Elsewhere), [docs/spec/codex-account.md](../docs/spec/codex-account.md) (the `usage_limited` signal it reads), [docs/spec/credentials.md](../docs/spec/credentials.md).
- Code: `Packages/KvotarCore/Sources/KvotarCore/Adapters/JSONLDirectoryWatcher.swift`, `Packages/KvotarCore/Sources/KvotarCore/Adapters/JSONLBackfillReader.swift`, `Packages/KvotarCore/Sources/KvotarCore/Adapters/LocalAdapter.swift`, `Packages/ClaudeAdapter/Sources/ClaudeAdapter/ClaudeJSONLParser.swift`, `Packages/ClaudeAdapter/Sources/ClaudeAdapter/ClaudeLocalAdapter.swift`, `Packages/CodexAdapter/Sources/CodexAdapter/CodexJSONLParser.swift`, `Packages/CodexAdapter/Sources/CodexAdapter/CodexLocalAdapter.swift`, `Packages/CodexAdapter/Sources/CodexAdapter/CodexSQLiteMetadataReader.swift`, `Packages/KvotarCore/Sources/KvotarCore/Attribution/`, `Packages/KvotarCore/Sources/KvotarCore/Forecast/OffMachineEstimator.swift`, `Packages/KvotarCore/Sources/KvotarCore/Storage/SQLiteStore+TokenEvents.swift`, `+Attribution.swift`, `+DailyLocal.swift`; the backfill and one-time repairs in `App/PollCoordinator.swift`; `Packages/KvotarUI/Sources/KvotarUI/Model/DisplayFormatter+LocalActivity.swift`, `LocalActivitySection.swift`; their tests.

**Approval:** the maintainer, 2026-10-04. Documentation only; touches no
item on the [VISION.md](../VISION.md) approval list. A ruling the maintainer gives in review is
recorded on the page as a *Decided* entry when the code does not follow it yet.

**blocked_by:** none.

## Goal

A contributor changing how Kvotar reads the tools' own session logs finds where the logs are found, how the watcher and the backfill read them, what one parsed request is, how tokens are counted and deduplicated, how work is attributed to windows and surfaces, how the share no local activity explains (Elsewhere) is estimated, and which one-time repairs the backfill has run.

## Contract

1. Write `docs/spec/local-usage.md` describing what the code and tests do today, in the format of the
   existing spec pages: front matter `summary` and `read_when`; **Questions for owner** (or
   "None"); **Decided** if the maintainer ruled; **About this page**; the current rules with their
   reasons; rejected alternatives where they matter; **Known gaps** with a proposed fix per row;
   code and test pointers; last line `Checked against the code at <parent commit> + STEP_261`.
2. Link, never restate, a rule another page owns.
   - Owns: where each tool's session logs are, the watcher and its debounce, the backfill and its watermark, parsing (what a request is; message, prompt and code content is never decoded or stored; error-flagged lines are scanned for quota markers, and the 429/529 line shapes are an unverified working assumption — `ClaudeJSONLParser.detectQuota429`), token counting and deduplication, subagent and surface attribution, the Codex local databases (`state_5.sqlite`, `goals_1.sqlite`: how they are opened and read; codex-account owns what the `usage_limited` signal does to a reading), the one-time repairs (`jsonl_*_done_*` keys; storage links here), the Elsewhere / off-machine estimate, the local-day report behind the popover's local activity section (its data, not its layout).
   - Links, does not restate: a quota 429 line becomes a `quota_limit_events` row under polling's rule; what the row is for is `capacity-learning.md`'s. Prices and value are `estimated-value.md`'s; the monthly `This machine` / `Elsewhere` / `Not observed` split of spend is `credits-and-monthly-limits.md`'s.
   - Section layout of the popover is `popover.md`'s (pending); this page owns what the local activity figures mean.
3. `docs/spec/INDEX.md` lists the page under *Topic pages* with its code areas, and drops it from
   *Topics without a page yet*.

   - Terms: a *quota window* is the five-hour or weekly refill period; the separate UI surface is an *app window* (the standalone quota display window belongs to group B). Pending links on published pages are updated in a separate step after group C lands, not in this step's commit.

## Proof

1. A different agent than the writer checked every factual claim against the code and tests; every
   unresolved finding is on the page.
2. Relative links and anchors resolve; `make check` passes.
3. A fresh agent with only this repository reaches the page from `AGENTS.md` through the index for
   a representative task.
4. No personal or account data, private paths or credential material on the page; invented figures only.

## Deliberately untouched

Other spec pages, any app code. The off-machine *state* rule (state.md) and the session-start poll (polling.md). Other spec pages except `INDEX.md`.

## Definition of done

   - The proof items hold.
   - One commit, `STEP_261: …`, lands the page, the index change and this contract.
