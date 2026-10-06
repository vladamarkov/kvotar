---
summary: Diagnostics are exported only by the user, extended capture needs explicit consent that expires within 24 hours, and captured replies are redacted before storage.
read_when: Changing DiagnosticsBundle, DiagnosticsCapture, DiagnosticsPayloadSanitizer, logging content, or anything that adds a file to a bundle.
---

# 0004 — Diagnostics consent and redaction

## Decision

1. The app never transmits diagnostics. **Save Diagnostics…** writes a zip to the Desktop; sharing it
   is the user's act.
2. An **ordinary bundle** carries aggregates, two record lists, logs and environment facts,
   never the database.
3. **Extended capture** (keeping the providers' quota replies, and adding the database to a bundle)
   happens only after the user confirms a dialog, and only until an expiry at most 24 hours away. It
   is off by default in every build.
4. Captured replies are **redacted before they are stored**. Unknown endpoints and non-JSON replies
   are rejected outright.

## Why

When a number looks wrong, the provider's actual reply and the app's own history are what explain
it. They also describe how a person works: account email, organisation, projects, months of usage.
So the useful-but-revealing part sits behind a consent the user gives knowingly, that ends by itself,
and that a stranger installing the app has never given.

Two real leaks shaped the details. One user's shell printed an API key at startup and it landed in a
bundle through a tool-version probe; now only a line that looks like a version is kept. Captured
replies once kept email addresses and organisation ids; identity fields are now redacted too.

## Accepted behavior

- Ordinary bundle: `diagnostics-summary.json` (counts, plus the capture on/off history and the model
  names the price table did not know), `environment.txt`, `manifest.json`,
  `WHAT_LOOKED_WRONG.txt`, the log files, and a snapshot of what the popover showed. No database,
  no session files, no response bodies.
- Extended bundle, only while capture is authorized: adds `extended-payloads.json` (redacted replies)
  and a consistent, unredacted copy of the database. The manifest states whether capture was on.
- Capture is authorized only when the setting is on **and** its expiry is in the future. A setting
  without an expiry is treated as off.
- Turning capture off, or its expiry passing, deletes the captured replies while the app runs; an
  expiry that passed while the app was closed is cleaned up at the next launch. A retention job also
  deletes any older than 24 hours. A zip already saved is the user's and is never touched.
- Redaction (`DiagnosticsPayloadSanitizer`) accepts only the known quota, profile and credits
  endpoints and replaces any field whose name contains a token-, content- or identity-shaped
  fragment (`access_token`, `refresh_token`, `authorization`, `secret`, `prompt`, `transcript`,
  `content`, `code`, `email`, `full_name`, `display_name`, `uuid`, …) with `<redacted>`. Field names
  survive, so the reply's shape can still be compared. This is not anonymization: bare `name`
  (model and plan names) and Codex's `user_id` and `account_id` are kept on purpose.
- Session files are never put in a bundle. Lines the parsers could not read are recorded by field
  name only, never by value.

## Non-goals

- Uploading a bundle, crash reports or telemetry.
- Capture that turns itself on, or that lasts longer than 24 hours.

## Required tests

- `DiagnosticsBundleTests` — notably `testOrdinaryArchiveCarriesLogsButNoDatabaseAndNoSessionFile`,
  `testOrdinaryArchiveStillCarriesNoDatabase`, `testAuthorizedArchiveCarriesTheDatabaseAndDeclaresIt`,
  `testOutputWithNoVersionShapeIsDropped`.
- `DiagnosticsPayloadSanitizerTests` — all four.
- `DiagnosticsCaptureFlagTests.testAuthorizationRequiresFutureExpiryAndClampsToTwentyFourHours`.
- The no-content-stored check in [safety-checks.md](../safety-checks.md).

## Tradeoffs

- Logs ride in every bundle. They hold the sequence of what the app did, which nothing else
  records, and they include the user's home folder path. That is why every bundle is treated as
  private and goes to `hello@kvotar.com`, never to a public issue.
- Redaction by field-name fragment can over-redact (a field named `code` loses its value). That is
  the safe direction.

## Status

Accepted.
