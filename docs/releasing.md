---
summary: The maintainer's checklist for cutting a Kvotar release — the bump commit, the build, the update feed, the tag and GitHub Release, the Homebrew cask — and the rulings that hold for every release.
read_when: Cutting a release, or checking what a published release must carry. Maintainer only.
---

# Releasing

Only the maintainer cuts a release. What a version, a build number and a beta label mean is in
[updates and releases](spec/updates-and-releases.md#version-and-build-numbers).

1. **Run `make prepare-release` on `main`.** It raises `CURRENT_PROJECT_VERSION` and
   `KVOTAR_PRERELEASE_LABEL` by one in `project.yml`, repeats the new values on the updates and
   releases page, moves the "Unreleased" lines of [CHANGELOG.md](../CHANGELOG.md) under a new
   heading, `<version> <label> (<build>) — <date>`, linked to the tag's GitHub Release, and pushes
   the commit `Bump to <version> <label> (<build>)`. It refuses when the tree is dirty, `main` is
   behind `origin/main` or "Unreleased" is empty.
2. **Build from the bump commit.** Build, sign and notarize it with the private tooling. If
   something else merges first, still build the bump's commit, never a later one.
3. **Publish the update feed.** Publish to the staging feed, check it, then promote it to
   `https://updates.kvotar.com/appcast.xml`.
4. **Tag the commit and publish the GitHub Release.** After promotion, push the tag
   `v<version>-<label>` on the built commit, with the message `Kvotar <version> <label> (<build>)`.
   The GitHub Release has the same title. Its text is the changelog section, the full commit, the
   zip's SHA-256 and the zip's address under `https://updates.kvotar.com/builds/`. Its files are
   the zip and its `.sha256`, byte for byte the ones the feed serves.
5. **Update the Homebrew cask,** once the tap exists: set its version and SHA-256 to this release
   on the same day. If a release is withdrawn, the cask goes back to the previous build in the
   feed, or is disabled when there is none.

## Rulings that hold for every release

- The tag is annotated and, for now, not signed. It is pushed once and never moved or deleted.
- The GitHub Release is marked pre-release while the label is a beta.
- The changelog names every user-facing change since the last build. A change to the CLI alone
  stays out, because the CLI is not in the release zip.
- Release notes write the support address as "hello at kvotar.com", without an `@`.
- A migration note is written only when the release changes the data or the settings.

## Done when

- An installed copy of the previous build updates through Sparkle from the production feed, and
  its data stays.
- The changelog heading links to the tag.
