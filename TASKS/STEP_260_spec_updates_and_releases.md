# STEP_260 — Updates and releases are one public spec page

**refs:**
- [docs/spec/INDEX.md](../docs/spec/INDEX.md) — where this page goes; the shared rules it links.
- [docs/spec/quota-readings.md](../docs/spec/quota-readings.md), [docs/spec/state.md](../docs/spec/state.md), [docs/spec/display-semantics.md](../docs/spec/display-semantics.md), [docs/spec/polling.md](../docs/spec/polling.md) — the shared rules; link them, never restate them.
- [ARCHITECTURE.md](../ARCHITECTURE.md), [PATTERNS.md](../PATTERNS.md), [VISION.md](../VISION.md).
- [README.md](../README.md), [CONTRIBUTING.md](../CONTRIBUTING.md#how-a-merged-change-reaches-a-release), [CHANGELOG.md](../CHANGELOG.md) — install, the path to a release, published versions; link them.
- [docs/credentials-and-privacy.md](../docs/credentials-and-privacy.md#the-network) — what an update check sends; link it.
- [docs/spec/diagnostics.md](../docs/spec/diagnostics.md) — the build channel's debug default; link it.
- Code: `App/UpdaterService.swift`, `App/Info.plist`, `project.yml`, `BuildChannel` in `Packages/KvotarCore/Sources/KvotarCore/DiagnosticsCapture.swift`, `App/Kvotar.entitlements`, `Makefile`.

**Approval:** the maintainer, 2026-10-04. Documentation only; touches no
item on the [VISION.md](../VISION.md) approval list. A ruling the maintainer gives in review is
recorded on the page as a *Decided* entry.

**blocked_by:** none.

## Goal

A contributor changing the updater, a version number, the build channel or the release flow finds what an update check does, when it runs and what the user controls, which keys configure it, how version and build numbers move, and how a merged commit reaches a release.

## Contract

1. Write `docs/spec/updates-and-releases.md` describing what the code and tests do today, in the format of the
   existing spec pages: front matter `summary` and `read_when`; **Questions for owner** (or
   "None"); **Decided** if the maintainer ruled; **About this page**; the current rules with their
   reasons; rejected alternatives where they matter; **Known gaps** with a proposed fix per row;
   code and test pointers; last line `Checked against the code at <parent commit> + STEP_260`.
2. Link, never restate, a rule another page owns.
   - The page owns the updater's policy and its two user controls (their menu copy is `menu-actions.md`'s, STEP_257), its configuration keys, its logs, the build channel, version and build numbering, and distribution.
   - Public facts only: nothing about signing material, notarization credentials, hosting internals or release tooling.
   - Describe only the source-to-release mapping a reader can verify in this repository; where none exists, say so as a Known gap.
   - "Quota window" means only the five-hour or weekly refill period. The separate window that shows the quota (`QuotaWindowController`, opened by **Open in Window**) is the **app window**. Monthly labels, if mentioned, are "This machine", "Elsewhere", "Not observed"; `offMachine` and `unattributed` are internal names.
   - No public record maps a build to its source commit today: a Known-gaps row. Release tags are already planned work, not a new decision.
   - The build channel (`KVOTAR_CHANNEL`, `release` or `beta`) is distinct from the beta label in the version and artifact name (for example `beta.9`). The per-channel debug-logging default is [diagnostics](../docs/spec/diagnostics.md)'s; link it.
3. `docs/spec/INDEX.md` lists the page under *Topic pages* with its code areas, and drops it from
   *Topics without a page yet*.

## Proof

1. A different agent than the writer checked every factual claim against the code and tests; every
   unresolved finding is on the page.
2. Relative links and anchors resolve; `make check` passes.
3. A fresh agent with only this repository reaches the page from `AGENTS.md` through the index for
   a representative task: "change how often Kvotar checks for updates".
4. No personal or account data, private paths or credential material on the page.

## Deliberately untouched

Any app code. `README.md`, `CONTRIBUTING.md`. Other spec pages except `INDEX.md`.

## Definition of done

   - The proof items hold.
   - One commit, `STEP_260: …`, lands the page, the index change and this contract.
