---
summary: What Kvotar reads, keeps and sends, how it reads each credential, and why it never refreshes one.
read_when: Changing anything that reads a credential, calls the network, writes to disk, logs, or builds a diagnostics bundle.
---

# Credentials and privacy

## In one paragraph

Kvotar runs on your Mac. There is no Kvotar account, and your usage and session data are never
uploaded: the only requests that reach a Kvotar-run server are update checks (daily, or when you ask), described below. To show your quota it asks your providers, with the sign-in Claude
Code and Codex already keep on your Mac, and it reads the session logs those tools already write. It
reads both credentials and never changes them.

## Credentials

### Claude

- **Where:** the Keychain item `Claude Code-credentials`, written by Claude Code.
- **How:** Kvotar runs `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w` and
  decodes `claudeAiOauth.accessToken`, the subscription type and the expiry. The refresh token in
  the same item is never decoded or kept. (`ClaudeAdapter/KeychainTokenProvider.swift`)
- **Why through `security`:** the item allows one trusted app, `/usr/bin/security`, because Claude Code
  created it with that tool. If Kvotar read the item itself, macOS would show a password dialog. Going
  through the trusted tool reads it silently. See
  [decision 0002](decisions/0002-read-claude-credential-through-security.md).
- **When:** fresh on every poll. The token is not cached, so when Claude Code refreshes its own
  sign-in, Kvotar picks the new token up on the next poll.

### Codex

- **Where:** `~/.codex/auth.json`, written by Codex.
- **How:** a plain file read of the access token and account id. Never written.
  (`CodexAdapter/CodexTokenProvider.swift`)

### Never a refresh

Kvotar never refreshes a token and never asks another program to. If the Claude token it reads has
expired, it sends **no request** and shows that the sign-in expired; opening Claude Code refreshes it,
and Kvotar recovers on its next poll. (One narrow case is not gated yet: after a 401 or 403, a token
that another program rotated in the meantime is retried once without checking its expiry. That sends
a request; it never refreshes anything.)

Why: a refresh token can be used once. When two programs share one, a refresh by one can make the
other replay a token that is already used. The provider rejects it, and Claude Code then clears its
own Keychain item, which forces you to sign in again. An earlier Kvotar version triggered exactly
that. See [decision 0001](decisions/0001-never-refresh-a-token.md).

## What it reads on your Mac

| Source | What is taken from it |
|---|---|
| `~/.claude/projects/` (Claude Code session logs) | Token counts, model, timestamps, session id, the project folder |
| `~/.codex/sessions/` and `~/.codex/archived_sessions/` (Codex session logs) | The same |
| `~/.codex/state_5.sqlite`, `~/.codex/goals_1.sqlite` | Thread metadata (model, file location) and an over-quota flag; opened read-only |
| `~/.claude.json` | The account email, only if the provider's profile call fails or returns no email |

The text of your prompts, Claude's replies and tool output is never stored. The session files
themselves are never copied.

## The network

Processing is local. Network use is listed here in full.

1. **Your providers, with your own credentials:**
   - Claude: `api.anthropic.com` — `/api/oauth/usage` (quota) on each poll, `/api/oauth/profile`
     (email and plan) once per token while the app runs, and the prepaid-credits balance only on Pro
     and Max accounts, at most every 15 minutes while the app runs (a relaunch or a new token starts
     both again).
   - Codex: the `codex app-server` process on your Mac, sent `initialize` when it starts and then only
     `account/read` and `account/rateLimits/read`. Kvotar calls `chatgpt.com/backend-api/wham/usage`
     when that fails, and also when an Enterprise or Business account's reply has no windows and no
     monthly limit, to fill in the monthly limit.
   - Direct requests to the providers identify themselves honestly with `User-Agent: Kvotar/<version>`. The
     `codex app-server` sees Kvotar's name in `initialize`.
   - How often: see [decision 0003](decisions/0003-polling-and-rate-limits.md).
2. **Updates:** Sparkle asks `updates.kvotar.com/appcast.xml` once a day, or when you choose
   **Check for Updates…**, whether there is a newer
   version. The request carries the app version; the server sees your IP address and the time. No
   system profile is sent. Nothing installs without your click.
3. **Links you click:** for example "Manage in Claude web" opens `claude.ai` in your browser. Kvotar
   does not fetch these pages itself.

There is no analytics, telemetry or crash reporting.

## Launching `codex`

To read Codex quota, Kvotar starts your installed `codex` program as
`codex -s read-only -a never app-server` and only sends it `initialize` and the two account questions
above. It finds
the program by its app bundle id, then a list of known install paths, then `which codex`.

What `codex` does when it starts (its own network calls, its own handling of its sign-in) is Codex's
behavior, not Kvotar's. Kvotar never asks it to run a command or touch a file.

## What Kvotar keeps

| Where | What |
|---|---|
| `~/Library/Application Support/Kvotar/kvotar.db` | Quota readings, local token counts per session, project folders, model names, account email and plan, state and notification history, settings |
| `~/Library/Logs/Kvotar/` | The app's own logs (and the CLI's, in a separate file): about 5 MB per file, the active file plus up to ten older ones each. They contain your home folder path; emails are written as `<redacted>` |
| `~/Library/Application Support/Kvotar/kvotar.pid` | A lock so only one copy polls at a time |

To remove Kvotar's data: quit Kvotar, delete the app, and delete those two folders. macOS and the
updater also keep caches under Kvotar's identifier: `~/Library/Caches/com.vladimirmarkovic.kvotar`,
`~/Library/HTTPStorages/com.vladimirmarkovic.kvotar` and `~/Library/WebKit/com.vladimirmarkovic.kvotar`;
delete them too. Diagnostics zips you saved stay on your Desktop until you delete them, and the
update settings live in Kvotar's preferences (`defaults delete com.vladimirmarkovic.kvotar`). If
you installed Kvotar with Homebrew, `brew uninstall --zap --cask kvotar` removes the app and all
of these except the zips.

## Diagnostics

**Save Diagnostics…** (right-click menu) writes a zip to your Desktop. It is never sent anywhere by the
app. You can open it before sharing it.

An ordinary bundle holds:

- aggregate counts from the database (no project names, no usage rows), plus two record lists: when extended diagnostics were switched on or off, and any model names the price table
  did not know, with when they were seen
- the app's log files
- a short environment description (app version, macOS, time zone, which tools are installed and
  their version lines)
- what the popover was showing (its own wording and your percentages)
- a `WHAT_LOOKED_WRONG.txt` for your note

**Extended diagnostics** are off unless you turn them on with **Enable Extended Diagnostics for 24
Hours…**, which asks for confirmation first. While on, the menu offers **Turn Off Extended
Diagnostics…**. During that window Kvotar keeps the providers' quota replies after redaction, and a
bundle saved in the window also carries a full copy of the database, which is not redacted.
Redaction replaces fields whose names look like a token, content or a personal identifier (tokens,
prompts, content, email, full and display names, UUIDs) with `<redacted>`, and rejects replies from
unknown endpoints. It is not anonymization: plain `name` fields and Codex's `user_id` and
`account_id` are kept. Capture ends when you turn it off or after 24 hours at most; the stored
replies are deleted then if Kvotar is running, or at its next launch if it is not. Zips you already
saved are yours and are not touched.

Even an ordinary bundle describes how you work. **Never attach one to a public issue**; send it to
`hello@kvotar.com`. See [decision 0004](decisions/0004-diagnostics-consent-and-redaction.md).
