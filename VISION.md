# VISION.md

Kvotar helps people who use Claude Code and Codex get the most from the plans they pay for. It shows
how much is left and whether it will last, and it turns your own usage into insight: where the work
went, what it would cost at published API prices, and when to push or pace yourself. All of it runs
on your Mac, with the credentials your tools already have, and without asking you to trust a server.

## In scope

- Claude Code and Codex, for the limits each provider reports, where available.
- macOS 14 and newer.
- Quota, pace and reset; local attribution by project and model; notifications; History.
- Honest display: say what is known, say when something is unknown, never guess a number.

## Out of scope

- Windows and Linux.
- Other tools (Cursor, Copilot and similar).
- Cloud sync, accounts or a Kvotar server, for now.
- Anything that needs a credential the user's tools do not already have on the Mac.

## No approval needed first

These can go straight to a pull request. They are still reviewed before they merge.

- Fixes with a clear cause, shown by a test or a synthetic reproduction.
- Tests.
- Documentation.
- Small UI fixes that follow the existing copy rules (the registry and copy tests in
  `Packages/KvotarUI/Tests` say what those are).
- Performance improvements that change no behavior.

## Needs approval first

Open an issue and get the maintainer's agreement **before** writing code that touches any of these.
Use [docs/decisions/TEMPLATE.md](docs/decisions/TEMPLATE.md) for the proposal.

- **Credentials**: how any token is found, read or handled.
- **Network**: a new endpoint or host, request headers, or the polling cadence and its 429 handling.
- **Storage and migrations**: the database schema, retention, file locations.
- **Diagnostics and privacy**: what is logged, captured, exported or redacted.
- **Notifications**: what fires, when, and how often.
- **User-facing copy rules**: the copy rule in [AGENTS.md](AGENTS.md) and its banned-word list.
- **Forecast logic**: how pace, runway and verdicts are computed.
- **New dependencies.**
- **New tools or platforms.**

Why the list exists: a mistake in these areas can log a user out of Claude Code, spend their quota,
or leak how they work. The decision records in [docs/decisions/](docs/decisions/) explain the rules
that already hold.

Checked against the code at 8aebac0.
