---
summary: What the STEP / REV / D / P1 numbers and Baseline or UI Spec section marks in code comments mean, and which public decision record covers the important ones.
read_when: A code comment cites an ID or a section (STEP_165, REV-96, D-58, Baseline §9.2, UI Spec §2.2a) and you want to know whether a public explanation exists.
---

# References in code comments

Before this repository became its home, Kvotar was built against a written specification that is
kept outside it. Comments in the code point back to that record. About 2,600 comment lines in shipped code and about 1,100 in tests name a
STEP, REV or D number, and several hundred more cite a section of the Baseline or the UI Spec (counted
at the commit below).

Those records are not published. The comments still tell you something: that the behavior was
decided on purpose, and roughly when. **Treat a cited line as intentional.** If you want to change
it, say so in an issue first, especially if the topic is on the approval list in
[VISION.md](../VISION.md).

## What each kind of reference means

| Form | What it is |
|---|---|
| `STEP_nnn` | One build step: a small, numbered unit of work with its own contract and tests. Higher numbers are newer. |
| `REV-nn` | A revision to the specification: a change of behavior or copy, decided before it was built. Usually implemented by one or more STEPs. |
| `D-nnn` | A recorded UI or product decision (copy, layout, interaction). |
| `P1-nn` | An entry in the known-issues list. |
| `R31-1`, `Change C`, `E6` and similar | A numbered item inside a REV or a spec section. |
| `Baseline §n` | A section of the Implementation Baseline: behavior, architecture, data sources, timeouts, storage. |
| `UI Spec §n`, `Part 2 §n`, `Part 3 §n` | A section of the UI Spec: copy, layout, interaction. Part 1 is Claude, Part 2 is Codex, Part 3 is app chrome and the explanation layer. |
| `Spike A`, `Spike C`, … | A measurement run on real accounts that informed a decision. |

## IDs with a public record

| Cited in code | Topic | Public record |
|---|---|---|
| STEP_165, STEP_48, STEP_42, REV-41, REV-37, Baseline §8.0.1 | Expired token gate, no refresh, 401/403 re-read | [0001 Never refresh](decisions/0001-never-refresh-a-token.md) |
| Baseline §8.0.1, §8.2, §5.2, REV-71 (credential unreadable vs absent) | Reading the Claude Keychain item and `auth.json` | [0002 Read through `security`](decisions/0002-read-claude-credential-through-security.md) |
| REV-39, REV-31, REV-32, REV-86, REV-88, REV-89, STEP_45, STEP_166, STEP_168, STEP_169, REV-14, P1-12, Baseline §9 | Cadence, 429 ladder, holds, User-Agent | [0003 Polling](decisions/0003-polling-and-rate-limits.md) |
| UI Spec Part 3 §5.2 | The copy rule: no polling words in UI copy | [0003 Polling](decisions/0003-polling-and-rate-limits.md) |
| REV-52, STEP_72, STEP_73, STEP_136, P1-31, STEP_171, Baseline §10.7a | Diagnostics bundle, capture consent, redaction | [0004 Diagnostics](decisions/0004-diagnostics-consent-and-redaction.md) |
| REV-83, STEP_152 | Sparkle updates | [credentials-and-privacy.md](credentials-and-privacy.md#the-network) |

## Most-cited IDs without a public record yet

These describe product behavior rather than safety rules. The code and its tests are the reference
until a topic doc is written.

| ID | Topic |
|---|---|
| REV-96, REV-98, REV-100 | Weekly and monthly limits: the "ahead of pace" and "nearly spent" tiers, the red bar, reminder decay |
| REV-106 | Weekly notification ladder (50 → 25 → 10 → 0 % left; 15 % instead of 10 on an account with only a weekly limit) |
| REV-84, REV-93, REV-104 | The History window and its weekly recap |
| REV-92, REV-94 | Popover layout and readability |
| REV-99 | The quota window and the hidden menu-bar item notice |
| REV-97 | The menu-bar reminder |
| REV-102 | Claude Team usage credits |
| REV-80, REV-57, REV-60, REV-59 | Window shapes: not started, unanchored, provider-reported width |
| REV-77, D-97 | Menu-bar and popover quota figures are "% left"; History and the hover cards also show "% used" |
| REV-62, REV-90 | Token pricing and the estimated value |
| REV-38, REV-40, REV-47, REV-48 | Enterprise monthly limits |
| REV-73 | Limit hits and lockout duration in History |
| REV-75, REV-67, D-90 | The explanation layer (hover cards, verdict anatomy) |
| REV-95, REV-105 | Forecast calibration and the blended burn rate |
| D-58, D-35, D-101 | The header caption, stale readings, the unknown `—` form |

Checked against the code at 62d7d98 + STEP_241.
