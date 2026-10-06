# ARCHITECTURE.md

The current state of the code, in one read. Why the sensitive parts are the way they are is in
[docs/decisions/](docs/decisions/).

## Packages and boundaries

```
App (composition root) ──► KvotarUI ──┐
        │                             ├──► KvotarCore ──► GRDB
        ├──► ClaudeAdapter ───────────┤
        └──► CodexAdapter ────────────┘
KvotarCLI ──► KvotarCore (+ swift-argument-parser)
```

| Unit | Owns | May not |
|---|---|---|
| `KvotarCore` | Data types, the protocols adapters conform to, the engines, polling policies, `SQLiteStore`, `Logger`, diagnostics | Import an adapter or UI package |
| `ClaudeAdapter` | Claude credential read, account quota calls, Claude Code session-log parsing | Import UI |
| `CodexAdapter` | Codex credential read, `codex app-server` client, web fallback, Codex session-log and local-database reading | Import UI |
| `KvotarUI` | `DisplayFormatter`, view models, SwiftUI views | Import an adapter |
| `App/` | Wiring: builds the adapters and injects them, schedules polls, owns the menu bar, windows, notifications and Sparkle | — |
| `KvotarCLI` | The `kvotar` tool: status, logs, doctor, the debug switch, turning capture off, bundle import | Call a provider, or turn capture on |

Outside the packages and `App/`:

| Path | What it is |
|---|---|
| `AppTests/` | App-level tests (the `KvotarTests` scheme). |
| `Resources/` | Bundled pricing table, third-party notices, brand assets. |
| `project.yml` | XcodeGen spec. The `.xcodeproj` is generated, never committed. |

Adapters are created in `AppDelegate` and handed to `PollCoordinator`. Engine code depends only on the
protocols in `KvotarCore/Adapters` (`AccountAdapter` for quota, `LocalAdapter` for session logs), so
tests inject mocks.

In the app, only the storage layer imports GRDB: `SQLiteStore` and `LegacyDataMigrator`. The CLI's
bundle importer also uses GRDB directly, for a separate analysis database the app never opens.

## Data flow

```
account adapters ─┐
                  ├─► PollCoordinator ─► StateEngine / ForecastEngine / NotificationEngine
local adapters ───┘          │                       │
                             ▼                       ▼
                        SQLiteStore            AppViewModel ─► DisplayFormatter ─► views
```

1. **Account adapters** fetch a quota snapshot (used %, resets, plan, credits) from the provider.
2. **Local adapters** watch the session-log folders and emit token events (counts, model, project
   folder, timestamps), debounced.
3. **`PollCoordinator`** (`App/`, main actor) schedules polls using the pure `PollBackoffPolicy`,
   writes each poll to the store in one transaction, and runs the engines.
4. **`StateEngine`** classifies each tool into one state from a fixed priority list (idle, spend
   control, over quota, at risk, bad timing, limit nearly spent, fast burn, elsewhere, multi-surface,
   elevated, limit ahead of pace, healthy, null window). States escalate at once. Calming down normally needs three
   calmer poll-triggered evaluations in a row; a window reset or removal, a drop to idle, and local
   activity resuming out of the Elsewhere state skip that wait.
5. **`ForecastEngine`** turns successive used-% readings into a burn rate and a runway.
6. **`NotificationEngine`** decides which notification, if any, fires per evaluation (at most one per
   tool per cycle), with caps and cooldowns recorded in the database.
7. **`AppViewModel`** holds the latest state per tool; **`DisplayFormatter`** turns it into the
   strings, colours and rows the menu bar and popover show (`HistoryDisplay` does the same for the
   History window). Views render what they are given and compute nothing.

## Concurrency

Engines, adapters and the store are Swift actors: `SQLiteStore`, `StateEngine`, `ForecastEngine`,
`NotificationEngine`, `AttributionEngine`, `EstimatedValueEngine`, `LimitsDatabaseAdapter`,
`JSONLDirectoryWatcher`, `RetentionScheduler`, the four adapters, and two estimators. `PollCoordinator` and
`AppViewModel` are `@MainActor`. Policies (`PollBackoffPolicy` and its siblings in
`KvotarCore/Polling`) are pure value types: no I/O, clock and jitter injected.

The Codex RPC client is a class, not an actor, because the subprocess's output arrives on a dispatch
queue.

## Storage

- One SQLite file, `~/Library/Application Support/Kvotar/kvotar.db`, through GRDB's `DatabasePool` in
  WAL mode, so the CLI can read it while the app writes.
- Schema changes go through GRDB's `DatabaseMigrator` in `SQLiteStore+Migrations.swift`; migrations
  are append-only.
- Tables, in groups: poll snapshots (kept two hours, then rolled into permanent hourly summaries by
  the retention job; the newest row per tool is always kept);
  local sessions and token events (permanent); poll health and quota-limit events (kept apart, see
  [polling](docs/decisions/0003-polling-and-rate-limits.md)); state transitions, notification log
  and settings; a forecast log and quota series for later grading; time-limited diagnostics capture.
- A retention job runs at launch and every 30 minutes.

## Where policy lives

| Policy | Owner |
|---|---|
| Poll cadence, 429 handling, holds | `PollBackoffPolicy` (Core), applied by `PollCoordinator` |
| Credential reading and the expiry gate | `KeychainTokenProvider`, `ClaudeAccountAdapter`, `CodexTokenProvider` |
| Which state a tool is in | `StateEngine` |
| Which notification fires | `NotificationEngine`; wording in `App/UserNotificationPresenter.swift` |
| On-screen copy | `DisplayFormatter` and the explanation registry (`KvotarUI/Model`) for the menu bar and popover, `HistoryDisplay` for History; menu labels in `App/MenuBarController.swift`; a few fixed labels in views |
| What is redacted from captured responses | `DiagnosticsPayloadSanitizer` |
| What a diagnostics bundle contains | `DiagnosticsBundle` |
| Prices for the estimated token value | `Resources/pricing.json`, read by `EstimatedValueEngine` |
| Logging | `Logger` (Core); the privacy boundary is kept at each call site |

## Logging

`Logger` writes to the unified log (subsystem `com.vladimirmarkovic.kvotar`) and to
`~/Library/Logs/Kvotar/kvotar.log`, rotated by size (5 MB per file). Callers never pass prompt or
response content, and write the account email as `<redacted>`; that is a convention each call site
keeps, not a filter inside `Logger`. Tests write their logs to a temporary folder, never to the real one.

## The CLI

`kvotar` is a Swift package executable, built separately from the app. It opens the app's database
read-only for `status` and `doctor`; `logs` reads the log files. It opens the database read-write
only for two switches: `debug`, and `capture --disable` (which also deletes the captured replies).
It cannot turn capture on: consent needs an expiring confirmation, so it comes only from the app's
dialog, and `capture --enable` refuses with directions to it. It never reads a credential
and never calls a provider. `import` loads diagnostics
bundles into a separate analysis database.

## The old name

The app was called AgentPilot before. `LegacyDataMigrator` copies an old AgentPilot database into the
Kvotar location once, read-only on the source, and a launch guard stops an old AgentPilot copy and
Kvotar from polling at the same time. Both stay because some people still have the old app installed.

## Updates

`App/UpdaterService.swift` wraps Sparkle. The feed URL and public signing key are in `App/Info.plist`;
it checks once a day and never installs without a click.
