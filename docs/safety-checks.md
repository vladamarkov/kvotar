---
summary: The four safety rules Kvotar never breaks, why each exists, and the tests and static checks that enforce them.
read_when: Changing credentials, network calls, storage, logging, diagnostics, or anything that launches a process.
---

# Safety checks

Kvotar reads other tools' credentials and session files. Four rules keep that safe. Each one is enforced by **behavior tests**, which are the real protection, and by **static checks** (`make check`), which catch drift early. A pull request that breaks either fails.

Run them with:

```sh
make check   # static checks, a few seconds
make test    # every test suite, with live access disabled
```

## The rules

### R1 — Never store prompts, code, transcripts, tool outputs or refresh tokens

**Why.** Session files hold everything a person typed and every file an agent read. Kvotar needs only token counts, models and timestamps. Anything more on disk, in a log or in a diagnostics bundle is a privacy leak that outlives the session.

| Suite | Test | What it proves |
|---|---|---|
| ClaudeAdapter | `NoContentStoredTests.testConversationContentReachesNoTableLogOrBundle` | A marker placed in a prompt, answer, tool call, tool output and an undecodable line, ingested by both the launch backfill and the live watcher with DEBUG logging and diagnostics capture on, reaches no cell of any table, the log, or an ordinary diagnostics bundle |
| CodexAdapter | `NoContentStoredTests.testConversationContentReachesNoTableLogOrBundle` | The same, for a Codex rollout (prompt, reasoning, tool call and output, answer) |
| KvotarCore | `DiagnosticsPayloadSanitizerTests.testForbiddenContentAndCredentialsNeverSurvive` | Captured provider payloads lose tokens, prompts and code before storage |
| KvotarCore | `DiagnosticsBundleTests.testOrdinaryArchiveCarriesLogsButNoDatabaseAndNoSessionFile` | An ordinary bundle never carries the database or a session file (an extended one, under consent, carries the database) |
| KvotarCore | `SQLiteStoreDiagnosticsCaptureTests.testParseAnomalyStoresNamesNotValues` | An undecodable line is recorded by field names, never values |
| ClaudeAdapter, CodexAdapter | `ClaudeParseAnomalyTests` / `CodexParseAnomalyTests.testAnomalyCarriesFieldNamesButNeverValues` | The parsers report names only |
| ClaudeAdapter | `ClaudeAccountAdapterTests.testRateLimited429BodyRedactsBearerToken` | A captured error body has the access token removed |
| KvotarCore | `LoggerTests.testRateLimitDetailsBodyNeverReachesTheDescription` | A response body never reaches a log line |
| KvotarCore | `SQLiteStorePollHealthTests.testWriteCredentialExpiredReclassifiedRowDropsResponseContent`, `EndpointRejectionSinkTests.testHealthRowNeverStoresBodyWhenExtendedCaptureIsOn` | Health records keep no response headers or bodies |

### R2 — Never write credential files (`~/.claude/`, `~/.codex/auth.json`, the Keychain)

**Why.** Those files belong to Claude Code and Codex. A stray write can corrupt a login or another tool's state, and the user would not know Kvotar did it.

| Suite | Test | What it proves |
|---|---|---|
| KvotarCore | `CredentialTreesUntouchedTests.testEveryWriterLeavesTheCredentialTreesAlone` | Every writer — the database and its migrations, the log writer, both PID locks, the legacy importer, the diagnostics bundle — runs against a fake home on the path it would use for real; afterwards `~/.claude/`, `~/.codex/` and `~/.claude.json` are byte-identical with nothing added |
| KvotarCLI | `CredentialTreesUntouchedTests.testImportingABundleLeavesTheCredentialTreesAlone` | The same for the CLI's bundle reader and import corpus |
| CodexAdapter | `NoRefreshNetworkSeamTests.testReadingAuthJSONLeavesItByteIdentical` | Reading `auth.json`, alone or through a poll, leaves its bytes and modification time unchanged |

### R3 — Never refresh an OAuth or Codex token, and never trigger a refresh

**Why.** Refresh tokens are single-use. If Kvotar refreshes — or makes another tool refresh — at the wrong moment, it can consume a token Claude Code still holds, and Claude Code then signs the user out. This happened once, through a delegated `claude doctor` call; that path is gone and no refresh path of any shape may come back. When a token expires, Kvotar says so and waits for the owning tool to renew it.

| Suite | Test | What it proves |
|---|---|---|
| ClaudeAdapter | `NoRefreshNetworkSeamTests.testAFullCycleReachesOnlyTheQuotaEndpointsAndNeverSendsARefreshToken` | Across a normal poll, an expired credential, a 401 with and without rotation, a 429 and a credential changed mid-run, every request goes to the usage, profile or prepaid endpoint on `api.anthropic.com`; none to a token endpoint; no header carries a refresh token or `grant_type` |
| CodexAdapter | `NoRefreshNetworkSeamTests.testAFullCycleSpeaksOnlyTheQuotaMethodsAndNeverSendsARefreshToken` | The app-server hears only `initialize`, `account/read` and `account/rateLimits/read`; HTTP goes only to `wham/usage`; nothing carries the refresh token |
| ClaudeAdapter | `ClaudeAccountAdapterTests.testExpiredCredentialGatesPollNoRequestSent`, `testExpiredCredentialGatesWithNoRefreshSeam` | An expired token sends no request at all |
| ClaudeAdapter | `ClaudeAccountAdapterTests.testZeroNetworkRecoveryPollsWhenExpiryFlipsFuture`, `testEpisodeEndsOnCredentialHealthNotOnAPoll` | Recovery happens only when the owning tool has renewed the token |

### R4 — Read credentials only the safe way, and never show a dialog

**Why.** The Claude token sits in a Keychain item that trusts only `/usr/bin/security`. Reading it through that tool is silent; reading it any other way raises a system dialog. `auth.json` is only ever read.

| Suite | Test | What it proves |
|---|---|---|
| ClaudeAdapter | `NoRefreshNetworkSeamTests.testAFullCycle…` (above) | Every Keychain access runs with exactly `find-generic-password -s "Claude Code-credentials" -w` |
| ClaudeAdapter | `NoRefreshNetworkSeamTests.testTheDefaultAccessorIsUsrBinSecurity` | The accessor is `/usr/bin/security` |
| ClaudeAdapter | `KeychainTokenProviderTests` (four tests) | Absent, denied and unlaunchable reads are told apart, never retried another way |
| ClaudeAdapter | `ClaudeAccountAdapterTests.testCredentialChangedIsFalseWhenTheReadFails` | A failed read probes nothing |
| CodexAdapter | `CodexBinaryDiscoveryTests.testLaunchArgumentsArePinned` | The Codex app-server is launched read-only (`-s read-only -a never`) |

## Static checks (`make check`)

`scripts/check_rules.sh` uses only Bash and the standard macOS command-line tools. Static checks catch drift; the behavior tests above are the protection. They are lexical and can be fooled — they exist to stop honest mistakes.

Over every file under `Packages/*/Sources` and `App`, the run fails on:

| Rule | Check |
|---|---|
| R2 | `SecItemAdd`, `SecItemUpdate`, `SecItemDelete` |
| R2/R4 | a `security` password or keychain subcommand (`*-generic-password`, `*-internet-password`, `*-keychain`) other than `find-generic-password`; `"/usr/bin/security"` outside `KeychainTokenProvider` |
| R3 | `refresh_token` / `refreshToken`, `grant_type`, `/oauth/token`, `auth.openai.com`, `console.anthropic.com` |
| R2 | a file write outside the approved writers: the database (`SQLiteStore*`), `LogFileWriter`, `PIDLock`, `LegacyDataMigrator`, `DiagnosticsBundle`, `ProductIdentity`, and the CLI's `BundleReader` and `AnalysisStore`. This catches a *new* writer; a wrong destination inside an approved one is the job of `CredentialTreesUntouchedTests` |
| R3 | a network host other than `api.anthropic.com` and `chatgpt.com` (quota traffic), `claude.ai` (links), `updates.kvotar.com` (the update feed, `Info.plist` only) |
| R2/R4 | a process launch outside the five known sites: `KeychainTokenProvider` (`/usr/bin/security`), `CodexProcessTransportLive` (`codex app-server`), `CodexRPCSeams` (`/usr/bin/env which codex`), `DiagnosticsBundle` (`ditto`, and `claude --version` / `codex --version` for the report), the CLI's `BundleReader` (`ditto -x`) |

**Exceptions** live in `scripts/check_rules.exceptions`, one per line with a reason. An exception whose text is no longer in its file fails the run, so the list cannot go stale.

**Doc paths.** The same run checks backticked paths in the agent and contributor docs that start with one of a fixed list of top-level folders (`App/`, `Packages/`, `Resources/`, `scripts/`, `docs/` and a few private ones) and contain no spaces; each must exist. Placeholders, Markdown links and bare root filenames are not checked.

## What is outside these checks

- What the `codex` binary does internally once Kvotar launches it. Kvotar launches it read-only; see `docs/credentials-and-privacy.md`.
- How often Kvotar polls and how it backs off. Those are product decisions with their own records in `docs/decisions/`.
- **The copy rule.** User-facing text never names polling internals ("throttled", "retry", "rate limit"…). It is a product voice rule, not a safety rule: one shared word list (`UserCopyRules.pollingWords`) is checked by the explanation-registry and notification tests, and changing the rule needs the maintainer's approval.

Checked against the code at 8aebac0.
