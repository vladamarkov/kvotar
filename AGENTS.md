# AGENTS.md

Instructions for every coding agent (and every human) changing Kvotar. Read this first, then
[ARCHITECTURE.md](ARCHITECTURE.md) and [PATTERNS.md](PATTERNS.md) (how code is written here). Read
[VISION.md](VISION.md) before proposing anything new.

The current requirements for a topic live in `docs/spec/`. Start at the
[spec index](docs/spec/INDEX.md): it maps features and code areas to pages and lists the topics with
no page yet. A spec page wins over a code comment that disagrees with it. A topic with no page yet is
described by its code, its tests and the [decision records](docs/decisions/).

Don't add a CLAUDE.md; if one is ever needed, it must contain @AGENTS.md.

## Layout

| Path | What it is |
|---|---|
| `App/` | The macOS app target: composition root (`AppDelegate`), poll scheduling (`PollCoordinator`), menu bar, windows, notifications, updates (Sparkle). |
| `Packages/KvotarCore` | Models, engines (state, forecast, notifications, attribution), polling policies, SQLite storage (GRDB), logging, diagnostics. Depends on nothing else in the repo. |
| `Packages/ClaudeAdapter` | Reads the Claude credential and quota, and Claude Code's local session logs. |
| `Packages/CodexAdapter` | Talks to the local `codex app-server` (with a web fallback), reads `~/.codex/auth.json` and Codex's local session logs. |
| `Packages/KvotarUI` | `DisplayFormatter` (every user-facing string), view models, SwiftUI views. |
| `Packages/KvotarCLI` | The `kvotar` command-line tool. A separate binary, not inside the app bundle. Reads the app's database (and can flip the debug-logging setting and turn capture off, never on); never calls a provider. |
| `AppTests/` | App-level tests (the `KvotarTests` scheme). |
| `Resources/` | Bundled pricing table, third-party notices, brand assets. |
| `project.yml` | XcodeGen spec. The `.xcodeproj` is generated, never committed. |

## Commands

```sh
make build   # xcodegen + unsigned Release build; prints the .app path
make test    # every package's tests + the app tests, with live variables unset
make check   # static rule checks and the doc-path check
```

The same three run on GitHub for every pull request (`.github/workflows/checks.yml`).

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

## Working on a task

Approved work is written down as numbered build steps before anyone codes it.

1. **Find the open step** in [TASKS.md](TASKS.md): the row marked `[~]`, or else the first `[ ]`.
2. **Read its contract** in `TASKS/` (linked from the row): goal, contract, proof, what it
   deliberately leaves alone, and when it is done.
3. **Read the docs on its `refs:` line.** They are all in this repository. If a step needs
   something that is not here, stop and say so; do not guess.
4. **State a plan and wait for approval** before writing code: what changes, which files, how you
   will prove it. **Approval of a step includes its stated live checks**, unless the maintainer
   reserves them for themselves: build and launch the app for them and hand over only the clicks. A
   maintainer's "I'll do the live check" wins.
5. **One step per session.** Finish it, commit it, stop. Do not start the next one.
6. **Update the spec page in the same commit as the code.** If a step changes behavior or copy that
   a page in `docs/spec/` describes, the page changes in that commit, and its `Checked against`
   line reads `Checked against the code at <parent commit> + STEP_nnn` (a file cannot name its
   own commit's hash). A step never leaves a page describing the old behavior. **A mismatch you
   find between a spec page and the code goes into that page's *Known gaps* table in the same
   commit**, with a proposed fix. Not only in chat.
7. **Commit message:** `STEP_nnn: <what is now true, in plain words>`, for example
   `STEP_238: on a weekly-only account the notice arrives with the red state`.

**What needs the maintainer's approval:** a new step, a change to a step's contract, and any change
in an area on the approval list in [VISION.md](VISION.md) (credentials, network, storage and
migrations, diagnostics and privacy, notifications, the copy rules, forecast logic, new dependencies,
new tools or platforms). A step that is already approved has that approval for exactly what its
contract says, and nothing more. If the code and a spec page disagree in a way the step does not
cover, record it and ask; do not fix it on the side.

New contracts use [TASKS/TEMPLATE.md](TASKS/TEMPLATE.md).

## What a pull request must contain

- A short summary: what changes and why.
- The commands you ran and their result (`make test`, `make check`).
- Proof that uses synthetic data only. See [.github/pr-proof/README.md](.github/pr-proof/README.md).
- One line for [CHANGELOG.md](CHANGELOG.md).
- Whether it touches the approval list in [VISION.md](VISION.md). If it does, link the issue where
  that was agreed.

Checked against the code at e9d2933 + STEP_276.
