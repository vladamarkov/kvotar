# Kvotar

A macOS menu-bar app that shows how much of your **Claude Code** and **Codex** quota is left, how fast
you are using it, and whether it will last until the next reset.

<img src="docs/images/kvotar-popover.png" width="360" alt="The Kvotar popover on the Claude tab: 47% of the 5-hour quota left, other limits, today's local activity and its estimated value">

## What it does

- Shows the quota left on each account, per limit (five-hour, weekly, monthly, per-model), with reset
  times, in the menu bar and in a popover.
- Says whether you will make it to the reset at your current pace, and notifies you before a limit
  runs out.
- Attributes local usage to projects and models from the session logs Claude Code and Codex already
  write on your Mac, with an estimated token value at published API prices (not a bill).
- Keeps a 30-day History window of your own usage and of the quota readings it recorded.

## What it does not do

- Only **Claude Code** and **Codex**. No other tools.
- Only **macOS 14 (Sonoma) or newer**, Apple Silicon and Intel.
- No analytics, no telemetry, no crash reporting.
- It never stores your prompts, code, transcripts or tool output, never writes to your Claude or
  Codex sign-in, and never refreshes a token.

## What "local" means

Your data is processed on your Mac. There is no Kvotar account, and no Kvotar server receives your
usage. The app keeps its own data in `~/Library/Application Support/Kvotar` and its logs in
`~/Library/Logs/Kvotar`.

The app does use the network, for three things only:

1. **Your providers' own endpoints**, with the credentials Claude Code and Codex already have on your
   Mac: `api.anthropic.com` for Claude, and for Codex the local `codex app-server` process with
   `chatgpt.com` as the fallback.
2. **Update checks** (Sparkle): once a day it asks `updates.kvotar.com` whether there is a newer
   version. Nothing installs until you click **Install**, and you can turn the daily check off.
3. **Links you click**, such as opening Claude or ChatGPT in your browser.

The details, including why the credential rules exist, are in
[docs/credentials-and-privacy.md](docs/credentials-and-privacy.md).

## Install

Download the current beta from [kvotar.com/download](https://kvotar.com/download), unzip, and drag `Kvotar.app` into
**Applications**. Release builds are signed and notarized, and update themselves.

## Build from source

Requirements:

- Xcode 26 (the packages need Swift 6.2), which itself needs macOS 15.6 or newer
- The app you build runs on macOS 14 or newer
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

```sh
make build   # generates the Xcode project and builds an unsigned app; prints its path
make test    # runs every package's tests and the app tests
make check   # static rule checks (see docs/safety-checks.md)
```

None of these needs a Claude or Codex account: the tests run on synthetic fixtures. An unsigned build
runs on your own Mac.

## Privacy, in short

- The Claude token is read from the Keychain through Apple's `/usr/bin/security` tool, so no password
  dialog appears. The Codex token is read from `~/.codex/auth.json`. Both are read only.
- Session logs are read for token counts, model names, timestamps and project folders. Their text
  is never stored.
- **Save Diagnostics…** writes a zip to your Desktop. Nothing is sent; you decide whether to share
  it. Even an ordinary bundle includes the app's logs, which contain local folder paths. A fuller
  bundle needs a 24-hour consent you turn on yourself.

Full detail: [docs/credentials-and-privacy.md](docs/credentials-and-privacy.md).

## Not affiliated

Kvotar is an independent project. It is not affiliated with, endorsed by or sponsored by Anthropic or
OpenAI. "Claude" and "Claude Code" are trademarks of Anthropic; "Codex" and "ChatGPT" are trademarks of
OpenAI.

## How development works

Kvotar is developed here, in this repository. Pull requests are welcome; an accepted pull request is
merged directly, ships in the next release, and is credited by name in [CHANGELOG.md](CHANGELOG.md).
Details in [CONTRIBUTING.md](CONTRIBUTING.md).

## Support

- Bugs and ideas: GitHub Issues.
- Anything private, including diagnostics bundles: `hello@kvotar.com`. Never attach a diagnostics
  bundle or log to a public issue.
- Security problems: see [SECURITY.md](SECURITY.md).

## License

The code and artwork are licensed under the [Apache License 2.0](LICENSE). The name "Kvotar" is
reserved for official releases: a distributed fork needs its own name, icon and menu-bar mark. See
[TRADEMARK.md](TRADEMARK.md). Third-party components and their licenses are
listed in `Resources/THIRD_PARTY_NOTICES`.

Checked against the code at 62d7d98 + STEP_241.
