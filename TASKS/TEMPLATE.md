# STEP_nnn — <what will be true when this lands, in plain words>

**refs:** the public docs this step needs, and only those: spec pages in `docs/spec/`, decision
records in `docs/decisions/`, `ARCHITECTURE.md`, `PATTERNS.md`, named source files and tests. Every
ref must exist in this repository.

**Approval:** who approved it and when, and which items on the [VISION.md](../VISION.md) approval
list it touches (or "none").

**blocked_by:** another step, or none.

## Goal

One short paragraph: the problem as a user or a maintainer sees it, and what changes.

## Contract

Numbered items. Each says exactly what changes, where, and what the result must be. Name the files
and the spec page sections. Exact copy goes here word for word.

Spec pages: name the page(s) in `docs/spec/` this step updates in the same commit, and what each
must say afterwards.

## Proof

Numbered checks that show the contract holds: the tests added or changed, `make test`, `make check`,
and any synthetic reproduction or screenshot. Fixtures only; no live provider calls.

## Deliberately untouched

What a reader might expect this step to change, and does not.

## Definition of done

- The proof items hold.
- The named spec pages describe the new behavior.
- One commit lands for the step, and work stops.
