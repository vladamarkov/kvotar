# STEP_242 — The privacy screen says what it sends; consent has one door

**refs:**
- [docs/spec/first-run-window.md](../docs/spec/first-run-window.md) — screen 5 (*What Kvotar never sees*) and its known gap.
- [docs/spec/diagnostics.md](../docs/spec/diagnostics.md) — *Turning it on and off*, *CLI commands today*, *Known gaps*.
- [docs/credentials-and-privacy.md](../docs/credentials-and-privacy.md) — *The network* (what the app actually calls) and *Diagnostics*.
- [docs/decisions/0004-diagnostics-consent-and-redaction.md](../docs/decisions/0004-diagnostics-consent-and-redaction.md) — why consent needs an expiry.
- Code: `Packages/KvotarUI/Sources/KvotarUI/Views/Onboarding/OnboardingView.swift` (`OnboardingPrivacyScreen`), `Packages/KvotarCLI/Sources/KvotarCLI/Capture.swift`, `Packages/KvotarCLI/Tests/KvotarCLITests/`.

**Approval:** owner rulings of 2026-10-02 (the copy below and the removal of `--enable`). Touches
the approval list in [VISION.md](../VISION.md): *Diagnostics and privacy* (approved by those
rulings). No change to polling, credentials, storage, migrations, notifications or the app's
consent dialog.

**blocked_by:** none.

## Goal

1. **The first-run Privacy screen overstates.** Its support line reads: *"Local only. Read only. Once
   a day it asks kvotar.com whether there's a new version — that's the only thing it sends."* The
   app also calls Anthropic and OpenAI on every poll, with the user's own sign-in.
   `docs/credentials-and-privacy.md` says so; the app's own screen must agree.
2. **`kvotar capture --enable` cannot work and says it did.** It writes
   `diagnostics_capture_enabled = 1` with no `diagnostics_capture_expires_at`. Consent needs both,
   so the running app reads it as off and writes `0` straight back, while the CLI prints
   "Diagnostics capture enabled." No consent is bypassed; the CLI misleads.

**Owner ruling:** fix the copy; **remove `--enable`**. The app's confirmation dialog (*Enable
Extended Diagnostics for 24 Hours…*) becomes the only way to open capture. One consent path is
easier to trust and to explain.

## Contract

### 1. The Privacy screen copy

1. In `OnboardingView.swift`, the *What Kvotar never sees* support line becomes exactly:
   > Local only. Read only. It asks Anthropic and OpenAI for your quota with your own sign-in, and once a day asks kvotar.com for updates. Nothing else leaves your Mac.
2. It must still fit the screen at the window's fixed size (480 × 440), in light and dark: no
   truncation, and no new line wrap that pushes the two columns down.
3. The comment above that line (D-105e) must stop calling the update check "the one thing the app
   sends"; say what the line now names.

### 2. One consent path

4. `kvotar capture` keeps `--disable` (off, and deletes captured replies) and `--status`.
   `--enable` is removed.
5. Running `kvotar capture --enable` fails with a message that says how to turn capture on: from
   the menu-bar item's right-click menu, *Enable Extended Diagnostics for 24 Hours…*. Exit
   non-zero.
6. `CaptureReport.Action.enabled` and its output paths go if nothing else uses them.
7. `kvotar debug --enable` is untouched (debug logging is not consent-gated).

### 3. Docs, in the same commit

8. `docs/spec/diagnostics.md`:
   - *CLI commands today*: `kvotar capture --disable | --status` only.
   - *Turning it on and off*: one sentence that capture opens only from the app's dialog, because
     consent needs an expiry and the CLI does not ask for one.
   - Add a **Rejected, don't re-propose** line: *a CLI path to turn capture on* — consent needs a
     visible, expiring confirmation, and a second door is a second thing to trust and explain.
   - Remove the `kvotar capture --enable` row from *Known gaps*.
   - Its `Checked against` line becomes `<parent commit> + STEP_242`.
9. `docs/spec/first-run-window.md`: screen 5's support line becomes the new copy; remove the row
   from *Known gaps*; `Checked against` becomes `<parent commit> + STEP_242`.
10. Update the lines that still describe the CLI turning capture on: `AGENTS.md` (the
    `Packages/KvotarCLI` row of the layout table), `ARCHITECTURE.md` (the unit table and *The CLI*),
    and `docs/credentials-and-privacy.md` if it mentions it. Each changed file's `Checked against` line becomes
    `<parent commit> + STEP_242`.
11. Remove this step's row from `TASKS.md`.

## Proof

12. A `KvotarCLITests` test: parsing `capture --enable` fails; `capture --disable` and
    `capture --status` parse.
13. A live check on a Debug build on your Mac (one copy of the app running): `kvotar capture
    --status` reports off; the app's menu item opens capture; `--status` then reports on;
    `--disable` turns it off and the menu shows the enable item again. Report what you saw; if you
    cannot run the app, say so and hand this check to the maintainer.
14. The Privacy screen rendered with the new line (a screenshot of the live window), in light and
    dark.
15. `make test` and `make check` pass.

## Deliberately untouched

- The app's consent dialog, the 24-hour cap, redaction and retention.
- The rest of the first-run window.
- Debug logging and its CLI commands.

## Definition of done

- Items 12–15 hold.
- Both spec pages and the files in item 10 describe the new behavior.
- One commit lands for STEP_242, and work stops.
