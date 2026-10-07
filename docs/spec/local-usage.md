---
summary: How Kvotar reads Claude Code's and Codex's own session logs on this Mac — where they are, the live watcher and its debounce, the launch backfill and its watermark, what one parsed request is, token counting and deduplication, surfaces and helper threads, Codex's two local databases, the one-time repairs, the Elsewhere estimate and the data behind today's local report.
read_when: Changing JSONLDirectoryWatcher, JSONLBackfillReader, LocalAdapter, ClaudeJSONLParser, ClaudeLocalAdapter, CodexJSONLParser, CodexLocalAdapter, CodexSQLiteMetadataReader, anything under Attribution/ (AttributionEngine, SurfaceWorkSplit, CodexSurface, CacheHit, DisplayedTokens, DailyLocalReport, LocalDayPolicy), OffMachineEstimator, SQLiteStore+TokenEvents, +Attribution or +DailyLocal, the backfill and one-time repairs in PollCoordinator, or what the local activity figures mean (DisplayFormatter+LocalActivity, LocalActivitySection); adding a Codex originator; touching what is read from a session log line.
---

# Local usage

## Questions for owner

None.

## About this page

This page is the specification for local usage: what Kvotar reads from each tool's own session
logs on this Mac, and what it derives from them. It replaces the private Implementation Baseline
§7.2 (Claude local adapter), §8.4 (Codex local attribution), §8.5 (Codex SQLite databases, except
what the `usage_limited` signal does to a reading) and §12.2 (window off-machine attribution), the
data parts of the private UI Spec §2.5 (local session section) and Part 2 §2.6, Part 2 §3.2
(off-machine detection) and §3.3 (current-window surface attribution), and the private records on
token counting, Codex helper threads, cumulative-counter resets and file growth as activity. Change
this page in the same commit as the code it describes.

IDs such as REV-nn or STEP_nnn in code comments are private record IDs;
[REFERENCES.md](../REFERENCES.md) explains them.

What this page does **not** own:

| Topic | Page |
|---|---|
| The terms *Local activity*, *Surface* and *Elsewhere* | [Product scope](product-scope.md#terms-a-newcomer-needs) |
| Window start and width, and why a window start is derived in one place | [Quota readings](quota-readings.md#limits-and-windows) |
| The Off-machine burn and Multi-surface states, the idle gap they use, and the `jsonl_delta` trigger | [State](state.md#when-state-is-evaluated) |
| The session-start and turn-end polls a local change can cause | [Polling](polling.md#extra-polls) |
| When a quota-limit line becomes a `quota_limit_events` row | [Polling](polling.md#a-refused-poll-is-not-an-exhausted-quota) |
| What a `quota_limit_events` row is for | [Capacity learning](capacity-learning.md) |
| What the `usage_limited` goal signal does to a Codex reading | [Codex account](codex-account.md#from-payload-to-reading) |
| The local tables' retention and the `settings` table | [Storage](storage.md#tables-by-purpose) |
| `parse_anomalies` rows (an undecodable log line) | [Diagnostics](diagnostics.md#where-it-is-stored-and-for-how-long) |
| Prices and the estimated token value | [Estimated value](estimated-value.md) |
| The monthly `This machine` / `Elsewhere` / `Not observed` split of spend | [Credits and monthly limits](credits-and-monthly-limits.md) |
| Where the local figures sit in the popover, and their hover text | [popover](popover.md), [explanations](explanations.md) |
| The never-store and never-write rules | [AGENTS.md](../../AGENTS.md#the-four-safety-rules) |

## Terms used here

| Term | Meaning |
|---|---|
| **Quota window** | The five-hour or weekly refill period ([quota readings](quota-readings.md#the-vocabulary)) |
| **Session log** | One `.jsonl` file a tool writes. For Claude Code one file holds lines of one or more sessions; for Codex one file is one thread |
| **Request** (token event) | One parsed log line that carries token counts: a `TokenEvent`, stored as one `local_usage_events` row |
| **Bucket** | The label stored with each request: a surface name, or `Subagent · <name>` for a helper thread |
| **Helper** | A subagent thread. It runs inside a surface and is never a surface itself |
| **Local write** | Any completed line appended to a watched log, with or without tokens |
| **Liveness timestamp** | The newest of: the newest request seen since launch, the newest stored request, the last local write (`LocalAttribution.lastActivityAt`) |

## Where the session logs are

| Tool | Folders read | Files |
|---|---|---|
| Claude | `~/.claude/projects` | Every `.jsonl` below it, any depth |
| Codex | `~/.codex/sessions` and `~/.codex/archived_sessions` | Every `.jsonl` below them, any depth |

Hidden files are skipped. (`ClaudeLocalAdapter.defaultRoot`, `CodexLocalAdapter.defaultRoots`,
`JSONLDirectoryWatcher.discover`)

- **Codex reads two folders, not all of `~/.codex`.** Reason: watching the whole folder cost one
  file handle per directory in it, including trees no session log lives in, and once exhausted the
  process's handle table so that every later file open failed. `archived_sessions` stays in
  because it holds real sessions. (test
  `JSONLDirectoryWatcherTests.testBothRootsAreDiscoveredAndDrained`)
- **A missing folder is normal.** It is logged once at INFO and checked again on every rescan, so
  it is picked up when it appears. A folder that exists but cannot be read is logged once as an
  ERROR, because that tree is then not watched. (`noteRootUnusable`; test
  `testMissingRootDoesNotDisableTheOtherRoot`)
- **The backfill sweeps exactly the watcher's folders.** A narrower sweep would leave a tree whose
  older bytes are never recovered; a wider one would ingest files the app chose not to watch.
- **No database, no watching.** The attribution engine that starts both watchers exists only when
  the database opened. (`PollCoordinator.init`)
- Codex's `state_5.sqlite` and `goals_1.sqlite` sit outside both folders and are read on demand
  ([below](#codexs-local-databases)).

## The live watcher

One `JSONLDirectoryWatcher` per tool owns the file handling; each adapter supplies its parser and
its change rule. (`JSONLDirectoryWatcher.swift`)

- **At launch every existing file is read from its end.** Its read offset is set to its current
  size, so the live path reports only lines appended after launch. Everything before that is the
  backfill's job. A file that appears later is read from its start. (`start`, `noteDiscovered`)
- **Handles are bounded.** A file gets its own change source only if it was modified in the last
  30 minutes, newest first, at most 128 per watcher. Older files keep their offset and cost no
  handle; a later write promotes them and reading resumes where it stopped. Reason: one handle per
  file ever seen eventually exhausted the process. (`syncFileSources`; tests
  `testHistoricalFilesGetNoSource`, `testFileSourceCountIsCapped`)
- **Each directory has one change source**, so new files are noticed. These are not bounded (see
  Known gaps).
- **Debounce: 5 seconds, cancel and reschedule.** Any file or directory event restarts a 5-second
  timer; the read happens when it runs out. (`scheduleFlush`)
- **A rescan every 45 seconds** discovers new files, promotes recently modified ones and reads
  them. Reason: an append to a file without a change source raises no event (a resumed old
  session is one), so without the rescan it stays unread. It also bounds the delay under a steady
  stream of writes that keeps restarting the debounce. (`startRescanTimer`; test
  `testRescanPromotesResumedUnwatchedFile`)
- **Only whole lines are parsed.** A trailing partial line is held until its newline arrives.
  (`readAppended`; test `testPartialLineIsCarriedAcrossFlushes`)
- **A file that shrank is read again from its start**, and a deleted or renamed file loses its
  offset and the adapter's per-file memory. (test `testRotatedFileIsReReadFromStart`)

Each read that found any new line (a *flush*) produces, in this order:

1. **A local write time.** Liveness only, never an amount: it reaches no token row, no rate, no
   burn tier, no session-start poll and no turn-end poll. Reason: Codex writes a turn's token line
   long after the work starts, so a working machine looked idle on token lines alone.
   (`LocalAdapter.localWrites`; tests `AttributionEngineTests.testFileGrowthKeepsTheToolLiveWithoutTokenLines`,
   `CodexLocalAdapterWatcherTests.testTokenlessAppendEmitsLocalWriteButNoTokenEvent`)
2. **The batch of requests**, if any, which the attribution engine stores in one transaction.
   (`AttributionEngine.ingest`)
3. **A meaningful-change signal**, only when at least one of these fired: a bucket not seen
   since launch appeared; a helper bucket not seen since launch appeared (Claude only); the local
   burn tier crossed a boundary; or a quota-limit line was read. (`LocalDeltaSignal.isMeaningful`)
   What it triggers is [state](state.md#when-state-is-evaluated) and
   [polling](polling.md#extra-polls).

**Burn tiers** count input plus output tokens over the last 2 minutes: below 100 tokens a minute
is none, then low to 1,000, mid to 3,000, high above. Only a crossing matters; the tier is never
shown. These are fixed starting values, because the adapter knows no plan and no provider states a
token budget per window. (`BurnTierTracker`; tests `BurnTierTrackerTests`)

## The launch backfill

The watcher skips everything written before launch. The backfill reads it, once per launch.
(`JSONLBackfillReader`, `PollCoordinator.startJSONLBackfill`, `runBackfill`)

- **It starts after both watchers set their offsets**, so the sweep's range and the live range
  meet with no gap. Overlap is harmless: duplicates are skipped.
- **One background task, Claude first, then Codex**, with a refresh of today's report after
  each, then the one-time repairs below, then another refresh. Nothing waits for it and it never touches the poll loop.
- **Which files:** every `.jsonl` under the tool's folders modified after the cutoff, newest first
  across all folders. The cutoff is the setting `jsonl_backfill_watermark_<tool>` (unix seconds of
  the last sweep's start), or 90 days ago when there is none. Reason for re-reading a whole file:
  it is the only way to fill gaps in the middle of a session the app was also watching. (test
  `ClaudeLocalAdapterBackfillTests.testMidStreamGapIsFilledExactly`)
- **How:** from byte 0 in 1 MiB chunks split at newlines; at most 2,000 requests per write; an
  unfinished last line is left to the live watcher; a file deleted between listing and reading is
  skipped. (tests `JSONLBackfillReaderTests`)
- **Requests only.** No quota-limit detection: a past limit line would be paired with today's
  reading. No change signal, no local write time, no turn-end hook: a past burst must not trigger
  polls or move the burn tier. (test
  `testBackfillEmitsNoDeltaSignalsAndQueuesNoQuota429s`)
- **The watermark moves to the sweep's start time after the sweep.** A crash mid-sweep keeps the
  old watermark, so the next launch sweeps again for free.
- **Codex keeps a second cumulative-total memory for the backfill**, cleared at each file's first
  chunk. Reason: judging a file read from byte 0 against the live memory, already at the file's
  end, would drop every turn as already counted. (`CodexLocalAdapter.backfillParse`)
- Each sweep logs files scanned, vanished, parsed, inserted and the inserted token count, so the
  one-off jump in long-period figures can be explained.

## What one request is

### Claude Code

A line is a request when it decodes with `type == "assistant"` and has a `sessionId` and a
message id or request id. Every other line is ignored, silently; only a line that will not decode
at all is reported as a parse anomaly. (`ClaudeJSONLParser.parseLine`; tests
`testNormalSessionParsesAssistantEventOnly`, `testMalformedAndNonAssistantLinesIgnored`,
`ClaudeParseAnomalyTests`)

| Kept | From |
|---|---|
| Session | `sessionId` |
| Project | `cwd` |
| Model | `message.model` |
| Bucket | `isSidechain`, `attributionAgent` ([below](#surfaces-and-helpers)) |
| Input, output, cache read | `message.usage.input_tokens`, `output_tokens`, `cache_read_input_tokens` |
| Cache write | `cache_creation_input_tokens`; else the sum of the two `cache_creation` tiers; else 0 |
| 1-hour share of the cache write | `cache_creation.ephemeral_1h_input_tokens`, capped at the cache write; `nil` when the line has no tier breakdown; 0 when the breakdown has no 1-hour field |
| Time | The line's own `timestamp`; the read time only when it is missing or unreadable |

`slug` is decoded but not stored. (tests `testCacheCreationSubTierFallbackAndAbsent`,
`testCacheWriteTiersAreCarriedAsASubsetOfTheTotal`, `testRecordedAtUsesLineTimestamp`)

**The line's own time, not the read time.** Reason: lines read late (after a sleep, or by the
backfill) must land at the moment they happened, or they look like a burst now.

### Codex

Each file is one thread. Its session id is the file name without `.jsonl`.
(`CodexLocalAdapter.sessionId`)

- **Line 1, `session_meta`,** gives the originator, `source`, `thread_source`, the helper's
  nickname, `parent_thread_id` and `forked_from_id`. It is read once per file, up to the first
  newline, in 64 KiB steps up to 1 MiB, because it embeds the session's configuration and is often
  larger than one small read. A file whose first line is missing or malformed still counts; its
  requests go to the `Unknown` bucket. The optional session fields (`source`,
  `thread_source`, the fork markers, the nickname, and `turn_context`'s model) decode leniently: a
  wrong shape drops that field, never the line. A wrong shape of `type`, `originator` or `info`
  fails the whole line. (`captureOriginator`, `parseSessionMeta`; tests
  `testLargeSessionMetaResolvesOriginator`, `testNestedSourceObjectDoesNotLoseOriginator`)
- **`turn_context` lines** (top-level `type`) give the model. Each request takes the newest
  `turn_context` model above it in the file, remembered across reads; before the first one, the
  thread's model from `state_5.sqlite`. The line must decode: chat lines can mention the word.
  (tests `testTurnContextModelAppliesToFollowingEventsAndSwitchesMidFile`,
  `testEventsBeforeFirstTurnContextUseCarryThenSessionModel`,
  `testChatLineMentioningTurnContextDoesNotChangeModel`)
- **A request is a line with `payload.type == "token_count"`** and a
  `payload.info.last_token_usage.total_tokens`. A token line without usage is skipped. (test
  `testNullInfoTokenEventDropped`)

| Kept | From |
|---|---|
| Input, output | `last_token_usage.input_tokens`, `output_tokens` |
| Cached input | `last_token_usage.cached_input_tokens`, stored in the `cache_creation_tokens` column; cache read is 0 |
| Project | `cwd` from `state_5.sqlite` |
| Time | The line's own `timestamp`; the read time only when it is missing or unreadable |

`reasoning_output_tokens` is decoded and deliberately not added: it is already inside
`output_tokens`. (test `testReasoningTokensAreNotAddedToOutput`)

Three rules drop a token line that would count work twice. Each dropped line writes a parse
anomaly with fixed text, so the rate stays visible.

1. **Re-recorded turn.** Codex sometimes writes the same turn again under a new timestamp. A line
   whose cumulative `total_token_usage.total_tokens` is not above the previous line's in the same
   file is a re-record and is dropped. Lines with no cumulative total are never dropped by this
   rule. (tests `testReEmittedTurnWithUnchangedCumulativeTotalIsDropped`,
   `testCarriedCumulativeTotalDropsReEmissionAcrossReads`,
   `testEventWithoutCumulativeTotalIsExemptFromDropRule`)
2. **Rebuilt counter.** If the cumulative total fell by more than this line's own turn, Codex
   rebuilt its counter (a resumed thread can do this). The line is kept and the memory restarts
   from it. Reason: a re-record sits at most one turn below; treating a rebuilt counter as one
   silenced hours of real turns. Fails soft: an old turn re-recorded after a rebuild is
   counted once more. (tests `testCumulativeCounterResetRebasesCarryInsteadOfDropping`,
   `testRegressionWithinOneTurnIsStillDropped`, `testCounterResetAcrossReadsViaCarry`)
3. **Inherited fork history.** When `session_meta` carries a fork marker and its timestamp parses,
   token lines stamped within 2 seconds of it are the parent thread's history copied into the
   fork, and are dropped before they can set the cumulative memory. Reason: the copy arrives
   within milliseconds and the first real turn many seconds later. A helper that carries
   `parent_thread_id` but inherits nothing loses nothing. Accepted: if the parent was never read,
   those turns are not counted anywhere. (tests
   `testForkedFileInheritedBlockDroppedAndGenuineTurnsKept`,
   `testParentThreadIdWithoutInheritedBlockLosesNothing`,
   `testInheritedBlockDoesNotPoisonCumulativeCarry`)

### What is never decoded or stored

- **Message, prompt and code content is never decoded or stored.** The decoders declare only the
  metadata fields in the tables above; everything else on a line is skipped by the decoder. Codex's
  first line is read whole into memory to find its end, but only its declared fields are decoded.
  (`RawEvent` in both parsers; tests `NoContentStoredTests` in ClaudeAdapter and CodexAdapter,
  which ingest a marked prompt, answer, tool call and tool output through the backfill and the
  live watcher with debug logging and capture on, and find the marker in no table, log or ordinary diagnostics bundle)
- **Error-flagged lines are scanned as raw text** for quota markers by both parsers
  ([below](#quota-limit-lines)). The scan looks for fixed words in memory; nothing from the line
  is kept but the file name and a time.
- **The working directory is stored** as the project (`local_sessions.project`).
- A line that will not decode is recorded by field names only, never values
  ([diagnostics](diagnostics.md#where-it-is-stored-and-for-how-long)).
- Kvotar never writes to these folders or to Codex's databases
  ([AGENTS.md](../../AGENTS.md#the-four-safety-rules)).

### Quota-limit lines

A *quota-limit line* is the user's own session reporting that it hit a usage limit. It is not
Kvotar's own refused poll ([polling](polling.md#a-refused-poll-is-not-an-exhausted-quota)).

| Tool | A line counts when | Its time |
|---|---|---|
| Claude | It decodes with `isApiErrorMessage == true` | The line's `timestamp`, else the read time |
| Codex | It decodes with `payload.type == "error"` or top-level `type == "error"` | Always the read time |

…and its raw text, lower-cased, contains one of `usage limit`, `rate limit`, `limit reached`,
`rate_limit`, `usage_limit`, `429` or `529`. (`Quota429Observation.lineContainsQuotaLimitMarker`,
`ClaudeJSONLParser.detectQuota429`, `CodexJSONLParser.detectQuota429`; tests
`BurnTierTrackerTests.testQuotaLimitMarkerMatches`, `testQuotaLimitMarkerRejectsOrdinaryErrors`,
`testQuota429ObservationEmittedFromTokenlessFlush` in both watcher suites)

- **Both shapes are an unverified working assumption.** No real Claude Code or Codex limit line has
  been captured; the detectors are isolated so the shape can be corrected in one place when one is.
- **Live path only**, never the backfill.
- Observations ride on the meaningful-change signal (a flush with no requests still carries them).
  Whether one becomes a row is [polling](polling.md#a-refused-poll-is-not-an-exhausted-quota)'s
  rule; what the row is for is [capacity learning](capacity-learning.md).

## Counting tokens

Claude's four columns are separate quantities. Codex's cached input is part of its input, and its
reasoning output is part of its output. Every count follows from that.

| | Claude | Codex |
|---|---|---|
| **Displayed token count** | input + output + cache write + cache read | input + output |
| **Cache hit** | cache read ÷ (input + cache read + cache write) | cached ÷ input |
| **Recent rate and burn tier** | input + output | input + output |

- **Displayed count** (`DisplayedTokens.sum`) is the one rule for the popover, the History window,
  today's report, the surface split and the backfill log. Reason: Claude's cache reads are most of
  its tokens and leaving them out understated work many times over; adding Codex's cached slice
  counted it twice. (tests `DailyLocalReportReaderTests.testClaudeTotalsReconcileExactlyAcrossProjectsAndModels`,
  `testCodexTotalsUseInputPlusOutputAndCachedSubset`)
- **Cache hit** (`CacheHit.ratio`) is `nil`, shown as `—`, when the denominator is zero, never 0.
  For Codex the cached amount is read from **both** cache columns: older stored rows kept it in
  `cache_read_tokens`, newer ones in `cache_creation_tokens`, and no row uses both
  (`ModelTokenTotals.codexCachedInputTokens`). (tests
  `AttributionEngineTests.testCodexCacheHitIsIdenticalAcrossBothStorageConventions`,
  `testCodexCacheHitNilWhenNoCachedTokens`)
- **Claude's 1-hour cache-write share** is a part of the cache write, never added to a count. Only
  the estimated value reads it ([estimated value](estimated-value.md)). (test
  `testTierSplitLeavesTheDisplayedTokenColumnsUntouched`)
- **The recent rate is per minute over the last 2 minutes**, by each request's own time, so a
  late-read backlog does not look like a burst. (`AttributionEngine.tokensPerMinute`; test
  `testBackdatedCatchUpBurstDoesNotInflateRate`)

## Deduplication

| Tool | Key |
|---|---|
| Claude | `<message.id>_<requestId>`; `msg:<message.id>` without a request id; the bare request id without a message id; no key, no request |
| Codex | `<session id>_<line timestamp>_<last_token_usage.total_tokens>` |

- **The session is not part of a request's identity.** Resuming or forking a Claude session copies
  earlier lines into a new file under the new session id; the same billed message must not count
  twice. (test `SQLiteStoreTokenEventsTests.testLiveWriteSkipsSameKeyUnderAnotherSession`)
- **One response written as several lines shares one key** and counts once. Changing that would
  double nearly half of Claude's tokens. (test
  `ClaudeJSONLParserTests.testWithinSessionContentBlockRepeatsShareOneKey`)
- **The store skips a request whose key already exists for the tool under any session**, in the
  new or the older Claude key form, and then also skips its session update. The live write and the
  backfill share this check (`SQLiteStore.duplicateExists`). The table's own key (session, tool,
  key) with `INSERT OR IGNORE` is a second guard. (tests `testDuplicateDedupKeyIsIgnored`,
  `testLiveWriteSkipsWhenLegacyKeyRowExists`,
  `testBackfillSkipsKnownDedupKeyAcrossSessionIdConventions`, `testBackfillRerunInsertsNothing`)
- Codex re-records and fork copies carry new timestamps, so no key can catch them; the parser drops
  them ([above](#codex)).

## Surfaces and helpers

**Claude.** A main-agent line is `Claude Code`. A sidechain line is `Subagent · <attributionAgent>`,
or `Subagent · Unknown` without an agent name. Claude Desktop chat writes no session log, so
Claude has one surface. (`ClaudeJSONLParser.surfaceBucket`; tests `testSubagentNamedBucket`,
`testSubagentUnnamedBucket`)

**Codex.** Decided from the file's first line:

1. `thread_source == "subagent"` **and** a `parent_thread_id` → a helper:
   `Subagent · <nickname>`, or `Subagent · Unknown` without one. Reason: Codex also tags top-level
   threads `subagent`; the parent id is what separates a helper from the thread that spawned it.
2. Otherwise the originator decides (`CodexSurface.bucket`):

| Originator | Bucket |
|---|---|
| `Codex Desktop`, `codex_work_desktop` | `Desktop` |
| `codex_vscode` | `IDE extension` |
| `codex_cli_rs`, `codex_exec`, `codex-tui` | `CLI` |
| anything else | `Unknown` |

`source` is not used: the desktop app reports the editor shell's name for itself, so reading it
told desktop users they had used an editor extension. Editors cannot be told apart. An unmapped
originator stays `Unknown` until it is observed writing local sessions and added here; related
cloud originators are not mapped ahead of time. (tests
`testCodexDesktopWithVSCodeSourceIsDesktop`, `testCodexVSCodeOriginatorStaysIDEExtension`,
`testCodexTUIOriginatorIsCLI`, `testSubagentTagWithoutParentIsATopLevelThread`,
`testParentedThreadWithoutNicknameStaysSubagentUnknown`,
`testUnobservedWorkOriginatorFamilyStaysUnknown`)

**Helpers are not surfaces** (`SurfaceWorkSplit`). A bucket starting `Subagent · ` is a helper; the
rest are surfaces. A surface is *active* when its newest request is less than 8 minutes old;
`Unknown` is never active, because nothing could name it. Helper nicknames never reach the UI. How
state uses the active count: [state](state.md#the-states). (tests `SurfaceWorkSplitTests`)

## Codex's local databases

Two files Codex maintains in `~/.codex` are read, never written.
(`CodexSQLiteMetadataReader`)

| File | Query | Used for |
|---|---|---|
| `state_5.sqlite` | `model`, `cwd`, `source`, `git_branch` from `threads` where `rollout_path` is the log file's full path | `cwd` as the project; `model` as the fallback model. `source` and `git_branch` are read and unused |
| `goals_1.sqlite` | Whether any `thread_goals` row has `status = 'usage_limited'` | The over-quota signal on [Codex account](codex-account.md#from-payload-to-reading) |

How they are opened:

- **Directly through `sqlite3`, read-only, opened and closed on every call.** They are not
  Kvotar's database, so not through its store, and no connection is held against Codex's writer.
- **Named columns only, never `SELECT *`**, so added columns and tables change nothing.
- **Two attempts.** First a plain read-only open, the only mode that sees writes still in Codex's
  write-ahead log. Only if that fails with `SQLITE_CANTOPEN` (Codex has closed the file and its
  `-shm` side file is gone, which a read-only connection cannot recreate), open again with
  `immutable=1`; the main file is then the whole truth. Never `immutable` first: while Codex
  writes it would ignore the log. (tests `testClosedWALGoalsFileIsRead`,
  `testClosedWALStateFileIsRead`, `testOpenWALFileSeesUncheckpointedWrites`)
- **A missing file, missing table or failed query reads as no data** (`nil` or `false`). A missing
  file is silent; a failed open or query is logged at DEBUG only. (tests `testMissingDatabaseFilesFallBackGracefully`, `testMissingTableFallsBackGracefully`)
- **The thread lookup runs on every parse** of that file. When it finds nothing (the row is missing
  or locked), the last good answer for that file is used until a lookup succeeds again. Reason: the model changes when the user switches it
  mid-thread. The match is by `rollout_path`: the thread id is not the file name.

## Storing a request

One flush, one transaction (`SQLiteStore.writeTokenEvents`):

- **`local_sessions`, upserted per request:** earliest start time kept, last-seen time advanced,
  each metadata column takes the newest non-null value.
- **`local_usage_events`, one row per request,** with its own model and bucket. Readers use the
  request's values and fall back to the session's where a row has none (older rows).
- **A request with no tokens at all asserts no model.** Claude Code writes a zero-token placeholder
  (model `<synthetic>`) for a turn that failed before the API; it must not rename the session or
  reach a per-model row. (`TokenEvent.attributableModel`; test `testZeroUsageEventNeverAssertsAModel`)
- **Stored rows are permanent** ([storage](storage.md#permanent-means-permanent)); only the
  one-time repairs below changed them.
- `session_summaries` rows are written by the retention job for sessions idle over 24 hours
  ([storage](storage.md#the-retention-job)). Nothing in the app reads them.

## From requests to figures

`AttributionEngine.attribution(for:windowStart:)` turns the stored and in-memory data into one
tool's local figures (`LocalAttribution`). It returns nothing when there is no current session, no
estimated value in the last 30 days and no surface split.

| Figure | Meaning |
|---|---|
| Liveness timestamp | Newest of: request seen since launch, newest stored request, last local write. The stored term keeps a relaunch mid-session from reading idle; the write term covers Codex's late token lines. It is the one clock for "is local work alive" ([state](state.md#the-states) uses it with an 8-minute gap) and is stamped on each poll's `quota_series` row for the Elsewhere estimate. (tests `testLivenessSeededFromStoreSurvivesRestart`, `testFileGrowthKeepsTheToolLiveWithoutTokenLines`) |
| Recent rate | Tokens per minute over the last 2 minutes; `nil` when nothing landed |
| Local tokens in the last 2 minutes | The same sum. Passed to state and notifications, read by neither today ([state](state.md#known-gaps)) |
| Helper count | Helper buckets seen since launch whose newest request is under 5 hours old |
| Current session | The session seen most recently since the span start: project, model, bucket |
| Session count | Sessions last seen since the span start (a session that began earlier counts) |
| Surface split | Displayed tokens per bucket since the span start, with each bucket's newest request time |
| Model totals, cache hit, span value | Per-model sums since the span start; the value is [estimated value](estimated-value.md)'s |

**The span start**, in order (`PollCoordinator.pollOnceInner`, `handleLocalDelta`, `localDayGrain`):

1. Local midnight on the monthly layout when today has sessions; yesterday's midnight when only
   yesterday had; local midnight otherwise. Also local midnight on a Codex window whose start is
   not confirmed and that has no last window to recap.
2. The last ended five-hour window, on an empty window with one on record (the idle recap).
3. The window's own start ([quota readings](quota-readings.md#limits-and-windows)).
4. With none of these: the start of the most recently seen session, else 5 hours ago.

The poll path and the between-poll path use the same order, so the figures never change grain
between polls. The launch restore and the stale render use only steps 3 and 4 (see Known
gaps). How each figure is laid out: [popover](popover.md).

## The Elsewhere estimate

*Elsewhere* is defined on [product scope](product-scope.md#terms-a-newcomer-needs). This is how the
window's share is computed. (`OffMachineEstimator`, `WindowAttribution`)

**Inputs.** The current quota window's rows in `quota_series` (one per successful poll, picked by
reset time within 60 seconds), each with its used percent and the liveness timestamp at that poll;
and the times of all stored requests from the window start to now plus the guard. The window start
is the reset time minus the reported width.

**The walk.** Recomputed over the whole window on every successful poll (after the poll's row is
written) and, without a new reading, on every meaningful local change.

- **Rises only.** Each next reading adds `max(0, used − highest so far)`, so a reading that wobbles
  down and back counts once. (test `testDownwardWobbleDoesNotDoubleCount`)
- **An interval's rise is Elsewhere** when 180 seconds (the guard) have passed since its end and
  there is no request and no liveness timestamp in (its start, its end + 180 s]. Everything else is
  **This machine**: requests or a liveness mark present, or still inside the guard. The start is
  open: a request at exactly the start belongs to the interval before. (tests
  `testZeroTokenIntervalBanksExactly`, `testGuardDefersSettlement`,
  `testActivityMarkAtIntervalStartDoesNotBlockSettlement`, `testActivityMarkInsideTheGuardBlocksSettlement`)
- **The guard** outwaits a call still running at the boundary, whose usage is written when it ends.
- **The leading slice** (used percent at the first reading of the window) is **This machine** at
  once if any request or liveness mark lies in [window start, first reading + 180 s]. It is
  **Elsewhere** if there is none, the guard has passed, and the app's launch records show it ran
  from at or before the window start to the first reading (sleep counts as running). Otherwise it
  stays **Not observed**. Pending is not This machine here: the span was never watched. The
  coverage rule holds even though the launch backfill now reads logs written while the app was
  quit; the maintainer confirmed it on 2026-10-04, to be revisited on evidence. (tests
  `testLeadingSliceWithLocalTokensIsLocal`, `testLeadingSliceLowerBoundIsClosed`,
  `testLeadingSliceStaysUnattributedInsideTheGuard`, `testLiveJuly29WindowStaysUnattributedWhenAppWasQuit`,
  `testSleepInsideLeadingSliceStillCounsAsCovered`, `testRelaunchInsideLeadingSliceBreaksCoverage`)
- **Total** is the highest reading seen. **Not observed** is total minus Elsewhere minus This
  machine, so the three always add up to the total.
- **The total is a floor** (`closeObserved == false`, shown with `≥`) when the window has ended and
  the last reading was more than 300 seconds before its reset. (tests
  `testUnobservedCloseMarksTheTotalAsAFloor`, `testCloseObservationToleranceBoundary`)

Rules with reasons:

- **Elimination, never conversion.** An Elsewhere share is an exact account rise in an interval
  with no local trace; tokens are never converted into percent. Reason: the token-to-percent
  weights proved unstable.
- **In doubt, This machine.** Elsewhere work that overlaps local activity is counted as This
  machine. Accepted: it is invisible, not overstated.
- **Liveness is evidence of work, not an amount.** A mark moves a rise between buckets and never
  changes the total. Reason: a Codex window worked end to end otherwise read mostly Elsewhere,
  because its token lines landed in later intervals. (tests
  `testSept3WindowWithMarksResolvesToThisMachine`, `testActivityMarksNeverMoveTheTotal`)
- **Late lines self-heal**, both ways, on the next recompute; there is no clamp, which would freeze
  a wrong answer. (test `testLateJSONLFlipsProvisionalIdleToLocal`)
- **Between polls it can only settle**, never invent: the total cannot rise without a reading.
  (test `testCurrentMaySettleButNeverInvents`)
- **Unknown data settles nothing.** A failed request read, or no database (then an in-memory
  series), leaves every interior rise as This machine (the leading
  slice stays Not observed unless a liveness mark resolves it). No series at all makes the whole reading Not
  observed.
- **No rows are written.** The database is the state; a per-tool cache only speeds the next call.
  After a restart an empty-window poll recomputes the newest stored window.
- **The window width after a restart** falls back to five hours, because these rows were read
  without their width; see [quota readings](quota-readings.md#known-gaps).

The Off-machine burn *state* is [state](state.md#the-states)'s; the turn-end poll that gives the walk
clean intervals is [polling](polling.md#extra-polls)'s; the monthly split is
[credits and monthly limits](credits-and-monthly-limits.md)'s.

## Today's local report

The data behind the popover's `LOCAL ACTIVITY · TODAY` section (`DailyLocalReport`,
`DailyLocalReportReader`, `SQLiteStore.dailyLocalRead`):

- **The day is [local midnight, now).** Calendar arithmetic only, never `+ 86,400 s`, so the
  23-hour and 25-hour days and a time-zone change are right; a request dated in the future is left
  out. (`LocalDayPolicy`; tests `LocalDayPolicyTests`)
- **One read** gives project × model cells, bucket × originator cells and the session count, so
  they describe the same moment and always reconcile.
- **Tokens** follow the displayed-count rule; a cell with none is dropped. The total is the sum of
  the project rows; each project is the sum of its model rows.
- **Sessions** (Claude) or **threads** (Codex): distinct sessions with at least one request that
  carried tokens today. A session begun yesterday counts once. (tests
  `testSessionBegunYesterdayWithUsageTodayCountsOnce`,
  `testZeroUsagePlaceholderEarnsNoSessionNoRowNoModel`)
- **Projects** are grouped against every working directory ever stored for the tool, not only
  today's, so a repository keeps one identity. The rule is `ProjectGrouping.canonical`: the longest
  stored root that contains the path. A temporary folder, the root or a home folder is
  `(no project)`. (test `testGroupsAgainstTheProviderWideStoredPathSetNotJustToday`)
- **Models** come from each request, falling back to its session; none is `Unknown model`. Tokens
  are never dropped for want of a name. (test `testUnknownProjectAndUnknownModelRetainTheirTokens`)
- **Apps:** a helper's tokens go to the app that spawned it (Codex: through its session's
  originator; Claude: `Claude Code`); a request without a bucket is `Unknown`. (tests
  `testCodexHelperThreadsCountInsideTheAppThatSpawnedThem`, `testClaudeHelpersFoldIntoClaudeCode`)
- **Shown rows:** the top two projects by tokens, plus the project with the newest request if it is
  not among them; the rest is a count. Equal tokens sort by name; equal recency goes to the
  higher-ranked project. (tests `testSelectionOneTwoThreeAndMany`,
  `testEqualRecencyBreaksByRankAndEqualTokensByName`)
- **A failed read is never an empty day.** The reader throws; the last good report is kept and
  shown with its date. (tests `testFailedReadThrowsInsteadOfReturningZeros`,
  `testReportStateExposesRetainedReportOnFailure`)
- **When it is read:** at launch; after every poll, whatever its outcome; when the popover
  opens; on a meaningful local change; after each tool's backfill and again after the repairs;
  2 seconds after local midnight; on wake; when the time zone or clock changes. One read per tool
  at a time; a request during a read runs once after it. A read is local only and never causes a
  poll. (`PollCoordinator.refreshDailyReports`, `pollOnce`)

What the section's figures mean (`DisplayFormatter.localActivitySection`; tests
`DisplayFormatterLocalActivityTests`):

- The summary names the collector (`Claude Code` or `Codex`), not "all local apps", and gives the
  day's tokens and sessions or threads. On a day with nothing it says so instead of printing zeros.
- Codex lists the day's apps only when there are two or more; Claude never does.
- The recent rate shows only while the figures it came from are under 2 minutes old; otherwise `—`.
- The source tag dates the newest request today: how fresh the evidence is, not whether the read
  worked.
- The value rows are [estimated value](estimated-value.md)'s.

## The one-time repairs

Each runs once, after the backfill, on the same background task, behind a `settings` key written
when it finishes. Each re-parses the logs with today's parser and changes only rows a clean parse
disagrees with. Why these are allowed to change permanent rows:
[storage](storage.md#permanent-means-permanent). (`PollCoordinator`)

| Order | Key | Logs read | What it does |
|---|---|---|---|
| 1 | `jsonl_attribution_enrichment_done_<tool>` | Last 90 days | Fills a request's model and bucket where empty. Never overwrites, never changes a token count. Claude then gives a session named `<synthetic>` the model of its last request with tokens, or none |
| 2 | `jsonl_reemission_cleanup_done_codex` | All | Deletes Codex rows a clean parse no longer yields (stored re-records) |
| 3 | `jsonl_surface_repair_done_codex_d95` | All | Rewrites a Codex request's bucket where the current rule disagrees, then sets each session's bucket from its newest request. No token count changes |
| 4 | `jsonl_forked_history_cleanup_done_codex` | All | Deletes inherited history from fork-marked Codex files only, and sessions left empty |

- **Order:** fill, delete, rewrite, delete, as numbered. Deletions run after the backfill's
  inserts and the fill, so a deletion never removes a row an earlier sweep was about to justify.
  The bucket rewrite runs after the re-record cleanup, so it never relabels a row about to be
  deleted. The fork cleanup runs last because it only deletes.
- **Bounds on deletion:** rows from the last 10 minutes before the sweep are never touched (a line
  read live during the sweep is not stale). The re-record cleanup skips a session, with a warning, where it
  would delete more than 5 rows and more than a fifth of its rows older than that cutoff. The fork cleanup has no such
  limit, because a fork can be all copy; it is bounded to fork-marked files instead, listed from
  their first lines, so a file whose clean parse yields nothing is still named. (tests
  `testReconcileCodexReEmissionsSkipsSessionOnMassDeletion`,
  `testReconcileForkedThreadHistoryDeletesInheritedRowsAndEmptiedSessions`)
- A crash before the key is written runs the repair again; every repair is safe to repeat.
- A file deleted since it was stored cannot be re-read, so its rows keep their old answer.

## Rejected alternatives

From the private records; reopening any needs the maintainer's approval.

- **Reading only what appears after launch (no backfill).** Lost every line written while the app
  was not running, including gaps inside sessions it was watching.
- **A session-scoped Claude key.** Counted every resumed or forked message again.
- **The timestamp-bearing Codex key alone.** Caught none of the re-recorded turns.
- **Finding the parent thread of a fork at read time.** A stateful parser for a case never seen.
- **`thread_source: "subagent"` alone marks a helper.** Codex writes it on top-level threads too.
- **Reading `source` to tell desktop from editor**, and **mapping unobserved originators ahead of
  time.**
- **Codex's per-line `rate_limits` block as a quota reading.** Sampled at local turns, so blind to
  work elsewhere; quota comes from the account ([Codex account](codex-account.md)).
- **`state_5.sqlite` as the only model source, read once per thread.** Missed model switches.
- **Watching all of `~/.codex`, and one file handle per file ever seen.** Exhausted handles.
- **Off-machine as account rise minus local token rate.** Needs a token-to-percent conversion that
  proved unstable.
- **Classifying each poll's rise at the time of the poll, with an 8-minute liveness proxy.** Could
  never correct itself and blended web work into local.
- **A local token rate as the idle test.** Claude Code writes a line when a turn completes, so a
  long turn read as idle.

## Known gaps

| Gap | Today | Proposed fix |
|---|---|---|
| Comments and records still say "zero backfill" | `OffMachineEstimator` (type and `unattributedPct` docs, leading-slice comment) says logs written while the app was quit are never read; the launch backfill reads them | Correct the comments only (the coverage rule stays) with the next change to that file |
| A failed backfill write is not retried | `JSONLBackfillReader` says a failed write is retried free next launch, but `runBackfill` moves the watermark after every sweep, so an unchanged file is not read again. The repairs write their key the same way | Count failed writes in the sweep summary and keep the old watermark (or skip the key) when any failed; a test |
| Directory change sources are unbounded | One file handle per directory under the roots, forever; Codex's `sessions` gains a folder per day | One file-system event stream per root, or bound directory sources the way file sources are |
| The quota-limit marker is broad | Any error line containing `429` or `529` anywhere (an id, a count) matches | Tighten to the real shape when a capture exists |
| Codex quota-limit lines use the read time | Claude uses the line's timestamp; Codex always the read time | Use the line's `timestamp` when it parses, as for requests; a test |
| Yesterday's midnight is computed as midnight − 86,400 s | `PollCoordinator.localDayGrain`, on the monthly layout; wrong by an hour on the day after a 23- or 25-hour day | Use `Calendar` arithmetic, as `LocalDayPolicy` does |
| Two render paths skip the day anchor and the recap | The launch restore and the stale render (`PollCoordinator`, the restore loop and `evaluateStaleness`) pass only the window start, so on a monthly layout or an empty window their local figures can cover a different span from the next poll's | Use `localDayGrain` and the recap on both paths, as the poll and between-poll paths do |
| The last-resort span can be days long | With no window, no day anchor and no recap, the span starts at the most recently seen session's start | Bound it (for example to local midnight), with evidence first |
| An incomplete first Codex line is not retried (unverified by a test) | `captureOriginator` runs once per new file, from the watcher's discovery hook; if `session_meta` has no newline yet, nothing is cached and `parseEvents` never retries, so that thread's live requests stay `Unknown` until the next launch's backfill | Retry `captureOriginator` in `parseEvents` while the file is uncached; a test |
| A new Codex field is dropped unseen | `cache_write_input_tokens` appears on some lines (zero so far) and is not decoded; nothing would notice if it became non-zero | Record a parse anomaly when it is non-zero |
| No app-level test for the watermark and repair order | `runBackfill`, the repair order and their keys in `PollCoordinator` are untested; the parts below them are tested | A test with an injected store and adapters |
| `session_summaries` has no reader | Written by the retention job, read nowhere in the app | Keep (permanent, small); give it a reader or retire the writer in an agreed issue |
| Stale code comments | Both local adapters: "a future consumer persists the stream"; `CodexLocalAdapter`: "Codex has no subagent concept"; `CodexJSONLParser`: refers to a `parseTokenLine` that does not exist | Fix with the next change to each file |

## Code and tests

Code:

- Watching and backfill: `Packages/KvotarCore/Sources/KvotarCore/Adapters/` (`LocalAdapter.swift`,
  `JSONLDirectoryWatcher.swift`, `JSONLBackfillReader.swift`); `App/PollCoordinator.swift`
  (`startJSONLBackfill`, `runBackfill`, the four repairs, `handleLocalDelta`, `writeQuota429Events`,
  `localDayGrain`, the daily report refresh).
- Parsing: `Packages/ClaudeAdapter/Sources/ClaudeAdapter/` (`ClaudeJSONLParser.swift`,
  `ClaudeLocalAdapter.swift`); `Packages/CodexAdapter/Sources/CodexAdapter/`
  (`CodexJSONLParser.swift`, `CodexLocalAdapter.swift`, `CodexSQLiteMetadataReader.swift`).
- Figures: `Packages/KvotarCore/Sources/KvotarCore/Attribution/`,
  `Packages/KvotarCore/Sources/KvotarCore/History/ProjectGrouping.swift`,
  `Packages/KvotarCore/Sources/KvotarCore/Forecast/OffMachineEstimator.swift`.
- Storage: `Packages/KvotarCore/Sources/KvotarCore/Storage/` (`SQLiteStore+TokenEvents.swift`,
  `+Attribution.swift`, `+DailyLocal.swift`; `processRunningSince` in `+DiagnosticsCapture.swift`).
- Display: `Packages/KvotarUI/Sources/KvotarUI/Model/DisplayFormatter+LocalActivity.swift`,
  `LocalActivitySection.swift`.

Tests:

- `Packages/KvotarCore/Tests/KvotarCoreTests/`: `JSONLDirectoryWatcherTests`,
  `JSONLBackfillReaderTests`, `BurnTierTrackerTests`, `AttributionEngineTests`,
  `SurfaceWorkSplitTests`, `OffMachineEstimatorTests`, `DailyLocalReportReaderTests`,
  `LocalDayPolicyTests`, `SQLiteStoreTokenEventsTests`, `HistoryReportReaderTests` (project grouping).
- `Packages/ClaudeAdapter/Tests/ClaudeAdapterTests/`: `ClaudeJSONLParserTests`,
  `ClaudeLocalAdapterWatcherTests`, `ClaudeLocalAdapterBackfillTests`, `ClaudeParseAnomalyTests`,
  `NoContentStoredTests`.
- `Packages/CodexAdapter/Tests/CodexAdapterTests/`: `CodexJSONLParserTests`,
  `CodexLocalAdapterWatcherTests`, `CodexLocalAdapterBackfillTests`, `CodexParseAnomalyTests`,
  `CodexSQLiteMetadataReaderTests`, `NoContentStoredTests`.
- `Packages/KvotarUI/Tests/KvotarUITests/`: `DisplayFormatterLocalActivityTests`.
