---
summary: What Kvotar is and is not, the two tools and the account kinds it covers, the few terms every other page assumes, and where to read next. A map, not a second README.
read_when: Starting on Kvotar for the first time, proposing a new tool, platform or kind of usage to cover, changing the Tool enum or ProductIdentity's name, tagline or description sentence, or deciding which page or overview owns a question.
---

# Product scope

## Questions for owner

None.

## Decided

The maintainer ruled on this on 2026-10-04 (STEP_248). The code does not follow it yet; its row in
*Known gaps* below names the change.

1. **There is no Settings window, and none is planned. Settings live in the right-click menu.**
   Reason: the [first-run window](first-run-window.md) page already rejects a Settings window for
   the notification switches; one place for settings is enough. Today four code comments still
   promise a future settings window.

## About this page

This page says what Kvotar covers and points to the page that owns each detail. It replaces the
private Implementation Baseline §1 (purpose), §2 (source-of-truth order), §3 (locked scope) and the
parts of §4 (terminology) that quota-readings does not already own. Which document wins is now in
[the spec index](INDEX.md). Change this page in the same commit as the code it describes.

## What Kvotar is

A native macOS menu-bar app that shows how much of your Claude Code and Codex quota is left, how
fast it is going, and whether it lasts until the reset. It calls itself *Claude Code and Codex
capacity intelligence* (`ProductIdentity.tagline`, shown in the right-click menu and the About
panel).

What it does and what "local" means: [README.md](../../README.md). Scope going forward:
[VISION.md](../../VISION.md). Code layout: [ARCHITECTURE.md](../../ARCHITECTURE.md).

It ships the menu bar and popover, notifications, the History window, the
[first-run window](first-run-window.md), the right-click menu (which holds the settings; there is no Settings window, Decided 1), the
`kvotar` command-line tool and one local database (`storage.md`, pending).

## What Kvotar is not

Beyond the limits README and VISION state (two tools, macOS 14 or newer, no telemetry, and no cloud
sync or Kvotar server receiving your usage, for now), three rules shape every page:

| Not | Why |
|---|---|
| A tracker of API-key or gateway billing | Quota comes from each tool's subscription sign-in |
| A multi-account or team view | One account per tool, the one it is signed in to now; a Team or Enterprise seat is one person's seat (`App/AppDelegate.swift`) |
| Something that acts for you | It never pauses, stops or changes a session; the user decides when to push or pace ([VISION.md](../../VISION.md)) |

What Kvotar never does with credentials and content is the four safety rules in
[AGENTS.md](../../AGENTS.md#the-four-safety-rules), each with its record in
[docs/decisions/](../decisions/).

## The two tools

Kvotar knows exactly two tools, `Tool.claude` and `Tool.codex`; the raw values are stored in the
database's `tool` columns. (`Packages/KvotarCore/Sources/KvotarCore/Tool.swift`)

| Tool | Menu-bar prefix | Popover tab | Quota and its reading | Credential |
|---|---|---|---|---|
| Claude | `CL` | Claude | `claude-account.md` (pending) | `credentials.md` (pending) |
| Codex | `CX` | Codex | `codex-account.md` (pending) | `credentials.md` (pending) |

Each tool has its own [polls](polling.md) and [state](state.md). A tool that is
[not detected](state.md#what-is-not-inferred-from-incomplete-evidence) shows a setup prompt
instead (`DetectionStatus.classify`; [first-run window](first-run-window.md)).

## Account kinds

| Tool | Kinds covered |
|---|---|
| Claude | Pro, Max, Team, Enterprise |
| Codex | Free, Go, Plus, Pro, Business, Enterprise |

Accounts differ in shape: windows, monthly limits, credits. No window rule branches on the plan name
([quota readings](quota-readings.md)); the one carve-out is the Codex low-allowance shape for Free
and Go ([state](state.md)).

How each kind is recognized and labelled is on the account pages; a Claude Team seat's label is a
Known gap on `claude-account.md` (pending). Monthly limits and credits: the
credits-and-monthly-limits page (pending).

## Terms a newcomer needs

Most terms live on the shared pages: reading, window, reset, used percent, stale in
[quota readings](quota-readings.md#the-vocabulary); state and severity in [state](state.md);
percent left in [display semantics](display-semantics.md); poll, refusal and hold in
[polling](polling.md#terms-used-here). Only these are defined here:

| Term | Meaning |
|---|---|
| **Tool** | Claude or Codex: one of the two `Tool` cases |
| **Account** | The one subscription a tool is signed in to now. Kvotar has no account of its own |
| **Surface** | A local app that spends a tool's quota on this Mac. Claude has one, Claude Code. Codex has `Desktop`, `CLI` and `IDE extension`; an unmapped one is `Unknown`. (`CodexSurface.bucket`; `SurfaceWorkSplit.claudeMainAgent`) |
| **Local activity** | Token use read from a tool's own session logs on this Mac (with Codex's local metadata), never the text. Owned by `local-usage.md` (pending) |
| **Elsewhere** | Quota use no local activity on this Mac explains: Claude Desktop chat (no session log), the web, a phone, another computer. Estimated, not measured. The popover header says `Not seen locally`; identifiers say `offMachine` |
| **Est. token value** | What local tokens would cost at published API prices. An estimate, never "cost" (`estimated-value.md`, pending) |

The naming rules for code and copy are in [PATTERNS.md — Naming
conventions](../../PATTERNS.md#naming-conventions-baseline-4). Window names belong to
[quota readings](quota-readings.md), which wins where the PATTERNS table differs.

## Rejected alternatives

From the private scope record; reopening any needs the maintainer's approval: more tools (Cursor,
Copilot, Windsurf); API or gateway usage; several accounts per tool; telling editor hosts apart
beyond `IDE extension`; syncing session logs between machines; a dashboard, a team view, automatic
intervention or blocking.

## Known gaps

| Gap | Today | Proposed |
|---|---|---|
| Comments promise a Settings window | `MenuBarController`, `AppDelegate`, `AppViewModel` and `MenuBarDisplay` say a future settings window absorbs the display picker | Delete the promise from the four comments (Decided 1) |
| PATTERNS naming table fixes window names | Fixed `5-hour` and `Weekly`; quota-readings names windows from their width | Point the two PATTERNS rows at quota-readings |
| `off-machine` in shipped copy | The since-last-look line says `+N% off-machine` (`DeltaLine.swift`); PATTERNS bans it | Say `elsewhere`, with the popover or explanations page (pending) |

## Code and test pointers

- `Packages/KvotarCore/Sources/KvotarCore/Tool.swift`: `Tool`, `menuBarPrefix`, `tabLabel`. Test:
  `AppViewModelTests` (rendered `CL` / `CX` lines).
- `Packages/KvotarCore/Sources/KvotarCore/ProductIdentity.swift`: `productName`, `tagline`,
  `descriptionSentence` (file locations and the former name: `storage.md`, pending). Test:
  `ProductIdentityTests`.
- `Packages/KvotarCore/Sources/KvotarCore/Adapters/AccountAdapter.swift`: `DetectionStatus.classify`.
  Test: `DetectionStatusTests`.
- `Packages/KvotarCore/Sources/KvotarCore/Attribution/CodexSurface.swift`: the Codex surfaces.

Checked against the code at bcf929e + STEP_248
