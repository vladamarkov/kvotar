# AGENTS.md

Instructions for every coding agent (and every human) changing Kvotar.

## What to read, and when

- **Always:** this file.
- **Once, when new to the code:** [ARCHITECTURE.md](ARCHITECTURE.md).
- **Per feature:** its spec page, found through the [spec index](docs/spec/INDEX.md). A spec page wins over a code comment that disagrees with it. A
  topic with no page yet is described by its code, its tests and the
  [decision records](docs/decisions/).
- **Per kind of code:** the matching section of [PATTERNS.md](PATTERNS.md).
- **Before proposing anything new:** [VISION.md](VISION.md).

Don't add a CLAUDE.md; if one is ever needed, it must contain @AGENTS.md.

## Commands

```sh
make build   # xcodegen + unsigned Release build; prints the .app path
make test    # every package's tests + the app tests, with live variables unset
make check   # static rule checks and the doc-path check
```

`make test` fails on any skipped test that is not on the expected-skips list. Do not add to that list
to make a run pass.

## The four safety rules

These are copied word for word from the maintainer's own instructions. Private cross-references were
replaced by links. Each rule has a decision record explaining why, and tests that enforce it, listed
in [docs/safety-checks.md](docs/safety-checks.md).

1. **Never store** prompts, code, transcripts, tool outputs, or refresh tokens.
   Why: [credentials and privacy](docs/credentials-and-privacy.md),
   [diagnostics record](docs/decisions/0004-diagnostics-consent-and-redaction.md).
2. **Never write** credential files (`~/.claude/`, `~/.codex/auth.json`, Keychain).
   Why: [read the Claude credential through `security`](docs/decisions/0002-read-claude-credential-through-security.md).
3. **Never refresh** OAuth or Codex tokens — read current token only, fail gracefully if expired.
   **No exceptions.** Never re-add a refresh trigger of any shape.
   Why: [never refresh a token](docs/decisions/0001-never-refresh-a-token.md).
4. **Read-only credential posture** — read the Claude token silently by delegating to
   `/usr/bin/security` (the trusted app on the `Claude Code-credentials` ACL, so no dialog appears);
   passive read of `~/.codex/auth.json`. Never present an auth dialog.
   Why: [read the Claude credential through `security`](docs/decisions/0002-read-claude-credential-through-security.md).
A change that touches any of these needs the maintainer's agreement before you write it
(see [VISION.md](VISION.md)).

## The copy rule

Also word for word. It is a rule about the product's voice, not a safety rule:

- **Never expose polling internals** to the user (no "throttled", "backing off", "rate limited" in UI
  copy).
  Why: [polling and rate limits](docs/decisions/0003-polling-and-rate-limits.md).

The banned words are one list, `UserCopyRules.pollingWords` in `Packages/KvotarCore`, checked by the
explanation-registry and notification tests. Changing the rule or the list needs the maintainer's
agreement.

## Agent notes

- **Fixtures only.** Never run live provider probes, and never set `KVOTAR_LIVE` or run live tests,
  unless the person you work for asks. A probe spends the user's real quota allowance, which Claude
  Code shares.
- Never read, print or copy a real credential, a real `~/.claude` or `~/.codex` file, or a real
  Kvotar database into a test, a log or a pull request. Use the synthetic fixtures under
  `Packages/*/Tests`.
- User-facing strings are built in `DisplayFormatter` and the explanation registry (menu bar and
  popover), `HistoryDisplay` (History) and `UserNotificationPresenter` (notifications). Menu labels
  live in `App/MenuBarController.swift`, and a few fixed labels still live in views; do not add new
  copy to views.
- Code comments cite IDs like `STEP_165`, `REV-96` or `D-58`, and Baseline or UI Spec sections. They
  point to private records; [docs/REFERENCES.md](docs/REFERENCES.md) explains them. Do not invent new
  IDs; explain the reason in the comment instead.
- Keep changes small and in the style of the surrounding code.
- Before handing off, run `make test` and `make check`, and say what passed, failed or was skipped.

## How a change lands

A change that makes Kvotar do what the docs already say, or that no user or spec page would notice,
goes straight to a pull request. A new feature, a change to what Kvotar is meant to do, or a change
to how an area on the approval list in [VISION.md](VISION.md) works, in a way no spec page already
describes, needs an agreed contract first. See [CONTRIBUTING.md](CONTRIBUTING.md).
