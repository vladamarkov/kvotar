# Security

## Reporting a problem

Please report security problems **privately**:

- through GitHub's private vulnerability reporting (the **Report a vulnerability** button on this
  repository's Security tab), or
- by email to `hello@kvotar.com`.

Do not open a public issue for a security problem.

## Diagnostics bundles and logs are sensitive

A Kvotar diagnostics bundle or log file can contain your account details, your home folder path and
your usage history. **Never attach one to a public issue or pull request.** If one is needed, send it
to `hello@kvotar.com`.

## In scope

- Anything that could make Kvotar write, change, refresh or leak a Claude or Codex credential.
- A password or authorization dialog caused by Kvotar.
- Kvotar storing or logging prompt, code, transcript or tool-output content.
- Diagnostics redaction failures, or capture happening without consent.
- Network requests to hosts other than those listed in
  [docs/credentials-and-privacy.md](docs/credentials-and-privacy.md).
- The update path (Sparkle feed, signature checks).
- Writes outside Kvotar's own folders.

## Out of scope

- Problems in Claude Code, Codex, or the providers' services. Report those to Anthropic or OpenAI.
- Attacks that already require control of your user account or your Mac.
- Builds you made yourself from modified source.

## What to expect

You will get an acknowledgment within 7 days, and a first assessment within 14 days. Fixes for
confirmed problems ship in the next release, sooner for anything that affects credentials. You will
be credited unless you ask not to be.
