# STEP_275 — Before the repository goes public: the consent dialog names the database copy, the license names its holder, and four small text fixes

**refs:**
- [docs/spec/diagnostics.md](../docs/spec/diagnostics.md) — "Turning it on and off" (the alert
  text) and "Save Diagnostics…" (`kvotar.db`, not redacted).
- [docs/credentials-and-privacy.md](../docs/credentials-and-privacy.md) — extended diagnostics.
- [docs/decisions/0004-diagnostics-consent-and-redaction.md](../docs/decisions/0004-diagnostics-consent-and-redaction.md).
- [docs/spec/product-scope.md](../docs/spec/product-scope.md) — Decided 1 (Settings window planned,
  no release target).
- `App/AppDelegate.swift` (`configureExtendedDiagnostics`), `App/Info.plist`, `LICENSE`,
  `.github/ISSUE_TEMPLATE/feature_request.md`,
  [STEP_253_settings_window_and_support_folder_rulings.md](STEP_253_settings_window_and_support_folder_rulings.md).
- [STEP_273_doc_followups_group_d.md](STEP_273_doc_followups_group_d.md) — the pattern.

**Approval:** the maintainer, 2026-10-05. Touches *diagnostics and privacy* on the
[VISION.md](../VISION.md) approval list (consent-dialog copy only; no behavior change).

**blocked_by:** none.

## Goal

A pre-publication check found that the extended-diagnostics consent dialog does not say what the
docs already say: a diagnostics bundle saved in the window carries an unredacted copy of the
database. It also found a build comment that points at private release notes, two issue-template
links that break inside an issue, release-stage names in one contract, and a license that names no
copyright holder. Now the dialog says it, the license names its holder, and those lines are fixed.

## Contract

1. **Consent dialog.** `AppDelegate.configureExtendedDiagnostics`: the alert's informative text
   gains one sentence after the first, word for word:
   *A diagnostics bundle saved while it is on also includes an unredacted copy of Kvotar's
   database, with your account email and project folder names.*
   Title, buttons and the other sentences stay. `diagnostics.md` "The alert text says" quotes the
   new text in full; its last line becomes `Checked against the code at d5e44af + STEP_275`.
2. **Info.plist.** The XML comment above `SUFeedURL` is removed. Every key and value stays
   unchanged.
3. **Feature-request template.** The links to `VISION.md` and `docs/decisions/TEMPLATE.md` become
   absolute `https://github.com/vladamarkov/kvotar/blob/main/…` URLs, so they work inside an issue.
4. **STEP_253 contract.** Lines 15–16, 21 and 22 name no release stage: there is no Settings window
   today; the window is planned, with no release target (product-scope Decided 1).
5. **LICENSE.** The appendix's boilerplate line `Copyright [yyyy] [name of copyright owner]` is
   filled in as `Copyright 2026 Vladimir Marković`. The rest of the Apache License 2.0 text stays
   word for word.

## Proof

1. The app builds; the `KvotarTests` scheme passes; `make check` passes.
2. `plutil -lint App/Info.plist` passes, and its keys and values are the same before and after.
3. The changed links resolve; no "Alpha" remains in the STEP_253 contract.
4. `LICENSE` differs from the Apache License 2.0 text only in the filled copyright line.
5. A different agent checked the diff against this contract.

## Deliberately untouched

Any other code or copy; the README screenshot; test fixtures; repository settings; the
open questions on the spec pages.

## Definition of done

- The proof items hold.
- `diagnostics.md` quotes the new dialog text.
- One commit, `STEP_275: …`, lands the changes and this contract.
