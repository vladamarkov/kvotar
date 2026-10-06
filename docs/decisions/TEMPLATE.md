---
summary: The shape of a decision record — the lasting explanation of a rule that is hard to reverse. Not a proposal form; a change is proposed as a contract issue.
read_when: An agreed contract creates or changes a rule that is hard to reverse and that a future reader would question, and the maintainer is writing its record.
---

# NNNN — Short title of the decision

A decision record is the lasting explanation of a rule. The maintainer writes one only when an
agreed contract creates or changes a rule that is hard to reverse and that a future reader would
question. It is not how a change is proposed: that is a contract issue
([CONTRIBUTING.md](../../CONTRIBUTING.md#proposing-work)). Keep it to one page.

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

Accepted, with the date and the number of the contract issue that agreed it.
