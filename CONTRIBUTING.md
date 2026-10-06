# Contributing to Kvotar

A change reaches Kvotar by one of two paths: straight to a pull request, or an agreed contract first.
The rules that hold on both paths are in [AGENTS.md](AGENTS.md).

## Which path

- **Straight to a pull request:** the change makes Kvotar do what the docs already say it should, or
  changes nothing a user or a spec page would notice. A bug fix in a sensitive area counts, as long
  as the pull request shows it with a test.
- **An agreed contract first:** the change adds a feature, changes what Kvotar is meant to do (so a
  spec page would have to say something different), or changes how an area on the approval list in
  [VISION.md](VISION.md) works in a way no spec page already describes.

Tests, CI, docs wording, refactors and version bumps usually take the first path, but the two tests
above decide, not the kind of change.

## Proposing work

Open an issue with one of the three templates: bug report, feature request or contract. A
**contract** is a GitHub issue with four short sections: Goal, Contract, Proof and Deliberately
untouched. The maintainer approves it by adding the `agreed` label. A feature request that gets
agreed is expanded in place into a contract; nobody opens a second issue. The issue number is the
contract's only ID.

## Working on a contract

1. Read the contract issue and the docs it names. If it needs something that is not in the
   repository, stop and say so.
2. The agreed contract is the plan. If you would have to depart from it, or the code and a spec page
   disagree in a way it does not cover, stop and ask; do not fix it on the side.
3. One contract per session and per pull request. Finish it and stop.
4. The spec page changes in the same pull request as the code. A mismatch you find between a spec
   page and the code goes into that page's *Known gaps* table, with a proposed fix.
5. Run `make test` and `make check` before handing off, and say what passed, failed or was skipped.

## What a pull request contains

1. **Summary**: what changes and why.
2. **Commands run** and their result: `make test` and `make check`.
3. **Proof using synthetic data only**, saying what was and was not proven
   ([.github/pr-proof/README.md](.github/pr-proof/README.md)).
4. **`Closes #n`** when the change needed a contract.

A change that users can see also adds one line to [CHANGELOG.md](CHANGELOG.md) under "Unreleased",
in the file itself. Any other change adds no changelog line.

## Merging

One branch and one pull request per change, squash-merged, so each pull request is one commit on
`main`. The title says what is now true, in plain words, with no prefix. Before the merge, the
`checks` run (`.github/workflows/checks.yml`) must be green and the branch up to date with `main`.

## How a merged change reaches a release

Kvotar is developed in this repository. When your pull request is accepted:

1. It is merged here directly, with your authorship kept.
2. It ships in the next release, which is built from this repository.
3. You are credited by name in [CHANGELOG.md](CHANGELOG.md).

## Maintainer only

The maintainer agrees contracts and cuts releases ([docs/releasing.md](docs/releasing.md)). Agreeing
a contract includes its stated live checks, unless the maintainer reserves them for themselves:
build and launch the app for them and hand over only the clicks. A maintainer's "I'll do the live
check" wins.

## Licensing

By contributing you agree that your contribution is licensed under the [Apache License 2.0](LICENSE),
like the rest of the repository. The name "Kvotar" is reserved for official releases; see
[TRADEMARK.md](TRADEMARK.md).

There is no `NOTICE` file. Apache-2.0 asks for one only when the work already carries one, and none
of the bundled third-party components (Sparkle, GRDB.swift, swift-argument-parser, whose licenses are
in `Resources/THIRD_PARTY_NOTICES`) ships a NOTICE file.
