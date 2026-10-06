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
3. If users can see your change, its line in [CHANGELOG.md](CHANGELOG.md) credits you by name.

## Running a development build

`make run` makes an unsigned Debug build for your Mac, asks a running Kvotar to quit once the build
has succeeded, launches the new build and prints its path. It never touches the copy in
Applications. To go back to the installed release, quit the development build and open Kvotar from
Applications.

- **It shares the installed copy's data.** The build has the same bundle identifier, so it polls
  the providers with your real Claude and Codex sign-ins, and reads and writes the same database and
  settings ([storage](docs/spec/storage.md#where-the-data-lives)). What it changes is still there
  when you reopen the release.
- **Only one copy runs at a time.** A second copy hands off to the first and quits, which is why
  `make run` quits the running one first.
- **A migration it applies stays applied.** A build with a new migration runs it on the real
  database at launch. The installed release still opens that database: it runs only the migrations
  it knows, skips any it does not, and undoes nothing. A table or nullable column it does not know
  is harmless to it. Rows a migration deleted or rewrote stay that way, and a migration that removes
  or renames something the release uses breaks the release until it is updated. A migration also
  never runs twice, so one you change after running it leaves your database in its first shape.
- **Two variables show states your account may never reach.** `make run` passes these two to the
  app, and no others:
  - `KVOTAR_MENU_BAR_FIXTURE=<name> make run` forces one long-limit warning onto the menu-bar item,
    for example `claude-limit-nearly-spent`
    ([menu bar](docs/spec/menu-bar.md#looking-at-it-without-a-live-warning)).
  - `KVOTAR_NOTIFICATION_FIXTURE=<name> make run` sends one scripted set of banners, for example
    `ladder-steps`
    ([notifications](docs/spec/notifications.md#the-test-aid-kvotar_notification_fixture)).
- **For the debugger,** quit Kvotar, run `xcodegen generate`, open `Kvotar.xcodeproj` in Xcode and
  press Run.

## Maintainer only

The maintainer agrees contracts and cuts releases ([docs/releasing.md](docs/releasing.md)). Agreeing
a contract includes its stated live checks, unless the maintainer reserves them for themselves:
build and launch the app for them with `make run` and hand over only the clicks. A maintainer's
"I'll do the live check" wins.

## Licensing

By contributing you agree that your contribution is licensed under the [Apache License 2.0](LICENSE),
like the rest of the repository. The name "Kvotar" is reserved for official releases; see
[TRADEMARK.md](TRADEMARK.md).

There is no `NOTICE` file. Apache-2.0 asks for one only when the work already carries one, and none
of the bundled third-party components (Sparkle, GRDB.swift, swift-argument-parser, whose licenses are
in `Resources/THIRD_PARTY_NOTICES`) ships a NOTICE file.
