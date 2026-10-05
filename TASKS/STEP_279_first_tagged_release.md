# STEP_279 — Kvotar 0.3.0 beta.10 (19) is built from a commit of this repository, and that commit carries a public tag and checksum

**refs:**
- [docs/spec/updates-and-releases.md](../docs/spec/updates-and-releases.md) — "Configuration
  keys" (the `project.yml` table), "Version and build numbers", "From a merged commit to a
  release", "Known gaps" (the first row).
- [CHANGELOG.md](../CHANGELOG.md) — "Unreleased".
- [CONTRIBUTING.md](../CONTRIBUTING.md) — "Before a pull request merges", "How a merged change
  reaches a release".
- `project.yml` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, `KVOTAR_PRERELEASE_LABEL`).
- [STEP_278_homebrew_tap.md](STEP_278_homebrew_tap.md) — reads `<version>`, `<label>`, `<build>`,
  `<tag>` and `<sha256>` from this release.

**Approval:** the maintainer, 2026-10-05, with these rulings: the GitHub Release is a pre-release
with the zip and its `.sha256` attached; the tag is annotated and not signed for now; no migration
note (nothing in the data or settings changes); the release notes write the support address as
"hello at kvotar.com", without an `@`; the CLI-only change to `kvotar capture --enable` stays out
of the CHANGELOG (the CLI is not in the release zip). Touches nothing on the [VISION.md](../VISION.md) approval
list: no app behavior, no new network use, no new data.

**blocked_by:** none.

## Goal

Every Kvotar build so far was made before the code was public, so nothing public says which source a
downloaded app came from ([updates and releases — Known gaps](../docs/spec/updates-and-releases.md#known-gaps)).
This step makes the next build, `0.3.0 beta.10 (19)`, from a commit on `main` of this repository,
tags that commit, and publishes the zip's SHA-256 next to the tag. Anyone can then check out the tag,
read the code that went into the app they run, and check their download against the checksum. The
Homebrew cask (STEP_278) points at this release.

## Contract

### A. The version bump (one pull request)

1. `project.yml`: `CURRENT_PROJECT_VERSION` `"18"` → `"19"`, `KVOTAR_PRERELEASE_LABEL` `"beta.9"` →
   `"beta.10"`. `MARKETING_VERSION` stays `"0.3.0"` (same audience).
2. `CHANGELOG.md`: the "Unreleased" lines move under a new heading
   `## 0.3.0 beta.10 (19) — <release date>`, above `0.3.0 beta.9 (18)`, and "Unreleased" is left
   empty. The section names every user-facing change merged since build 18, in plain words; the
   maintainer approves the wording in the pull request. Expected lines, beyond the three already in
   "Unreleased":
   - the first-run Privacy screen names the calls the app makes: the quota checks to Anthropic and
     OpenAI, and the daily update check;
   - the dialog that turns on extended diagnostics says the saved copy of the database is not
     redacted;
   - the support address in the About panel and in saved diagnostics is on kvotar.com;
   - a restarted Codex connection is no longer failed by the old one closing.
3. `docs/spec/updates-and-releases.md`, "Configuration keys", the `project.yml` table:
   `CURRENT_PROJECT_VERSION` reads `19`, `KVOTAR_PRERELEASE_LABEL` reads `beta.10`, and the
   "It is not the beta label" bullet's example follows (`beta.10`).
4. The pull request goes through the usual rule (CONTRIBUTING.md): `checks` green, branch up to
   date. The merged commit on `main` is the **release commit**. Nothing else merges into `main`
   between this merge and the build; if something does, the build uses this pull request's merged
   commit, never a later one.

### B. The release (outside this repository)

5. The release commit is built, signed, notarized, published to the staging feed, checked, and then
   promoted to `https://updates.kvotar.com/appcast.xml`, as
   [updates and releases](../docs/spec/updates-and-releases.md) says: outside this repository.
   The zip is `Kvotar-0.3.0-beta.10-build.19-macos-universal.zip`.
6. A real update from build 18 to build 19 is taken through the production feed on an installed
   copy: **Check for Updates…** offers 19, **Install** replaces the app, it relaunches, both tools
   are read, the data stays.

### C. The tag and its checksum (after promotion)

7. **The tag `v0.3.0-beta.10`**, annotated, on the release commit, message
   `Kvotar 0.3.0 beta.10 (19)`. It is pushed once, after promotion, and never moved or deleted. It
   is not signed (see Deliberately untouched).
8. **A GitHub Release for that tag**, marked pre-release, titled `Kvotar 0.3.0 beta.10 (19)`. Its
   text: the CHANGELOG section, the full release commit, the SHA-256 of the zip, and the zip's
   address under `https://updates.kvotar.com/builds/`. Its files: the same zip and its `.sha256`,
   byte for byte the ones the feed serves.

### D. The records (one pull request, after the tag)

9. `docs/spec/updates-and-releases.md`:
   - "From a merged commit to a release", the third bullet becomes: **Which commit a published
     build came from:** from `0.3.0 beta.10 (19)` on, the tag `v<version>-<label>` (for example
     `v0.3.0-beta.10`) marks the commit the build was made from, and the GitHub Release of that
     tag gives the zip's SHA-256. Earlier builds were made before the code was public and have no
     tag here.
   - "Version and build numbers": "from `0.3.0 beta.2 (11)` to `0.3.0 beta.9 (18)`" →
     "… to `0.3.0 beta.10 (19)`".
   - "Known gaps": the row "No public record maps a build to its source commit" is removed.
   - Its "Checked against" line names the release commit and STEP_279.
10. `CHANGELOG.md`: the `0.3.0 beta.10 (19)` heading links the GitHub Release.
11. `TASKS.md`: this row is removed; STEP_278's row is no longer blocked by it.

## Proof

12. `git rev-parse v0.3.0-beta.10^{commit}` equals the commit `main` got from item 4, and the
    `checks` run on that commit is green.
13. The zip's SHA-256 is the same in four places: the GitHub Release text, its `.sha256` file, a
    fresh download from `https://updates.kvotar.com/builds/…`, and a fresh download from the GitHub
    Release (`shasum -a 256 -c`).
14. The downloaded app reports `0.3.0 (19)` in About, passes Gatekeeper as notarized, and its
    `CFBundleVersion` is `19`.
15. The update of item 6, recorded with the log lines `Update available` (`build` 19) and
    `Installing update`.
16. `make check` and `make test` pass on the item 9–11 pull request (its `checks` run is green).

## Deliberately untouched

- **Signing the tag.** The maintainer has no signing key set up for git; an annotated tag on a
  protected `main` and the published checksum are this step's guarantee. A later step may sign tags.
- **A tag for build 18 or earlier.** Those builds came from code that was not public; no commit here
  made them.
- **Reproducible builds.** The tag says which source went into the app; it does not promise that
  building it again gives the same bytes.
- **The CLI's own version constant** (`KvotarVersion`, still `0.2.0 (5)`). The CLI is not in the
  release zip; bringing it in line is its own step.
- **The app, its updater keys and the feed.** No code changes; only the three `project.yml` numbers.
- **Repository settings.** No branch, tag or merge rule changes.

## Definition of done

- The proof items hold.
- `docs/spec/updates-and-releases.md` and `CHANGELOG.md` say what items 3, 9 and 10 say.
- Two commits land on `main` (the bump, the records), each through a pull request, and work stops.
