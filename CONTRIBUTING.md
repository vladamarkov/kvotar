# Contributing to Kvotar

Thanks for helping. Start with [AGENTS.md](AGENTS.md) (it applies to people as much as to agents) and
[VISION.md](VISION.md).

## Before you write code

- **Anything on the approval list in [VISION.md](VISION.md)** (credentials, network or polling,
  storage, diagnostics and privacy, notifications, copy rules, forecast logic, new dependencies, new tools or
  platforms): open an issue first, using [docs/decisions/TEMPLATE.md](docs/decisions/TEMPLATE.md).
  Wait for agreement before writing the change.
- Bug fixes, tests, docs and small UI fixes that follow the existing copy rules can go straight to a
  pull request.

## Build and check

```sh
make build
make test
make check
```

GitHub runs the same three commands on every pull request and every push to `main`
(`.github/workflows/checks.yml`), on macOS, with no account or credential. Run them locally
first; the GitHub run is a second check, not a replacement.

All three run without a Claude or Codex account. Never use real credentials, real session logs or a
real Kvotar database in a test, a screenshot or a pull request.

## What a pull request contains

1. **Summary**: what changes and why, in a few lines.
2. **Commands run** and their result: at least `make test` and `make check`.
3. **Proof using synthetic data only**: a test, a fixture, or a screenshot of fixture data. Say what
   the proof shows and what it does not. See [.github/pr-proof/README.md](.github/pr-proof/README.md).
4. **One line for [CHANGELOG.md](CHANGELOG.md)** under "Unreleased".
5. Whether it touches the approval list, with a link to the issue where it was agreed.

## How a merged change reaches a release

Kvotar is developed in this repository. When your pull request is accepted:

1. It is merged here directly, with your authorship kept.
2. It ships in the next release, which is built from this repository.
3. You are credited by name in [CHANGELOG.md](CHANGELOG.md).

## Licensing

By contributing you agree that your contribution is licensed under the [Apache License 2.0](LICENSE),
like the rest of the repository. The name "Kvotar" is reserved for official releases; see
[TRADEMARK.md](TRADEMARK.md).

There is no `NOTICE` file. Apache-2.0 asks for one only when the work already carries one, and none
of the bundled third-party components (Sparkle, GRDB.swift, swift-argument-parser, whose licenses are
in `Resources/THIRD_PARTY_NOTICES`) ships a NOTICE file.

Checked against the code at e9d2933 + STEP_276.
