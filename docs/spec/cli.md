---
summary: The `kvotar` command-line tool — its commands and shared options, what `doctor` and `status` print in text and JSON (the JSON field names are a machine contract), the version it reports, its exit codes and error output, how it is built and installed today, its own log file, and what it never does.
read_when: Adding or changing a `kvotar` command, flag or JSON field (Packages/KvotarCLI/Sources/KvotarCLI — Kvotar.swift, GlobalOptions, CLIOutput, Doctor, Status, StatusReader, CLIFormat, KvotarVersion, CLIRuntime); changing scripts/cli.sh or Packages/KvotarCLI/Package.swift; changing Logger.useLogFile; bumping the app version in project.yml.
---

# Command-line tool

## Questions for owner

None.

## Decided

The maintainer ruled on this on 2026-10-04 (STEP_259). The code does not follow it yet; its row in
*Known gaps* below names the change.

1. **`status --json` names a quota window by its width, and `monthly` means only the monthly
   limit.** `window` is derived from `primaryWindowSeconds` by the
   [quota readings](quota-readings.md#limits-and-windows) naming rule: `five_hour`, `weekly`,
   another whole number of days or hours named literally (`30_day`, `14_day`, `72_hour`), and
   `primary` for a width the rule makes no name claim for. With no width reported it stays
   `five_hour`. `monthly` is used only for the monthly limit (a separate credit or spend pool).
   Reason: today a script reading `five_hour` treats a seven-day or 30-day reset as a five-hour
   one, and a quota window and the monthly limit must never share one value. So a 30-day window is
   `30_day` in JSON where the screen says "Monthly". Readers on a weekly or 30-day primary will see
   the value change; every other account keeps today's value.

   | Case | Today | Ruled |
   |---|---|---|
   | Primary window 5 hours wide | `five_hour` | `five_hour` |
   | Primary window 7 days wide (weekly-only Codex) | `five_hour` | `weekly` |
   | Primary window 30 days wide (Codex low-allowance) | `five_hour` | `30_day` |
   | No primary percent, monthly limit only | `monthly` | `monthly` (unchanged) |
   | Primary window with no width reported | `five_hour` | `five_hour` (fallback) |

## About this page

This page is the specification for the `kvotar` command-line tool. It replaces the private
Implementation Baseline §10.8 (CLI log access) and the private build-step records for the CLI,
which never had a Baseline section. Change this page in the same commit as the code it describes.

IDs such as REV-nn or STEP_nnn in code comments are private record IDs;
[REFERENCES.md](../REFERENCES.md) explains them. The rules here stand without them.

What this page does **not** own:

| Topic | Page |
|---|---|
| Where the database is, which commands open it read-write, and why the CLI never migrates or creates it | [Storage — who may write to disk](storage.md#who-may-write-to-disk) |
| `debug`, `capture`, `logs`, `import` and the analysis database | [Diagnostics — CLI commands today](diagnostics.md#cli-commands-today) |
| Which state a tool is in, and how `status`'s state differs from the app's | [State](state.md#what-is-not-inferred-from-incomplete-evidence) |
| How a percent, a placeholder, a countdown or a clock is written, and where `CLIFormat` drifts from the app | [Display semantics](display-semantics.md#known-gaps) |
| When a reading is stale | [Quota readings](quota-readings.md#fresh-and-stale-readings) |
| Why the CLI must not poll | [Polling](polling.md) |
| The monthly runway rule behind `runway_days` | [Credits and monthly limits](credits-and-monthly-limits.md) |
| What the log may and may not contain | [Diagnostics — what the log never contains](diagnostics.md#what-the-log-never-contains) |

## What the CLI is

- **A separate Swift package executable, `kvotar`, not part of the app.** It depends on
  `KvotarCore`, swift-argument-parser and GRDB, nothing else. Reason: the app's build stays
  independent of it, and with no dependency on the adapters it cannot call a provider or read a
  credential. (`Packages/KvotarCLI/Package.swift`; [ARCHITECTURE.md](../../ARCHITECTURE.md#the-cli))
- **It reads what the running app saved; it never fetches.** `status` reports the newest saved
  poll for each tool. Reason: a second poller would spend the same provider allowance the app
  and the user's own tools share ([polling](polling.md)). (`StatusReader.read`)
- **It cannot use the app's display code.** `KvotarUI` is not a dependency, so `CLIFormat`
  restates the small part of the display grammar `status` needs. Where it drifts is on
  [display semantics](display-semantics.md#known-gaps). (`CLIFormat.swift`)

## Building and installing

- **`scripts/cli.sh` builds it and links it.** It runs `swift build` on `Packages/KvotarCLI`
  (debug by default; extra arguments such as `-c release` are passed through) and points
  `~/.local/bin/kvotar` at the freshly built binary, every run. It prints a note when
  `~/.local/bin` is not on `PATH`. Reason: a user-owned folder needs no `sudo`, and refreshing the
  link each run means it never serves an old binary.
- **Without the link:** `swift run --package-path Packages/KvotarCLI kvotar <command>`.
- **The app build does not produce it.** `make build` builds only the app, and the app bundle does
  not contain the CLI. There is no in-app installer.
- **Tests** run with every other suite in `make test` (`scripts/test.sh`, suite `KvotarCLI`).

## Commands and shared options

```bash
kvotar doctor                                    # can the CLI read the database?
kvotar status [--tool claude|codex]              # each tool's state, percent and reset
kvotar debug --enable | --disable | --status     # diagnostics
kvotar capture --disable | --status              # diagnostics
kvotar logs [--follow] [--level L] [--component C] [--tool claude|codex] [--since 30m]   # diagnostics
kvotar import --tester <id> <bundle>...          # diagnostics
kvotar --version
kvotar help <command>
```

The command list is `Kvotar.configuration.subcommands`. A new command registers there.
`debug`, `capture`, `logs` and `import` belong to
[diagnostics](diagnostics.md#cli-commands-today); this page owns only what they share below.

Every command takes the shared options through `@OptionGroup var global: GlobalOptions`:

| Option | Meaning |
|---|---|
| `--json` | Print the command's result as JSON instead of text |
| `--database <path>` | Use this database file instead of the app's (`SQLiteStore.expectedDatabasePath()`). The default path is computed, never created |

- **`--database` is how to point the CLI at a copy.** In tests and agent work, point it at a
  synthetic copy; [AGENTS.md](../../AGENTS.md#agent-notes) forbids copying a real database into a
  test, a log or a pull request.
- **`import` refuses `--database`** (except with `--print-queries`) instead of ignoring it, because it never touches the app's
  database (it has `--analysis-db`). (`Import.validate`;
  `ImportCommandTests.testTheAppDatabaseFlagIsRefusedRatherThanIgnored`) `logs` accepts and
  ignores it (see *Known gaps*).
- **`status --tool claude|codex`** limits the report to one tool; without it both are reported,
  Claude first (`Tool.allCases`). Any other value is a usage error. (`Status.validate`)

## Text and JSON output

Every command except `logs` builds one payload type that conforms to `CLIOutputPayload`: `Encodable` for JSON,
plus `humanText` for the terminal. `CLIOutput.print` prints one or the other. (`CLIOutput.swift`)

- **JSON is pretty-printed with sorted keys and unescaped slashes.** Reason: the same input gives
  the same bytes, so scripts and diffs are stable.
- **Field names are snake_case and are a machine contract.** Rename or remove one only with an
  agreed issue whose pull request changes this page. Reason: scripts read them.
- **A missing value is left out, not written as `null`.** Optional fields use the default
  `Encodable` behaviour, which omits `nil`.
- **Text cells never leak into JSON.** `StatusReport.Row` keeps its pre-rendered text cells out of
  `CodingKeys`. (`StatusRenderTests.testJSONKeepsUsedBasedUtilization`)
- The diagnostics commands' payloads (`DebugReport`, `CaptureReport`, `ImportReport`) follow the
  same seam; their fields are in those types. `logs --json` builds its own output outside the
  seam: one compact object per line (`LogLine.jsonLine`). `import --print-queries` prints text even
  with `--json`.

## `doctor`

Checks that the CLI can find and open the database, read-only. (`Doctor.swift`)

| Outcome | Text | Exit |
|---|---|---|
| File opens | `Kvotar database readable at <path> (schema: <newest migration>)` | 0 |
| No file | `Kvotar hasn't run yet — no database at <path>` | 1 |
| File exists, will not open | `Can't read Kvotar's database — is Kvotar running? (<path>)` | 1 |

JSON fields (`DoctorReport`):

| Field | Meaning |
|---|---|
| `database_readable` | `true` or `false`. Read this one |
| `database_path` | The path checked |
| `schema_migration` | The newest applied migration's identifier ([storage — migrations](storage.md#migrations)). Present only when readable and known |
| `reason` | `not_run_yet` or `open_failed`. Present only on failure |
| `message` | The text line above |

The schema read is best effort: if the file opens but the identifier cannot be read, `doctor`
still reports it readable, without `schema_migration`.

## `status`

Prints one line per tool from the newest saved poll. (`Status.swift`, `StatusReader.swift`,
`CLIFormat.swift`)

- **The state** comes from `StatusReader.read`, which classifies the saved row with no live burn
  data. How that differs from the app's own state is on
  [state](state.md#what-is-not-inferred-from-incomplete-evidence); do not restate it here.
- **Which limit the line reports:** the primary limit when it has a percent, else the monthly
  limit, else none. Weekly and per-model limits are never printed. (`CLIFormat.displayWindow`)
- **Stale** is the shared staleness test on the saved poll's time
  ([quota readings](quota-readings.md#fresh-and-stale-readings); `StateEngine.isStale`).

### Text

```text
CL  Healthy       42%  resets in 1h52m · 12s ago
CX  Pacing Only    ––  no active window · 3m ago
CL  Unknown       42%  resets in 1h52m · as of 9:47 pm
```

Columns: the tool prefix (`CL`, `CX`); the state label padded to 11 characters; the percent
**left**, right-aligned in four; a detail cell; the freshness suffix. The number forms, the
placeholders (`––`, `—`, `no data yet`, `no active window`, `no window open`) and the clock belong
to [display semantics](display-semantics.md#unknown-missing-and-stale). On a failure the line is
the `doctor`-style message instead.

State labels (`CLIFormat.stateLabel`):

| Label | States |
|---|---|
| `Healthy` | `healthy` |
| `Elevated` | `elevated`, `limit_ahead_of_pace`, `fast_burn_spike`, `off_machine_burn`, `multi_surface` |
| `At Risk` | `at_risk`, `bad_timing`, `limit_nearly_spent` |
| `Over Quota` | `over_quota`, `spend_control` |
| `Pacing Only` | `null_window` |
| `Unknown` | `idle_fallback` |

The map covers every state, though `status` can only reach those that need no live burn data.

### JSON

Top level (`StatusReport`):

| Field | Meaning |
|---|---|
| `tools` | One object per reported tool. Always present; empty on failure |
| `reason` | `not_run_yet` or `open_failed`. Present only on failure |
| `message` | The failure text. Present only on failure |

Each object in `tools` (`StatusReport.Row`):

| Field | Meaning |
|---|---|
| `tool` | `claude` or `codex` |
| `state` | The text label from the table above |
| `state_raw` | The state's code name (`AppState.rawValue`). Scripts should read this one |
| `window` | `five_hour` (the primary limit, whatever its width) or `monthly`. Absent when the tool has no saved poll, or has neither a primary percent nor a monthly limit. Decided 1 names the primary by its width |
| `utilization_pct` | Percent **used** (not left) of that limit, a number. Absent when unknown. It kept its name and meaning when the text column switched to percent left ([display semantics — by surface](display-semantics.md#by-surface)) |
| `resets_at` | That limit's reset, Unix seconds. Absent when unknown |
| `runway_days` | Monthly limit only: the value of `MonthlyLimit.runwayDays`. The rule, and when it has no value, are on [credits and monthly limits](credits-and-monthly-limits.md). Absent for the primary limit. When present, the text detail cell reads `runway ~17d` instead of a reset |
| `polled_at` | When the saved poll was taken, Unix seconds. Absent when the tool was never polled |
| `stale` | `true` when the saved poll is stale |
| `as_of` | The saved poll's clock time as text, present only when stale (see *Known gaps*) |

## Version

- **`kvotar --version` prints `<version> (<build>)`**, also after a subcommand. The values are
  compiled constants in `KvotarVersion`, because a bare package executable has no `Info.plist` to
  read them from. They are meant to match the app's `MARKETING_VERSION` and
  `CURRENT_PROJECT_VERSION` in `project.yml`, by hand; today they do not (see *Known gaps*).
- No JSON payload carries the version.

## Exit codes and errors

| Code | When | Where the message goes |
|---|---|---|
| 0 | The command did its job; `--help`; `--version` | stdout |
| 1 | The command ran and failed: no database (`not_run_yet`), the database would not open or read (`open_failed`), no app log for `logs`, any bundle failed in `import`, or an unexpected error | A command's own failure result goes to **stdout**, as text or as JSON with `reason`, so a `--json` caller always gets one JSON object. `logs` without a log file and an unexpected error write to stderr |
| 64 | Usage error: unknown command or option, a bad value (`--tool foo`), a wrong flag combination, or a refusal in `validate()` such as `capture --enable` | stderr, as `Error: …` plus usage, in text even with `--json` |

`ExitCode.failure` is 1; 64 is swift-argument-parser's code for a `ValidationError` or a parse
failure. (`throw ExitCode.failure` in each command; `CaptureCommandTests.testEnableExitsNonZero`)

## The CLI's log file

- **The CLI writes its own file, `~/Library/Logs/Kvotar/kvotar-cli.log`,** never the app's
  `kvotar.log`. Every command calls `CLIRuntime.bootstrap()` first, which calls
  `Logger.useLogFile(basename: "kvotar-cli")`. Reason: a CLI run must not rotate or interleave the
  running app's log.
- **It uses the app's log writer,** so it rotates by size the same way
  ([ARCHITECTURE.md — logging](../../ARCHITECTURE.md#logging)). Under tests it goes to a temporary
  folder (`Logger.logDirectoryURL`).
- **What it records:** `doctor`'s result, each failed database open or read with its path and
  error, the debug and capture switches, and each imported or failed bundle. `status` logs only a
  failed open or read. What any log line may contain is
  [diagnostics'](diagnostics.md#what-the-log-never-contains).
- `kvotar logs` reads the **app's** log, not this file. A Save Diagnostics bundle includes both
  ([diagnostics](diagnostics.md#save-diagnostics)).

## What the CLI never does

- **Never calls a provider and never reads a credential.** It has no adapter dependency and no
  network code. ([credentials — what is never done](credentials.md#what-is-never-done))
- **Never polls.** See *What the CLI is*.
- **Never migrates or creates the app's database.** Every command that opens it checks first that
  the file exists. The read-write rules are [storage's](storage.md#who-may-write-to-disk).
- **Never writes under `~/.claude` or `~/.codex`.** Besides its log and the database writes
  [storage](storage.md#who-may-write-to-disk) lists, its only file writers are the two `import`
  ones: `BundleReader` (expands a bundle to a temporary folder) and `AnalysisStore` (the corpus). `make check` fails on a new writer or a new process launch
  ([safety checks](../safety-checks.md#static-checks-make-check)), and
  `CredentialTreesUntouchedTests.testImportingABundleLeavesTheCredentialTreesAlone` checks that an
  import leaves a fake home's credential trees untouched.
- **Never turns diagnostics capture on** ([diagnostics](diagnostics.md#turning-it-on-and-off)).

## Rejected alternatives

- **A CLI that polls the provider itself.** It would be a second poller on the same allowance.
  `status` reads saved rows instead and labels old ones with `as of`.
- **Writing the app's log file from the CLI.** Each CLI run could rotate or interleave the app's
  history; the CLI got its own file.
- **A `remaining_pct` JSON field** when the text column switched to percent left. The JSON kept
  `utilization_pct` as used, and no field was added (`StatusRenderTests`).
- **Ignoring a meaningless `--database`.** `import` refuses it with directions instead.

## Known gaps

| Gap | Today | Proposed |
|---|---|---|
| The version is out of date | `KvotarVersion` says `0.2.0 (5)`; `project.yml` says `0.3.0` build `18`. Its comment points at the generated `.xcodeproj`, which is not committed. The CLI is in no release and not in the app bundle, so only a source build reports it | A `KvotarCLITests` test that compares `KvotarVersion` with `project.yml`; point the comment at `project.yml`, and bump both together |
| A primary window wider than five hours is reported as `five_hour` | `CLIFormat.displayWindow` labels any primary window `five_hour`, whatever its width; on a weekly-only or 30-day Codex primary `window` is wrong, and the text counts down in hours (the text part is on [display semantics](display-semantics.md#known-gaps)) | (Decided 1) Name the window by its width (`weekly`, `30_day`, other widths literally, `primary` with no name claim), keep `monthly` for the monthly limit only and `five_hour` as the fallback; tests with a seven-day and a 30-day primary and one with no width |
| An ended limit still shows its percent | The state is classified on a copy with ended limits cleared, but `displayWindow` reads the raw row: after the reset passes, the line shows the old percent and `—`, and JSON keeps the old `utilization_pct` and a past `resets_at`. The app shows an ended limit as having no percent ([display semantics](display-semantics.md#fresh-and-stale)) | Build the display window from `QuotaSnapshot.degradingExpiredWindows(now:)`; a test with a reset in the past |
| `as_of` in JSON is not yet in one fixed format | It is built by the human clock `CLIFormat.clock`: a 12-hour form whose month name follows the locale, with no year. Moving the human clock to the Mac's 12/24-hour setting ([display semantics](display-semantics.md#decided) Decided 1) would move `as_of` with it, though that ruling keeps CLI JSON in one fixed format | Give `as_of` its own fixed-locale formatter, separate from `CLIFormat.clock`, and a test that pins its form. `polled_at` stays the field scripts should read |
| `logs` ignores `--database` silently | It takes `GlobalOptions` but never opens the database | Refuse `--database` in `logs`, as `import` does |
| Every `status` read failure says "is Kvotar running?" | One `catch` covers a failed open and a failed query, both as `open_failed` | Separate a failed read from a failed open, if the owner accepts a new `reason` value |
| The JSON contract has no full test | Only `utilization_pct` and the absence of `remaining_pct` and text cells are tested; nothing pins the full field sets of `status` and `doctor`, the failure payloads or the exit codes (only `capture --enable` is checked, and only as non-zero) | One test per payload that compares the encoded key set with the tables above, and the two failure paths with a `--database` path that does not exist |
| Stale code comments | `Kvotar.swift` (product commands such as `forecast` "arrive in later steps"); `CLIOutput.swift` (a `--format prompt` that does not exist); `StatusReader.swift` (later `forecast`/`session`/`today` commands); `Status.swift` (a later "Phase B"); `CLIRuntime.swift` ("append-only"; the file rotates); `Logger.swift` ("the dormant CLI"); `KvotarVersion.swift` and `Package.swift` (a release-stage name and a private document line); `scripts/cli.sh` (an in-app installer "deferred to distribution/packaging"; delete the comment, since an installer would be new scope). The restore-parity comment is on [state](state.md#known-gaps) | Fix with the next change to each file |

## Code and test pointers

Under `Packages/KvotarCLI/Sources/KvotarCLI/`: `Kvotar.swift` (command list, version flag),
`GlobalOptions.swift`, `CLIRuntime.swift` (log file), `CLIOutput.swift` (text and JSON seam),
`KvotarVersion.swift`, `Doctor.swift`, `Status.swift`, `StatusReader.swift`, `CLIFormat.swift`;
the diagnostics commands `Debug.swift`, `Capture.swift`, `Logs.swift`, `Import.swift` with
`BundleReader.swift`, `AnalysisStore.swift` and `StarterQueries.swift`. Package:
`Packages/KvotarCLI/Package.swift`. Build and link: `scripts/cli.sh`. Shared pieces in
`KvotarCore`: `SQLiteStore.openReadOnly`, `openReadWrite`, `expectedDatabasePath`,
`readLatestPollSnapshot`; `StateEngine.classify`, `isStale`; `MonthlyLimit.runwayDays`;
`Logger.useLogFile`.

Tests in `Packages/KvotarCLI/Tests/KvotarCLITests/`: `StatusRenderTests` (percent left in text,
used in JSON), `CLIFormatTests` (not-started, absent and reset-less limits),
`CredentialTreesUntouchedTests`, and for the diagnostics commands `CaptureCommandTests`,
`ImportCommandTests`, `BundleReaderTests`, `AnalysisStoreTests`, `LogLineTests`.
