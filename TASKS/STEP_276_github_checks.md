# STEP_276 — Every pull request and every push to main runs the checks on GitHub, and a red run blocks the merge

**refs:**
- [AGENTS.md](../AGENTS.md) — "Commands" and "Working on a task".
- [CONTRIBUTING.md](../CONTRIBUTING.md) — "Build and check".
- `Makefile`, `scripts/check_rules.sh`, `scripts/test.sh`, `scripts/expected-skips.tsv`.
- [docs/safety-checks.md](../docs/safety-checks.md) — what `make check` and `make test` protect.
- [.github/pull_request_template.md](../.github/pull_request_template.md),
  [.github/pr-proof/README.md](../.github/pr-proof/README.md).
- [STEP_275_prepublication_fixups.md](STEP_275_prepublication_fixups.md) — the format.

**Approval:** the maintainer, 2026-10-05, with these rulings: the single `checks` job is the
required check; `macos-26` and Xcode 26.3 are pinned; a branch must be up to date with `main` before
it merges; runs from first-time contributors wait for approval (GitHub's default). Touches *new
dependencies* on the [VISION.md](../VISION.md) approval list: a hosted CI service and build-time
tools (XcodeGen, GitHub-maintained actions). Nothing new ships in the app.

**blocked_by:** none. The repository is public, so GitHub's standard hosted runners, macOS
included, are free ([GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions),
checked 2026-10-05).

## Goal

Today `make check`, `make test` and `make build` run only when someone remembers to run them, and a
pull request can merge with a broken build or a silently skipped test. After this step GitHub runs
all three on every pull request and every push to `main`, without any credential, and the
maintainer can make a green run a condition for merging.

## Contract

1. **One workflow file**, `.github/workflows/checks.yml`, named `checks`.
   - Triggers: `pull_request` (any target branch) and `push` to `main`. Never
     `pull_request_target`, never a schedule.
   - One job, `checks`, on `macos-26` (pinned, not `macos-latest`), `timeout-minutes: 60`.
   - `permissions: contents: read` at the top level. The file names no `secrets.` value and no
     environment; no `KVOTAR_*` variable is set.
   - `concurrency`: one run per branch or pull request; a newer push cancels the older run.
2. **Toolchain, pinned and printed.**
   - Selects Xcode 26.3 (`sudo xcode-select -s /Applications/Xcode_26.3.app`) and prints
     `xcodebuild -version` and `swift --version`.
   - Installs XcodeGen 2.45.4 from its GitHub release zip and checks the zip's SHA-256 against a
     value written in the workflow. Prints `xcodegen --version`. No `brew install`.
   - The only third-party action is `actions/checkout`, pinned to a full commit SHA with the
     version in a comment. No cache action.
3. **Steps, in order:** `make check`, `make test`, `make build`. `make test` and `make build` run even
   when an earlier step failed (`if: ${{ !cancelled() }}`), so one run shows every failure. The job is
   red when any step is red.
4. **Logs on failure.** When the job fails it uploads `$KVOTAR_BUILD_DIR/logs/` (the per-suite test
   logs and `report.txt`) as an artifact kept 7 days, with `actions/upload-artifact` pinned the same
   way. Nothing else is uploaded; the app is not.
5. **No behavior change to the scripts.** `Makefile`, `scripts/check_rules.sh`, `scripts/test.sh`
   and `scripts/expected-skips.tsv` stay as they are. If a test fails or skips only on the runner,
   do not skip it, list it or change it: record the test and its log line, and stop and ask.
6. **Docs.**
   - `CONTRIBUTING.md` "Build and check" gains, after the command block:
     *GitHub runs the same three commands on every pull request and every push to `main`
     (`.github/workflows/checks.yml`), on macOS, with no account or credential. Run them locally
     first; the GitHub run is a second check, not a replacement.*
     Its last line becomes `Checked against the code at <parent> + STEP_276`.
   - `AGENTS.md` "Commands" gains one line under the block: *The same three run on GitHub for every
     pull request (`.github/workflows/checks.yml`).* Its last line becomes
     `Checked against the code at <parent> + STEP_276`.
   - No `docs/spec/` page changes: CI is contributor tooling, not app behavior.
7. **Merge rule, recorded after the maintainer sets it.** This step never changes repository
   settings. After proof items 1–3 hold, the maintainer turns on the approved rule for `main`: the
   `checks` job is required, and the branch must be up to date before it merges. Runs from
   first-time contributors wait for approval (GitHub's default). The session then reads the
   settings back with read-only `gh api` calls (the `main` branch protection or ruleset, and the
   Actions setting for fork pull requests) and adds a short section to `CONTRIBUTING.md`, "Before a
   pull request merges", stating exactly what is on. It states only what the read-back shows; if the
   read-back differs from the approved rule, it says so and asks.

## Proof

1. **Green.** A pull request with this step's changes gets a green `checks` run: all three steps
   pass, and the `make test` table shows only expected skips. Its run link goes in the commit
   message body.
2. **Red on a rule.** A throwaway branch adds one line containing `SecItemAdd` to a file under
   `Packages/KvotarCore/Sources`. Its run is red at `make check` with an `R2` line, and `make test`
   and `make build` still ran.
3. **Red on an unexpected skip.** A throwaway branch adds one test that calls `XCTSkip` and is not in
   `scripts/expected-skips.tsv`. Its run is red at `make test` with
   `unexpected skip (not in expected-skips.tsv)`, and the logs artifact is attached.
4. Both throwaway branches are deleted and their pull requests (if any) closed unmerged. Their run
   links go in the commit message body.
5. The workflow file has no `secrets.` reference, no `pull_request_target`, and every `uses:` is
   pinned to a 40-character SHA (`grep` output in the commit message body).
6. `make check` passes locally; the changed docs' links resolve.
7. After the maintainer sets the merge rule: a pull request with a red run shows merging blocked,
   and the `CONTRIBUTING.md` section matches the read-back.

## Deliberately untouched

Repository settings and visibility (the maintainer sets them); signing, notarizing, releases and
tags; a Linux runner for `make check`; caching; test sharding; a schedule or nightly run; the
expected-skips list; any code or test; the spec pages.

## Definition of done

- The proof items hold, with run links for one green and two red runs.
- `CONTRIBUTING.md` says what runs on GitHub and exactly which merge rule is on.
- One commit lands for the workflow and the docs (`STEP_276: …`); if the merge-rule record waits
  for the maintainer, it lands as a second commit, `STEP_276: record the merge rule`, and work stops.
