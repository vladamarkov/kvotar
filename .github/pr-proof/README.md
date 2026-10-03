# Proof for pull requests

Every pull request shows that the change does what it says. Keep the proof small and honest.

## Use synthetic data only

- Tests and fixtures: use or extend the fixtures under each package's `Tests` folder.
- Screenshots: of fixture data only (SwiftUI previews or snapshot tests), never of your own account.
- Never include a real token, a real session log, a real Kvotar database, a diagnostics bundle, a log
  file, an email address or a home folder path.

## Say what was and was not proven

Write two short lists in the pull request:

- **Proven:** for example "the new test fails before the change and passes after it" or "the popover
  renders the new row for the weekly fixture".
- **Not proven:** for example "not tried against a live Codex Enterprise account" or "only checked
  in light mode".

A pull request that says what it did not prove is easier to accept than one that claims everything.

## Small files only

If the proof needs an image, keep it small and attach it to the pull request description. Do not
commit proof images to the repository.
