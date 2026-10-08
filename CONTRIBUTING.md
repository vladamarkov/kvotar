# Contributing to Kvotar

- A fix that restores documented behaviour, or a change nobody and no spec page would notice:
  open a pull request.
- A new feature, or a change to what Kvotar is meant to do: open an issue first, describe the
  problem and the outcome you want, and wait for the `agreed` label.
- Unsure: open an issue and it gets scoped there.

An agreed issue records the problem, the behaviour agreed, what is deliberately left out and how to
tell it is done. How to build it is not settled there.

The safety rules in [AGENTS.md](AGENTS.md) bind every change.

## Your first pull request

1. Fork the repository and clone your fork.
2. For a code change, `brew install xcodegen` and run `make test` once, so you know your Mac can
   build and test Kvotar. The prerequisites are in [README.md](README.md#build-from-source). A
   docs-only change needs nothing but git.
3. The rules every change follows are in [AGENTS.md](AGENTS.md). Coding agents read it on their
   own.
4. Open the pull request with the template. The `checks` run must be green.

## What a pull request contains

The pull request follows [.github/pull_request_template.md](.github/pull_request_template.md):

1. **Summary**: what changes and why. A short diff sketch or tree is fine when it says it better
   than prose.
2. **Checks**: `make test` and `make check` and their results. A docs-only change runs `make check`
   alone.
3. **Proof using synthetic data only**, saying what was and was not proven
   ([.github/pr-proof/README.md](.github/pr-proof/README.md)).
4. **Risk**: whether a revert restores the old behaviour cleanly, and what a user would notice.
   "None" is fine.
5. **`Closes #n`** when the change needed an agreed issue.

The spec page changes in the same pull request as the code. A mismatch you find between a spec page
and the code goes into that page's *Known gaps* table, with a proposed fix.

A change that users can see also adds one line to [CHANGELOG.md](CHANGELOG.md) under "Unreleased",
in the file itself. Any other change adds no changelog line.

The maintainer reviews every pull request, usually within a few days. If review asks for changes
you cannot make, say so: the pull request is then finished for you with your authorship kept, or
closed.

## Merging

One branch and one pull request per change, squash-merged, so each pull request is one commit on
`main`. The title says what is now true, in plain words, with no prefix. Before the merge, the
`checks` run (`.github/workflows/checks.yml`) must be green and the branch up to date with `main`.

The maintainer may push a release bump, a changelog line or a docs repair straight to `main`; the
`checks` run still runs on the push. Anything that changes code, a test or a spec page goes through
a pull request.

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

The maintainer agrees issues and cuts releases ([docs/releasing.md](docs/releasing.md)). The
maintainer's own work needs no agreed issue; one is opened when the change should be visible before
it lands. Agreeing an issue includes its stated live checks, unless the maintainer reserves them for
themselves: build and launch the app for them with `make run` and hand over only the clicks. A
maintainer's "I'll do the live check" wins.

## Licensing

By contributing you agree that your contribution is licensed under the [Apache License 2.0](LICENSE),
like the rest of the repository. The name "Kvotar" is reserved for official releases; see
[TRADEMARK.md](TRADEMARK.md).

There is no `NOTICE` file. Apache-2.0 asks for one only when the work already carries one, and none
of the bundled third-party components (Sparkle, GRDB.swift, swift-argument-parser, whose licenses are
in `Resources/THIRD_PARTY_NOTICES`) ships a NOTICE file.
