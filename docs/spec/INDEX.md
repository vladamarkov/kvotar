---
summary: The map of Kvotar's spec pages — which page owns which feature and code area, how the pages depend on each other, and which topics have no page yet.
read_when: Starting any change, choosing which spec pages to read for a task or bug fix, adding a spec page, or moving a rule from one page to another.
---

# Spec index

Each page in `docs/spec/` is the current specification for one topic: the rule, its reason, the
code that implements it and the gaps still open. A page wins over a code comment that disagrees
with it. How to use the pages when you work on a task is in
[AGENTS.md — Working on a task](../../AGENTS.md#working-on-a-task).

## What on a page is a rule

- **The description of today's behavior is the current rule.** A change that departs from it
  needs a build step that changes the page in the same commit.
- **Decided** entries are the maintainer's rulings that the code does not follow yet. The ruling is
  the target; its Known-gaps row names the change, and a build step makes it.
- **Questions for owner**, and Known-gaps rows that do not cite a Decided entry, are proposals, not
  approved changes. A recommendation there is not permission to change the code. Each needs the
  maintainer's decision and its own build step.

## How to find the right page

1. If your task contract has a `refs:` line, read exactly those pages first.
2. Otherwise find the feature words or the code you will touch in the tables below. Each page's
   `read_when` line, at its top, names the code and behavior it governs.
3. Follow the links a page makes to the shared pages. A topic page links to a shared rule; it
   does not restate it.
4. If no page covers the behavior, or two pages disagree, say so and get the rule settled before
   you implement it. Do not guess from old comments.

## Shared rules

Four pages define the terms every other page uses. Read the one your change touches even when a
topic page also applies.

| Page | Owns | Feature words | Code areas |
|---|---|---|---|
| [Quota readings](quota-readings.md) | What a limit, a window, a reset and a reading mean; missing, unanchored and stale readings; freshness | limit, window, five-hour, weekly, reset, used, left, stale, null reading | `QuotaSnapshot` in `Packages/KvotarCore/Sources/KvotarCore/Adapters/AccountAdapter.swift`, reset and staleness checks in `StateEngine`, `DiscontinuityDetector`, the launch restore |
| [State](state.md) | Which state an account is in, severity, priority, thresholds, clearing, and what is not inferred from incomplete data | state, severity, amber, red, at risk, blocked, hysteresis | `Packages/KvotarCore/Sources/KvotarCore/State` |
| [Display semantics](display-semantics.md) | Percent left or used on each surface, colours, unknown and stale wording, cross-surface consistency, the copy rule | percent left, colour, unknown, stale wording, copy | `Packages/KvotarUI/Sources/KvotarUI/Model`, `Packages/KvotarCore/Sources/KvotarCore/UserCopyRules.swift` |
| [Polling](polling.md) | Cadence, extra polls, Kvotar's own refused poll versus the user's spent quota, holds and recovery | poll, cadence, refresh, 429, retry, hold, turn end | `App/PollCoordinator.swift`, `Packages/KvotarCore/Sources/KvotarCore/Polling`, 429 handling in the adapters |

## Topic pages

| Page | Owns | Code areas |
|---|---|---|
| [Diagnostics](diagnostics.md) | Debug logging, extended diagnostics capture and its consent, Save Diagnostics…, the CLI commands that touch them | `Packages/KvotarCore/Sources/KvotarCore/Diagnostics`, `Packages/KvotarCore/Sources/KvotarCore/DiagnosticsCapture.swift` |
| [First-run window](first-run-window.md) | When the first-run window opens, its screens and copy, the notification permission request, launch at login | `Packages/KvotarUI/Sources/KvotarUI/Views/Onboarding`, `App/OnboardingGate.swift` |
| [Product scope](product-scope.md) | What Kvotar is and is not, the two tools and the account kinds it covers, the terms every page assumes, and where to read next | `Packages/KvotarCore/Sources/KvotarCore/Tool.swift`, `Packages/KvotarCore/Sources/KvotarCore/ProductIdentity.swift`; README, VISION, ARCHITECTURE |
| [Credentials](credentials.md) | Finding and reading the Claude and Codex credentials, the read-only posture, an expired, missing or unreadable credential, and what is never done | `KeychainTokenProvider`, `ClaudeTokenProvider` and `ClaudeCredential` in `Packages/ClaudeAdapter`; `CodexTokenProvider` and `CodexAuthFileReader` in `Packages/CodexAdapter`; the expiry gate in `ClaudeAccountAdapter`; `CredentialTreesUntouchedTests` |

## Topics without a page yet

Until a topic has a page, its code, its tests and the [decision records](../decisions/) describe
it. These pages are planned; the names are the intended file names. When you need one of these
rules, read the code and the shared pages above, and say that the topic has no page yet.

| Planned page | Topic | Shared pages it builds on |
|---|---|---|
| storage | The database, retention and migrations | — |
| claude-account | Claude quota and prepaid data, model-scoped weekly limits | Quota readings, Polling |
| codex-account | Codex quota, the web fallback, Enterprise | Quota readings, Polling |
| local-usage | Local session discovery, token use, attribution | Quota readings |
| capacity-learning | Community limits and the personal observed ceiling | Quota readings |
| credits-and-monthly-limits | Credits, monthly limits and spend control | Quota readings, State |
| estimated-value | Pricing and estimated token value | — |
| forecast | Pace, burn and runway estimates | Quota readings, State |
| notifications | When notifications fire, the weekly ladder, delivery | State, Display semantics |
| menu-bar | The menu-bar item and its modes | Display semantics, State |
| popover | Popover layout, rows and recommendations | Display semantics, State |
| explanations | Hover cards and the verdict's anatomy | Display semantics |
| history | The History window and weekly recap | Display semantics |
| menu-actions | Right-click menu actions and settings | — |
| app-lifecycle | Launch, second opening, hidden menu-bar item recovery | — |
| cli | The `kvotar` command-line tool | Diagnostics |
| updates-and-releases | Updates, packaging, source-to-release mapping | — |

## Adding or changing a page

- One topic per page. A new page starts with front matter (`summary`, `read_when`), then
  **Questions for owner** (or "None"), any **Decided** rulings, the current rules with their reasons, rejected
  alternatives where they matter, **Known gaps**, code and test pointers, and a last line
  `Checked against the code at <parent commit> + STEP_nnn`.
- When a page lands, move its row from *Topics without a page yet* to *Topic pages* in the same
  commit.
- A rule lives on exactly one page. If you need it elsewhere, link to it.
