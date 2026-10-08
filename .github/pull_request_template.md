## Summary
What changes and why, in a few lines. A short diff sketch or tree is fine when it says it better
than prose.

## Checks
`make test` and `make check` results. A docs-only change runs `make check` alone.
Proven: ...
Not proven: ...
(Synthetic data only; see .github/pr-proof/README.md.)

## Risk
Does a revert restore the old behaviour cleanly, and what would a user notice? One or two lines;
"none" is fine.

Closes #   <!-- only when the change needed an agreed issue -->

<!-- Users can see this change? Add one line to CHANGELOG.md under "Unreleased". -->
