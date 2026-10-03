---
summary: The template for proposing a change on the approval list (credentials, network, storage, privacy, notifications, forecast, dependencies, platforms).
read_when: Before opening an issue or pull request for anything on the "needs approval first" list in VISION.md.
---

# NNNN — Short title of the decision

Copy this file into this folder under the next free number, fill it in, and open an issue linking it
before writing the code. Keep it to one page.

## Decision

What will be true after this change, in two to five sentences.

## Why

The problem, with evidence: what you observed, on which plan and macOS version, using synthetic or
redacted data only.

## Accepted behavior

The exact behavior, including edge cases and failure paths. Name the numbers (intervals, thresholds,
limits).

## Non-goals

What this deliberately does not do.

## Required tests

The tests that will fail if this decision is broken. Name them.

## Tradeoffs

What gets worse, for whom, and why it is still worth it. Which of the five rules in `AGENTS.md` this
touches, and why it does not break them.

## Status

Proposed.
