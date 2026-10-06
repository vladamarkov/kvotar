---
summary: The current rules for debug logging, extended diagnostics capture and its consent, what is stored and for how long, the Save Diagnostics bundle, and the CLI commands that touch them.
read_when: Changing Logger's debug mode, DiagnosticsCapture, DiagnosticsPayloadSanitizer, the capture decorators, raw_payloads / payload_shapes / parse_anomalies / app_lifecycle_events, DiagnosticsBundle, the kvotar debug / capture commands, or the build channel.
---

# Diagnostics

This page is the specification for diagnostics. It replaces the private Baseline §10.7, §10.7a,
§10.7b and the diagnostics parts of §17, §17.1 and §17.2. Change this page in the same commit as
the code it describes.

Why consent and redaction exist at all is recorded in
[decision 0004](../decisions/0004-diagnostics-consent-and-redaction.md). What the app reads and
sends in general is in [credentials and privacy](../credentials-and-privacy.md).

Three separate things live here. Keep them apart:

| Thing | What it is | Default |
|---|---|---|
| Debug logging | More detail in the app's own log file | Off in release builds, on in internal beta builds |
| Extended diagnostics (capture) | Keeping the providers' quota replies, redacted, for at most 24 hours | Off in every build; on only after the user confirms a dialog |
| Save Diagnostics… | A zip the user writes to their Desktop | Only when the user clicks it |

## Debug logging

A runtime setting, stored in the `settings` table as `debug_mode_enabled` (`"1"` on, anything else
off). (`Packages/KvotarCore/Sources/KvotarCore/DebugMode.swift`: `DebugMode`)

- **Default.** The first launch seeds the row from the build channel: off in `release`, on in
  `beta`. A row that exists is never overwritten, so the user's choice survives every later launch.
  (`DiagnosticsCapture.swift`: `BuildChannel.seedsDebugOn`; `App/AppDelegate.swift`, the launch
  settings task)
- **What it changes.** DEBUG-level lines are written (`Logger.log` drops them when it is off), and
  the log file gets a `[DEBUG MODE]` line when it is switched on.
  (`Packages/KvotarCore/Sources/KvotarCore/Logging/Logger.swift`: `setDebugModeEnabled`)
- **What it does not change.** Nothing else: no polling, no thresholds, no display, no capture.
- **Live switch.** `kvotar debug --enable` / `--disable` writes the row and posts a Darwin
  notification; the running app re-reads the row and applies it without a relaunch. The database is
  the source of truth, so a lost notification only delays the change to the next launch.
  (`Packages/KvotarCLI/Sources/KvotarCLI/Debug.swift`; `AppDelegate.reloadDebugMode`)
- **Every launch** writes one `Kvotar started` line carrying version, channel, PID, macOS,
  architecture, time zone, database path, schema and `debug=` / `capture=` on or off, so the state
  is never hidden. (`Logger.launchBanner`)

Debug logging needs no consent: the log file follows the never-log rules below whether it is on or
off.

### What the log never contains

Prompt, code, transcript or tool-output text; response bodies; JSONL line contents beyond metadata;
an email address in plain text (it is written as `email=<redacted>`). The log does contain the
user's home folder path. In builds compiled without `DEBUG` (the Release configuration, whatever the
channel) the metadata half of each unified-log (`os_log`) line is marked private. (`Logger.emitOSLog`)

## Extended diagnostics (capture)

When a number looks wrong, the provider's actual reply is the evidence that explains it. Capture
keeps those replies for a short, consented window.

### Turning it on and off

- **On, only through the app's dialog.** The status item's right-click menu shows **Enable Extended
  Diagnostics for 24 Hours…**. It opens a confirmation alert, *Enable Extended Diagnostics for 24
  Hours?*, with the buttons **Enable for 24 Hours** and **Cancel**. Confirming writes
  `diagnostics_capture_enabled = "1"` **and** `diagnostics_capture_expires_at` (now + 24 hours, unix
  seconds). (`App/MenuBarController.swift`, the menu; `AppDelegate.configureExtendedDiagnostics`)
- **The alert text says:** *Kvotar will temporarily retain safety-filtered quota and account response
  details. A diagnostics bundle saved while it is on also includes an unredacted copy of Kvotar's
  database, with your account email and project folder names. It never retains prompts, code,
  transcripts, tool output, credentials, or local session files. The data is deleted automatically
  when the window expires, or immediately if you turn it off.*
- **Off.** While capture is on, the same menu item reads **Turn Off Extended Diagnostics…** and
  switches it off at once (no second dialog). `kvotar capture --disable` does the same from the
  terminal. Off writes `"0"`, clears the expiry and **deletes every captured reply**: off means gone,
  not "stop adding". (`AppDelegate.disableExtendedDiagnostics`; `Capture.swift`)
- **No way on from the terminal.** Capture opens only from the app's dialog, because consent needs
  an expiry and the CLI does not ask for one. `kvotar capture --enable` refuses, names the menu
  item, and exits non-zero.
- **Expiry.** A timer switches capture off at the stored instant, with the same deletion. If the
  expiry passed while the app was closed, the next launch finds it lapsed, writes it off and deletes
  the replies. (`AppDelegate.scheduleDiagnosticsExpiry`, the launch settings task)
- **Authorized means flag and future expiry together.** A `"1"` with no expiry, or an expiry in the
  past, is off. A requested expiry is clamped to 24 hours from now. (`DiagnosticsCapture.isAuthorized`,
  `DiagnosticsCapture.setEnabled`, `maximumDuration`)
- **Default: off, in every build.** The first launch seeds `"0"`. Capture never turns itself on and
  never re-arms. (`BuildChannel.seedsDiagnosticsOn` returns `false`; the launch settings task)
- **The build channel decides the debug-logging default and nothing else.** No cadence, threshold,
  engine or display difference may depend on it; otherwise the beta stops testing the app that
  ships. The channel also appears in labels (the version string, the bundle name), which is not
  behavior.

**Rejected, don't re-propose:** capture on by default for a tester group, re-arming itself every
launch. It was tried before the first public build and reverted: a stranger who installs the app
from a website has not consented, and a window that silently re-arms is the same as always-on.

**Rejected, don't re-propose:** a CLI path to turn capture on. Consent needs a visible, expiring
confirmation, and a second door is a second thing to trust and explain.

### What is captured

Provider replies at three points, by wrappers added only at the composition root, so no adapter
changes and no request or reply is altered (`AppDelegate`, where `LiveDiagnosticsSink` is wired;
`Packages/KvotarCore/Sources/KvotarCore/Diagnostics/LiveDiagnosticsSink.swift`):

- Claude `/api/oauth/usage`, `/api/oauth/profile` and the prepaid-credits call (one wrapper on the
  HTTP fetcher);
- Codex `wham/usage` (the Codex HTTP fetcher);
- Codex app-server replies to `account/read` and `account/rateLimits/read` (an `onResponse` hook on
  `CodexRPCClient`).

**Never captured:** bearer tokens in either direction (the token is a request header, and requests
are not captured), and local JSONL session files.

### Redaction before storage

Every reply passes `DiagnosticsPayloadSanitizer` on its way to the database
(`Packages/KvotarCore/Sources/KvotarCore/Diagnostics/DiagnosticsPayloadSanitizer.swift`):

- **Rejected outright:** any endpoint outside the allowlist (`claude_usage`, `claude_profile`,
  `claude_prepaid`, `codex_wham_usage`, `account/read`, `account/rateLimits/read`) and any body that
  is not JSON. A rejection logs one warning and stores nothing.
- **Redacted:** the value of any key whose lower-cased name (dashes read as underscores) contains
  one of `forbiddenKeyFragments` — `access_token`, `accesstoken`, `refresh_token`, `refreshtoken`,
  `authorization`, `bearer`, `secret`, `prompt`, `transcript`, `tool_output`, `tooloutput`, `code`,
  `message_content`, `content`, `email`, `full_name`, `display_name`, `uuid` — becomes
  `"<redacted>"`. So does any string value that starts with `bearer `.
- **Kept on purpose:** field names (so the reply's shape stays comparable), bare `name` (model and
  plan names), and Codex's `user_id` and `account_id`. This is redaction, not anonymization.
- **Why `uuid` and not `organization`:** the profile's `account.uuid`, `organization.uuid` and
  `application.uuid` are identifiers. `organization` names an object; redacting it would collapse
  the whole object, change the shape and destroy the plan fields the adapter reads.

### Where it is stored, and for how long

| Table | What | Written | Kept |
|---|---|---|---|
| `raw_payloads` | One redacted reply: tool, endpoint id, time, HTTP status (null on RPC), body, shape hash. `keep_reason` is always `window` and means nothing | Only while capture is authorized | **24 hours at most**, every row, no exception. Deleted at once when capture goes off |
| `payload_shapes` | One row per distinct `(tool, endpoint, shape_hash)`: sorted field paths, first and last seen. Names only, never values | Beside each `raw_payloads` write, so only while capture is authorized | Permanent; turning capture off keeps it |
| `parse_anomalies` | A local JSONL line a parser could not use: file path, line number, time, error, top-level field names. Never values | Only while capture is authorized; at most 20 per file per process | Permanent |
| `app_lifecycle_events` | `launch`, `quit`, `sleep`, `wake`, with the app version | Always, whatever the capture setting | Permanent |

Code: `Packages/KvotarCore/Sources/KvotarCore/Storage/SQLiteStore+DiagnosticsCapture.swift`
(`writeRawPayload`, `writeParseAnomaly`, `writeLifecycleEvent`, `deleteCapturedPayloads`);
`SQLiteStore+Retention.swift` (`runRetentionCleanup`, step 5, the 24-hour delete); migration
`v20_time_limited_diagnostics` in `SQLiteStore+Migrations.swift`.

- **The gate is checked twice.** `LiveDiagnosticsSink` checks the live flag before it hands a write
  off, and `writeRawPayload` checks it again inside the store, because a write queued just before
  the expiry could otherwise land after the cleanup.
- **Writes never slow a poll.** The sink writes on a detached background task; a failed write logs
  a warning and is dropped.
- **Why the shape is kept and the body is not.** The shape is what shows that a provider changed a
  reply (a new field, a missing object), and it carries no identity. A body carries account details
  and nothing justifies keeping one.
- **The shape hash keys on structure only.** Field paths, sorted; array elements under a `[]`
  marker, so a longer list is the same shape; leaf types ignored, because providers switch a field
  between `null` and a number routinely. `PayloadShape.of` would give a non-JSON body the shape
  `<unparseable>`, but the storage path never gets that far: the sanitizer rejects non-JSON first,
  so such a reply leaves no `raw_payloads` row and no `payload_shapes` row.
  "New" means never seen for that endpoint, not "different from the last reply".
  (`Packages/KvotarCore/Sources/KvotarCore/Diagnostics/PayloadShape.swift`)
- **Why `parse_anomalies` exists.** It is the reason no bundle ever needs a session file: it records
  what failed by field name, and session files carry other people's transcripts and code.

**Rejected, don't re-propose:** storing reply bodies unredacted, or keeping some bodies permanently
when their shape is new. Both shipped once and were withdrawn; the shape alone serves the drift check.
Also rejected: putting raw replies in a `poll_snapshots` column. That table is purged after two
hours and has one row per poll, so it cannot hold the profile, credits or RPC replies.

### Standing endpoint rejection (always on)

Separate from capture: the sink also watches every reply's status. Three identical non-2xx replies
in a row from one endpoint log a warning and write one `poll_health_events` row; the next 2xx
writes one "cleared" row. A 429 anywhere, and a 401 or 403 on a quota endpoint, are left to the
mechanisms that already handle them. This runs whatever the capture setting, because the user who
needs it is the one with capture off. Nothing of it reaches the UI.
(`LiveDiagnosticsSink.detectStandingRejection`, `EndpointRejectionTracker`)

## Save Diagnostics…

The right-click item **Save Diagnostics…** builds a zip named
`Kvotar-diagnostics-<yyyyMMdd-HHmm>-<version>-<channel>.zip` on the Desktop and reveals it in
Finder. The app never sends it anywhere; a failure shows an alert naming what went wrong.
(`Packages/KvotarCore/Sources/KvotarCore/Diagnostics/DiagnosticsBundle.swift`: `build`;
`AppDelegate.saveDiagnosticsBundle`)

| File | Ordinary bundle | Inside an authorized capture window |
|---|---|---|
| `WHAT_LOOKED_WRONG.txt` | Yes (a template for the user's note) | Yes |
| `environment.txt` | Yes | Yes |
| `manifest.json` | Yes | Yes |
| `diagnostics-summary.json` | Yes | Yes |
| `logs/kvotar*.log`, `logs/kvotar-cli.log` | Yes | Yes |
| `explanation-snapshot.json` | Yes, when a popover tab has rendered | Yes |
| `extended-payloads.json` | No | Yes |
| `kvotar.db` | No | Yes |

- `environment.txt`: app version, channel, capture and debug on or off, macOS, architecture, the
  price table's version, local and UTC time, time zone, UTC offset and DST, uptime, notification
  permission and style, Open at Login, whether (never what) `~/.codex/auth.json`, `~/.claude.json`
  and `~/.claude/projects` exist, the logs collected, and the `claude` and `codex` version lines.
  Only an output line that looks like a version is kept. (`environmentReport`, `versionLine`)
- `manifest.json`: contents, channel, whether capture was on, time zone, the database summary, and
  notes naming every absence, so an empty bundle never reads as "nothing happened". (`notes`)
- `diagnostics-summary.json`: row counts per table, the capture on/off history, and the model names
  the price table did not know. (`SQLiteStore.diagnosticsSummary`)
- The logs ride in every bundle. They are the only record of the order in which things happened.
  They contain the home folder path and no prompts, code, transcripts, bodies or emails.
- `explanation-snapshot.json`: what the popover was showing, element by element, for **tagged**
  elements only, except E-06, the local-app rows (an [explanations](explanations.md#known-gaps)
  Known gap). Untagged rows (project names, model rows, email, plan badge) are not in it. Its key
  names avoid the sanitizer's fragments, and a test checks that against the sanitizer's own list.
  (`Packages/KvotarCore/Sources/KvotarCore/Diagnostics/ExplanationSnapshot.swift`)
- `extended-payloads.json`: the redacted replies, the shapes, and the parse anomalies (file name only,
  not the full path). (`SQLiteStore.extendedDiagnosticsJSON`)
- `kvotar.db`: a consistent `VACUUM INTO` copy, **not redacted**: account emails, project folders,
  months of usage. That is why it is behind the consent window. If the copy fails, the manifest
  says so. (`SQLiteStore.backup`)
- **Never in a bundle:** session files, bearer material.

Every bundle describes how a person works. Bundles go to `hello@kvotar.com`, never to a public
issue.

**Rejected, don't re-propose:** the database in every bundle. It shipped for the tester group and was
put back behind consent for the first public build.

## CLI commands today

The `kvotar` CLI reads the app's database and never calls a provider. These commands touch this
topic:

```bash
kvotar debug --enable | --disable | --status     # debug logging
kvotar capture --disable | --status              # extended capture (off or state only)
kvotar logs [--follow] [--level L] [--component C] [--tool claude|codex] [--since 30m]
kvotar import <bundle>...                          # read bundles into a separate analysis database
```

`capture --disable` also deletes the captured replies, even when the app is not running.
(`Packages/KvotarCLI/Sources/KvotarCLI/`: `Debug.swift`, `Capture.swift`, `Logs.swift`,
`Import.swift`)

## Known gaps

| Gap | Today | Proposed |
|---|---|---|
| `kvotar capture --disable` leaves the expiry | It writes `"0"` and deletes the replies but keeps `diagnostics_capture_expires_at`; the app's off switch clears it. Harmless: `"0"` is off whatever the expiry says | Clear the expiry in `Capture.swift` with the next change to it |
| Stale code comments | `DiagnosticsBundle.build`'s doc comment says the ordinary bundle has no logs; `LiveDiagnosticsSink.capture` says capture is "beta-gated" | Fix with the next change to either file |
