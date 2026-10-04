---
summary: Where Kvotar keeps its data and how — the one database file, its tables grouped by purpose and how long each kind of row lives, the retention job, the settings table, how migrations are numbered and pinned in tests, which code may write to disk, the copy-only AgentPilot import and the single-instance lock.
read_when: Adding or changing a table, a column or a migration (SQLiteStore+Migrations.swift); changing a retention rule (runRetentionCleanup, RetentionScheduler); adding a settings key or changing writeSetting; changing how SQLiteStore opens the database or what happens when it cannot; changing LegacyDataMigrator or PIDLock; adding a file writer to the R2 list in scripts/check_rules.sh.
---

# Storage

## Questions for owner

None.

## Decided

The maintainer ruled on these on 2026-10-04 (STEP_250; the second in STEP_253). The code does not
follow them yet; each has a row in *Known gaps* below, which a later build step closes.

1. **A lock-file failure is a lock error, not "another copy is running".** If `kvotar.pid` cannot be
   opened or written, the app reports a lock error and does not poll. It never runs unguarded as a
   possible second poller, and never takes the second-copy path (no hand-off, no quit, no conflict
   window) for it. Reason: two copies polling share one provider budget
   ([polling](polling.md)), and the user must see the real cause. Today `PIDLock.acquire` returns
   `.alreadyRunning(pid: -1)` on an open or write failure, and the app treats it as a second copy.
2. **A missing support folder is a lock error too.** If the Application Support folder cannot be
   found, the app reports a lock error and does not poll, as in Decided 1. Reason: without that
   folder there is no database either, so an unguarded run saves nothing and risks two pollers on
   one budget. Today `PIDLock.defaultPath` fails, the app logs an error and polls with no lock.

## About this page

This page is the specification for Kvotar's own storage. It replaces the private Implementation Baseline §17 (the storage baseline),
§17.1 (the table definitions) and §17.2 (the shared cleanup job), except their diagnostics parts,
which [diagnostics](diagnostics.md) already replaced, and §17's network paragraph, which
[credentials and privacy](../credentials-and-privacy.md) covers. §17.3 listed open questions about
provider reply shapes; those belong to the account pages, not here. Change this page in the same
commit as the code it describes.

IDs such as REV-nn or STEP_nnn in code comments are private record IDs;
[REFERENCES.md](../REFERENCES.md) explains them. The rules here stand without them.

What this page does **not** own:

| Topic | Page |
|---|---|
| What is never stored (prompts, code, transcripts, tool outputs, refresh tokens) | [AGENTS.md — the four safety rules](../../AGENTS.md#the-four-safety-rules) |
| What Kvotar keeps and reads, told to the user; how to remove it | [Credentials and privacy](../credentials-and-privacy.md) |
| The diagnostics tables (`raw_payloads`, `payload_shapes`, `parse_anomalies`, `app_lifecycle_events`) and the debug and capture settings | [Diagnostics](diagnostics.md) |
| Which poll table a refusal or a quota 429 goes to (`poll_health_events`, `quota_limit_events`), and the stored hold | [Polling](polling.md) |
| The launch restore of the last reading, and why a restored reading is stale | [Quota readings](quota-readings.md) |
| What happens when a second copy starts, and the message an AgentPilot conflict shows | [App lifecycle](app-lifecycle.md) |
| The `kvotar` CLI's commands | [CLI](cli.md) |
| Finding and parsing session logs, the backfill and its one-time repairs | [Local usage](local-usage.md) |

## Where the data lives

| File | What it is |
|---|---|
| `~/Library/Application Support/Kvotar/kvotar.db` (with `-wal` and `-shm`) | The database. Everything on this page except the two files below |
| `~/Library/Application Support/Kvotar/kvotar.pid` | The single-instance lock |
| `~/Library/Application Support/Kvotar/agentpilot-migration.json` | The AgentPilot import receipt |
| `~/Library/Application Support/Kvotar/analysis/` | The CLI's separate analysis database, built from imported diagnostics bundles. The app never opens it |

(`ProductIdentity.swift`: `applicationSupportDirectory`, `databaseFilename`, `pidFilename`,
`migrationReceiptFilename`; `KvotarCLI/Import.swift` for the analysis folder)

- **One location for every build.** A Debug build and the installed app share the folder, the
  database and the lock, so only one runs at a time. The app has no path override.
- **The app is not sandboxed** (`App/Kvotar.entitlements`), so the CLI reads the same folder
  without an app-group entitlement.
- **Outside the database:** Sparkle keeps its automatic-check setting in user defaults
  (`App/UpdaterService.swift`); launch at login is the system's `SMAppService` state.
- Logs are files under `~/Library/Logs/Kvotar/`; see [ARCHITECTURE.md](../../ARCHITECTURE.md#logging).

## One store, one connection pool

- **All access goes through the `SQLiteStore` actor,** which owns one GRDB `DatabasePool` in WAL
  mode. Reason: one place for every query, and the CLI can read the file while the app writes.
- **A busy database waits up to 5 seconds** (`busyMode = .timeout(5)`) instead of failing at once.
  Reason: most write callers use `try?`, so an instant `SQLITE_BUSY` during a CLI write would
  silently drop a poll, a notification row or token events.
- **Foreign keys are on for every connection** (`PRAGMA foreign_keys = ON`). Today only
  `local_usage_events` → `local_sessions` uses one.
- **Timestamps are stored as `Int` unix seconds.** See [PATTERNS.md](../../PATTERNS.md#sqlite-access-baseline-17).
- **Write failures are logged by the store** and then thrown. Callers may ignore the error; the
  log line is the record.
- **The app runs without storage rather than not at all.** If the AgentPilot import fails, or the
  database cannot be opened or migrated, the app logs it and runs with no store: polling and the
  menu bar work, and nothing is saved or restored for that launch. (`App/AppDelegate.swift`)

(`SQLiteStore.swift`)

## Who may write to disk

Only the writers listed under R2 in [safety checks](../safety-checks.md) may write files; a new
writer fails `make check`.

In the app, only `SQLiteStore` and `LegacyDataMigrator` import GRDB. The CLI's `AnalysisStore`
also does, for its own separate database.

Who touches `kvotar.db`:

| Who | How | Migrates |
|---|---|---|
| The app | Opens read-write at launch | Yes, every launch, before any read or write |
| The CLI, most commands | `SQLiteStore.openReadOnly` | Never |
| The CLI, `debug --enable`/`--disable` and `capture --disable` | `SQLiteStore.openReadWrite`; writes `settings` rows (and `capture --disable` deletes captured replies) | Never |

The CLI never migrates, because the running app owns the schema and a CLI migration would race
it, and never creates the database. (`SQLiteStore.init`, `openReadOnly`, `openReadWrite`) The
commands belong to [CLI](cli.md) and [diagnostics](diagnostics.md#cli-commands-today).

## Tables by purpose

22 tables. "Kept" is what the code deletes, not a promise about disk size.

| Purpose | Table | One row is | Kept | Meaning owned by |
|---|---|---|---|---|
| Account quota | `poll_snapshots` | One account-quota poll, as normalized | 2 hours; the newest row per tool always stays; rolled up before deletion | [Quota readings](quota-readings.md) |
| | `quota_series` | A slim copy of a poll whose [primary](quota-readings.md#the-vocabulary) window had a used percent and a reset, whatever its width (used %, reset, width, the secondary beside it, the last local activity) | Permanent | Quota readings; [local usage](local-usage.md) |
| | `model_limit_series` | One window of one model allowance, from one poll | Permanent | [Claude account](claude-account.md), [Codex account](codex-account.md) |
| | `history_rollups` | One tool-hour of `poll_snapshots`: min, max and last values | Permanent | Read by the [History window](history.md) and [capacity learning](capacity-learning.md) |
| | `accounts` | One tool's account email (plain text) and plan | Permanent, overwritten in place | [Claude account](claude-account.md), [Codex account](codex-account.md) |
| | `discontinuity_events` | An instant something changed, for example a limit, the plan, credits, a window reset, early reset, withdrawal or width change, a monthly rollover | Permanent | [Quota readings](quota-readings.md#resets) |
| Local usage | `local_sessions` | One Claude Code or Codex session: project folder, model, surface | Permanent | [Local usage](local-usage.md) |
| | `local_usage_events` | One request's token counts | Permanent | [Local usage](local-usage.md) |
| | `session_summaries` | One session's totals, written once it has been idle 24 hours | Permanent | [Local usage](local-usage.md) |
| | `unpriced_models` | One model the price table did not know | Permanent | [Estimated value](estimated-value.md) |
| Polling | `poll_health_events` | One refused or failed poll of Kvotar's own | 90 days | [Polling](polling.md#a-refused-poll-is-not-an-exhausted-quota) |
| | `quota_limit_events` | One quota 429 seen in a session log | Permanent | [Polling](polling.md#a-refused-poll-is-not-an-exhausted-quota); [capacity learning](capacity-learning.md) |
| State and alerts | `state_transitions` | One change of state | 90 days | [State](state.md) |
| | `notification_events` | One notification sent | 90 days | [notifications](notifications.md) |
| | `forecast_log` | One forecast, with what was on screen then | Permanent | [Forecast](forecast.md) |
| | `popover_opens` | One open of the popover or the app window: tab and the states shown | Permanent | [popover](popover.md#the-glance-row) |
| Settings | `settings` | One key and its text value | Permanent | [The settings table](#the-settings-table) |
| | `settings_changes` | One settings write, old value to new | Permanent | The settings table |
| Diagnostics | `raw_payloads`, `payload_shapes`, `parse_anomalies`, `app_lifecycle_events` | | See [diagnostics](diagnostics.md#where-it-is-stored-and-for-how-long) | [Diagnostics](diagnostics.md) |

Who writes:

- **One poll is one transaction.** `writePoll` upserts `accounts` (only fields the poll carried),
  appends the `poll_snapshots` row, the `quota_series` row (only when the primary window has a
  used percent and a reset) and a `model_limit_series` row per reported model window. A failure
  rolls back all of them. (`SQLiteStore+Poll.swift`)
- **The account email is stored in plain text** in `accounts.email`, for both tools (maintainer's
  ruling, 2026-10-04). Reason: the launch restore shows it in the popover header before the first
  poll, and [credentials and privacy](../credentials-and-privacy.md#what-kvotar-keeps) tells users
  the database keeps it. Logs still write it as `<redacted>`. The old "redacted or hashed" wording
  is retired.
- `quota_series` and `model_limit_series` use `INSERT OR REPLACE`, because two polls can land in the
  same second and a key clash must not roll back the poll.
- `StateEngine` writes `state_transitions` and `discontinuity_events`; `NotificationEngine` writes
  `notification_events`; the retention job writes `history_rollups` and `session_summaries`.

**Why `poll_snapshots` is short-lived and the series permanent.** A snapshot row is wide and arrives
about every two minutes per tool. The permanent tables keep only what a later question needs:
window boundaries, an hourly summary, and the model allowances (`model_limit_series`, written on
every successful poll that reports one, whether or not a five-hour window runs).

## Store observations, not conclusions

A stored row records something measured, or what the app decided, said or showed at that moment.
It never stores a conclusion as if it were the quota's own history. The test: if a threshold or
formula changes next month, does this row become false? A used percent stays true; a stored
"elevated" on a quota row would not.

The app's own decisions are allowed as dated facts about the app: `state_transitions` (the state it
entered), `notification_events` (what it sent), `discontinuity_events` (what it detected),
`forecast_log` (its forecast, which is graded later, and the state on screen when it was made) and
`popover_opens` (what was shown). None of them is read as the quota's own history; that is
`quota_series` and `history_rollups`.

Two more rules with the same root:

- **No backfill.** A new column starts `NULL` on old rows. Nothing is copied from a neighbouring
  row or from today's reading, because that would invent a past observation. Readers treat `NULL`
  as "not recorded".
- **Retention is part of a read's contract.** Code that reasons about a past state must read a
  table that keeps rows at least as long as that state lasts. A "last window" read from
  `poll_snapshots` vanishes after two hours, because during an idle stretch its surviving row has no
  window. Read `quota_series`, `history_rollups` or the local tables instead.

## The retention job

`SQLiteStore.runRetentionCleanup` runs these steps in **one transaction**:

1. **Roll up, then purge.** Fold the `poll_snapshots` rows that step 2 will delete into
   `history_rollups`, one row per tool and UTC hour, with the plan from `accounts`. An hour is purged
   across up to three runs, so the write merges (min, max, count, and "last" only when newer).
2. **Delete `poll_snapshots` older than 2 hours,** except the newest row (highest id) per tool. That
   row stays for the launch restore and is rolled up once a newer row replaces it.
3. **Summarize idle sessions:** every `local_sessions` row last seen more than 24 hours ago gets a
   full recomputed `session_summaries` row. A session that resumes is summarized again next time.
4. **Delete after 90 days:** `poll_health_events` and `state_transitions` by `timestamp`,
   `notification_events` by `fired_at`.
5. **Delete `raw_payloads` older than 24 hours** ([diagnostics](diagnostics.md)).

Reason for steps 1 and 2 sharing one transaction and one `WHERE` clause: nothing leaves
`poll_snapshots` without leaving its summary behind.

**When it runs:** after the first poll of the launch completes (any tool, any outcome), so it never
races the popover's first fill; then every 30 minutes. A failed run is logged and the schedule
continues. (`PollCoordinator.startRetentionIfNeeded`, `RetentionScheduler`)

## Permanent means permanent

Every table not named in the retention job is permanent: no scheduled job deletes from it. Reason:
these rows hold no prompt or content, they are small, and a
deleted observation cannot be recovered when a later question needs it.

The exceptions, all one-time corrections of rows that recorded nothing real:

| Where | What it deleted | Why it was allowed |
|---|---|---|
| Migration `v11_quota_ceiling_floor` | `quota_limit_events` below 50 % used | A "limit reached" at 5 % cannot be a real limit, and the ceiling resolver takes the minimum, so one bad row would pin it forever. Nothing reads the table today ([capacity learning](capacity-learning.md#dormant-today)) |
| Migration `v12_unanchored_window_cleanup` | Every Codex `window_reset` row in `discontinuity_events` and every Codex `window_reset_post` row in `notification_events` stored until then | The reset time moved on every poll while nothing was used, so each poll looked like a rollover and every such row was false |
| Migration `v16_duplicate_event_cleanup` | `local_usage_events` the app stored twice under two of its own naming schemes, and `local_sessions` left empty | One turn, two rows |
| Migration `v19_fixture_session_cleanup` | Seven Codex sessions that were Kvotar's own test fixtures, by exact id, from `local_usage_events`, `local_sessions` and `session_summaries` | They were never anyone's work |
| One-time sweeps: `SQLiteStore.reconcileCodexReEmissions` and `reconcileForkedThreadHistory`, called from `PollCoordinator.runCodexReEmissionCleanup` and `runCodexForkedHistoryCleanup` | Codex `local_usage_events` a clean re-parse no longer produces (re-emitted lines; history copied into a forked thread); the fork sweep also deletes `local_sessions` it empties | Second copies of turns already stored. Each ran once behind a `jsonl_*_done_codex` setting |

Two migrations deleted rows that were not observations: `v13_drop_persisted_poll_base` removed a
setting no code reads any more, and `v20_time_limited_diagnostics` removed stored reply bodies,
cleared the reply columns of `poll_health_events` and switched capture off
([diagnostics](diagnostics.md)). Neither wrote a `settings_changes` row.

A new exception must be bounded exactly (ids or a fixed literal, never a pattern that could match
real rows, never a constant the app may later tune), delete child rows explicitly rather than by
cascade, and say in the code why the rows recorded nothing. This is stricter than the early
cleanups: `v12` deleted by tool and type alone, and `v13` and `v16` match with `LIKE`. `v19`, with
exact ids, is the pattern to follow.

The two one-time Codex sweeps are narrow exceptions (maintainer's ruling, 2026-10-04). Each runs
once behind its `settings` flag and touches only rows older than 10 minutes before the sweep; the
re-emission sweep skips a session where it would delete more than a fifth of the rows, and the fork
sweep reads only fork-marked files. They are **not** permission for routine deletion: any new
deletion from a permanent table is a migration that follows the rule above.

## The settings table

One row per key: `key` (primary key), `value` (text, may be `NULL`), `updated_at`.
(`SQLiteStore+Settings.swift`)

- **Write through `writeSetting`.** It upserts the row and, in the same transaction, appends a
  `settings_changes` row with the old and new value. A write that changes nothing is skipped: no
  update and no audit row. Reason: `INSERT OR REPLACE` alone erased the history of a setting.
- **An absent row means the default.** Each reader defines its own default. Store values as text;
  the convention per key is the owner's (`"1"`/`"0"`, `"true"`/`"false"`, unix seconds, JSON).
- **Raw SQL in a migration bypasses the audit.** A migration that changes a value a person chose
  writes its own `settings_changes` row, as `v21_retire_menu_bar_modes` does.
- **A key that might ever hold something sensitive** must log its change with both values `NULL`.
  No key does today, so no such branch exists.

The keys in use, by owner:

| Key | Owner |
|---|---|
| `schema_version` | This page ([Migrations](#migrations)) |
| `debug_mode_enabled`, `diagnostics_capture_enabled`, `diagnostics_capture_expires_at` | [Diagnostics](diagnostics.md) |
| `poll_cooldown_until.<tool>` | [Polling](polling.md#the-hold) |
| `onboarding_completed` | [First-run window](first-run-window.md) |
| `notification_<group>_enabled` (`at_risk`, `fast_burn`, `over_quota`, `window_reset`), `notification_project_name_enabled` | [First-run window](first-run-window.md); [notifications](notifications.md) |
| `block_episode.<tool>`, `nearly_spent.<tool>.<limit>`, `ladder.<tool>.<limit>` | [notifications](notifications.md) |
| `menu_bar_display_mode`, `reminder_episode.<tool>.<limit>` | [menu bar](menu-bar.md) |
| `last_open_snapshot_<tool>` | [explanations](explanations.md) |
| `monthly_attrib_accum_<tool>` | [Credits and monthly limits](credits-and-monthly-limits.md) |
| `jsonl_backfill_watermark_<tool>`, `jsonl_attribution_enrichment_done_<tool>`, `jsonl_reemission_cleanup_done_codex`, `jsonl_forked_history_cleanup_done_codex`, `jsonl_surface_repair_done_codex_d95` | [Local usage](local-usage.md) |

## Migrations

Schema changes go through GRDB's `DatabaseMigrator`, registered in one function,
`SQLiteStore.registerMigrations` (`SQLiteStore+Migrations.swift`). The app applies every
unapplied migration at launch, before the first read or write. GRDB records each applied
identifier in its own `grdb_migrations` table; the newest one is what logs, `kvotar doctor` and
diagnostics bundles report (`latestSchemaMigration`).

**Today the schema is at `v25_model_limit_series`, and `schema_version` is `"25"`.**

### Rules for a new migration

1. **Append only.** Add the new migration at the end of `registerMigrations`. Never edit, reorder,
   rename or remove one that has shipped. Reason: GRDB keys on the identifier string, so a database
   that already ran a migration never runs it again, and a renamed one runs twice.
2. **Name it `v<N>_<what_it_does>`,** with N one more than the highest in the file (the next is
   `v26_…`). The numbers skip 2 and 3: early databases may carry `v2_local_usage_reasoning_tokens`
   and `v3_codex_desktop_surface_bucket` from work whose migrations were never registered here, so `v4` was named past
   them. Do not reuse those names.
3. **End it by writing `schema_version`** = N, with `INSERT OR REPLACE INTO settings` (as every
   migration since `v1` does).
4. **Add, don't rebuild.** Add nullable columns with `ALTER TABLE … ADD COLUMN` (or GRDB's
   `alter(table:)`). Never rebuild `local_usage_events`: some older databases carry an extra column
   from the unregistered `v2`, and a rebuild would make machines behave differently. The only table
   rebuild so far is `v8`, of `poll_health_events`, for a `NOT NULL` SQLite cannot drop in place.
5. **No backfill** (see [above](#store-observations-not-conclusions)); a deletion follows
   [Permanent means permanent](#permanent-means-permanent); a value that must not drift is a
   literal, not a constant the app may tune later (as `v11`'s 50.0).
6. **Leave a retired column in place.** Dropping one costs a table rebuild for no behaviour gain.
7. **Test it from the previous version:** migrate a fresh file `upTo:` the previous identifier,
   insert old-shaped rows, run the full migrator, and check the rows survive unchanged and new
   columns are `NULL`. `SQLiteStoreQuotaSeriesTests` (`v23`, `v24`) and
   `SQLiteStoreModelLimitSeriesTests` (`v25`) are the pattern.

A migration changes storage, which is on the approval list in [VISION.md](../../VISION.md); it needs
the maintainer's agreement and a build step that updates this page.

### The version pin

These tests fail until they are moved to the new version. Change all of them in the migration's
commit:

| Test file (`Packages/KvotarCore/Tests/KvotarCoreTests/`) | Pins |
|---|---|
| `SQLiteStoreTests.swift` (`testMigrationCreatesAllTablesAndSchemaVersion`) | `schema_version` = `"25"`, and the list of every table (add a new table here) |
| `SQLiteStorePollHealthTests.swift` | `schema_version` = `"25"` |
| `SQLiteStoreQuotaSeriesTests.swift` (two tests) | `schema_version` = `"25"` |
| `SQLiteStoreTokenEventsTests.swift` | `schema_version` = `"25"` |
| `SQLiteStoreModelLimitSeriesTests.swift` | `schema_version` = `"25"` |
| `DiagnosticsBundleTests.swift` (`testManifestReportsIdentityCaptureAndSchema`) | The newest identifier, `"v25_model_limit_series"` |

## The AgentPilot import

Kvotar used to be called AgentPilot. On every launch, before the store opens,
`LegacyDataMigrator.migrateIfNeeded` decides whether to copy AgentPilot's database in. This stays
(maintainer's ruling).

In order:

1. Create Kvotar's folder; delete any leftover `.kvotar-migration-*` temporary copy.
2. **A Kvotar database exists:** an empty file is deleted and treated as absent. A non-empty valid
   one is kept, always (receipt `preservedExistingKvotarStore`). A non-empty invalid one is left
   untouched and the launch runs without storage.
3. **No Kvotar database, but a receipt says an earlier launch already set storage up** (any outcome
   except `cleanInstall`, or a receipt that will not decode): start empty and do not import
   (`cleanStartAfterPriorRun`). Reason: the database was deleted or moved on purpose, and
   re-importing would bring back data months stale.
4. **No AgentPilot database:** start empty (`cleanInstall`). A later launch can still import if
   AgentPilot data appears.
5. **Otherwise copy:** byte-copy AgentPilot's database and its `-wal` or `-journal` file to a
   temporary file (mode 600), fold the journal into the copy, check the copy (`PRAGMA quick_check`
   is `ok`, and it has `grdb_migrations` and `settings`), then move it into place in one step
   (`migrated`). The store then opens it and applies Kvotar's newer migrations.

Rules, with reasons:

- **The AgentPilot files are never opened or changed.** Only the copy is opened. Reason: AgentPilot
  must keep working if the person goes back to it, and opening a SQLite file can change it.
- **The copy happens while Kvotar holds the AgentPilot lock** (below), so AgentPilot cannot be
  writing.
- **Existing Kvotar data always wins.** An update never imports over it.
- **Deleting the receipt** forces a deliberate re-import on the next launch with no Kvotar database.

## The single-instance lock

Only one copy of Kvotar may poll, and Kvotar and AgentPilot must not both poll one account.
(`Lifecycle/PIDLock.swift`; taken at launch in `App/AppDelegate.swift`, before the store, polling and
UI)

- **An advisory file lock plus the PID as text.** `PIDLock.acquire` opens `kvotar.pid`, takes
  `lockf(F_TLOCK)` (closing the read-then-write race between two copies) and writes its PID, the
  only format released AgentPilot builds understand.
- **A live PID blocks; a dead one is reclaimed.** If the file names another process that is alive
  (or exists but cannot be signalled), acquisition fails. A PID whose process is gone is
  overwritten.
- **Release removes the file only if it still holds this process's PID,** then unlocks.
- **The AgentPilot lock is taken only if AgentPilot's support folder exists.** Kvotar then holds
  AgentPilot's `agentpilot.pid` too, with its own PID, so an old AgentPilot sees a live process and
  refuses to poll. If AgentPilot already holds it, Kvotar releases its own lock and stops. A clean
  install never creates AgentPilot's folder. This stays (maintainer's ruling).
- **No lock path, no guard.** If the support folder cannot be found, the app logs an error and runs
  unguarded. It must instead report a lock error and not poll (Decided 2).
- **A lock file that cannot be opened or written** must be reported as a lock error, and the app
  must not poll (Decided 1). Today `acquire` reports "already running" with PID −1, and the app
  acts as for a second copy.

What the user sees when the lock is taken, and how a second copy hands off to the first, is
[app lifecycle](app-lifecycle.md).

## Rejected alternatives

- **A current-state table per account** (`account_windows`). It would duplicate the newest
  `poll_snapshots` row and could drift from it. The newest row per tool is kept by retention
  instead.
- **A stored per-window attribution table** (`attribution_windows`). Computed on demand from
  `local_usage_events` instead.
- **`DatabaseQueue`.** It cannot share the file with the CLI.
- **Deleting local sessions after 30 days.** Shipped once, then made permanent: the rows hold no
  content, are small, and are what every later question about usage rests on.
- **Money stored in dollars, with the unit guessed from the tool.** Loses the currency. Monthly
  amounts are stored in the unit the provider gave (minor units plus a currency for money).

## Known gaps

| Gap | Today | Proposed |
|---|---|---|
| The version pin is copied into six test files | Each migration edits six files by hand | One test constant read by each test, plus a test that it matches the last registered migration |
| `extra_usage_is_enabled` cannot say "unknown" | `writePoll` writes `0` when a reading has no extra-usage data, including every Codex row; the restore always builds `isEnabled = false`. The column comment says Claude-only | Write `NULL` and restore `nil`, with a test; check the readers of a restored reading first |
| A lock-file failure takes the second-copy path | `acquire` returns `.alreadyRunning(pid: -1)` on an open or write failure, and the app hands off and quits, quits silently, or shows the conflict window | (Decided 1) Report a distinct lock error (not PID −1), show the real cause, do not poll; tests for the open and write failures |
| A missing support folder runs unguarded | `PIDLock.defaultPath` fails, the app logs an error and polls with no lock | (Decided 2) Report the same lock error and do not poll; a test with no support folder |
| Columns never written | `poll_snapshots.raw_payload_redacted`, `primary_window_limit`, `secondary_window_limit` (and the two rollup copies); `poll_health_events.response_headers_json`, `response_body` | Keep them (rule 6); mark them retired in the `v1` / `v4` comments with the next change to that file |
| `PATTERNS.md` names one GRDB carve-out | It omits `LegacyDataMigrator`, which `ARCHITECTURE.md` names | Add it with the next `PATTERNS.md` edit |
| The privacy page's file list is incomplete | [What Kvotar keeps](../credentials-and-privacy.md#what-kvotar-keeps) omits the import receipt and the CLI's `analysis/` folder | Add both with the next edit to that page |
| `RetentionScheduler` has no test | Start-after-first-poll and the 30-minute repeat are untested | Add a test with an injected interval with the next change to it |
| Stale code comments | `SQLiteStore+Retention.swift` (permanent list omits `unpriced_models`, `model_limit_series`); `SQLiteStore.swift` (says `debug` is the CLI's only write); `SQLiteStore+Migrations.swift` (header cites a private file; `v1` "Pre-Alpha keys", "AgentPilot-caused"; `v13` "fixed at 60s"); `RetentionScheduler.swift` ("Step 15") | Fix with the next change to each file. The "7-day" comment in `SQLiteStore+PollHealth.swift` is on [polling](polling.md#known-gaps) |

## Code and tests

Under `Packages/KvotarCore/Sources/KvotarCore/`: `Storage/SQLiteStore.swift` (opening),
`Storage/SQLiteStore+Migrations.swift`, `Storage/SQLiteStore+Poll.swift` (poll write, restore
read), `Storage/SQLiteStore+Retention.swift`, `Lifecycle/RetentionScheduler.swift`,
`Storage/SQLiteStore+Settings.swift`, `Storage/LegacyDataMigrator.swift`, `Lifecycle/PIDLock.swift`,
`ProductIdentity.swift`. Launch order: `App/AppDelegate.swift`. Writer list: `scripts/check_rules.sh`.

Tests in `Packages/KvotarCore/Tests/KvotarCoreTests/`: `SQLiteStoreTests` (tables, version,
settings audit, `v21`), `SQLiteStoreRetentionTests`, `SQLiteStorePollTests`,
`SQLiteStoreQuotaSeriesTests` and `SQLiteStoreModelLimitSeriesTests` (migrating from the previous
version), `SQLiteStoreTokenEventsTests` (`v19`), `SQLiteStoreQuotaLimitEventsTests` (`v11`,
`v13`), `LegacyDataMigratorTests`, `PIDLockTests`, `CredentialTreesUntouchedTests`; and
`Packages/KvotarCLI/Tests/KvotarCLITests/CredentialTreesUntouchedTests.swift`.

Checked against the code at 00ed0b1 + STEP_273
