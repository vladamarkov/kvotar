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

## Straight to a pull request

A change goes straight to a pull request when it makes Kvotar do what the docs already say it
should, or changes nothing a user or a spec page would notice. It is still reviewed before it
merges. For example:

- Fixes with a clear cause, shown by a test or a synthetic reproduction. A fix that restores
  documented behavior takes this path even in an area on the approval list below.
- Tests.
- Documentation.
- Small UI fixes that follow the existing copy rules (the registry and copy tests in
  `Packages/KvotarUI/Tests` say what those are).
- Performance improvements that change no behavior.

## An agreed contract first

Open a contract issue and get the maintainer's agreement **before** writing code for any of these:

- A new feature.
- A change to what Kvotar is meant to do, so that a spec page would have to say something different.
- A change to how an area on the approval list works, in a way no spec page already describes.

A contract is a GitHub issue that the maintainer approves with the `agreed` label;
[CONTRIBUTING.md](CONTRIBUTING.md) describes it and the rest of the process.

### The approval list

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
