---
summary: How Kvotar is distributed and kept up to date — the Sparkle updater and its policy (a daily check, ask before install, nothing installs by itself), the two update controls in the menu, the Info.plist and project.yml keys, the update log lines, the build channel, how version and build numbers move, and how a merged commit reaches a release.
read_when: Changing App/UpdaterService.swift, the SU* keys or KvotarChannel in App/Info.plist, the Sparkle package pin, PRODUCT_BUNDLE_IDENTIFIER, MARKETING_VERSION, CURRENT_PROJECT_VERSION, KVOTAR_PRERELEASE_LABEL or KVOTAR_CHANNEL in project.yml, BuildChannel or ProductIdentity.buildChannelInfoKey, ForecastLogRecorder.appVersionString, KvotarVersion in the CLI, App/Kvotar.entitlements, the Makefile's build target, or where the updater starts in AppDelegate; changing how often Kvotar checks for updates; cutting a release.
---

# Updates and releases

## Questions for owner

None.

## About this page

This page is the specification for how Kvotar reaches people and stays up to date. It replaces the
private Implementation Baseline §5.3 (distribution and entitlements), except its Keychain-sharing
row, which [credentials](credentials.md) replaced, its path rows, which
[storage](storage.md#where-the-data-lives) covers, and its JSONL watch-roots row, which belongs to
[local usage](local-usage.md); the Sparkle part of §17's
network-inventory amendment (the request itself is described in
[credentials and privacy](../credentials-and-privacy.md#the-network)); and the versioning section
of the private release checklist. Change this page in the same commit as the code it describes.

IDs such as REV-nn, D-nnn or STEP_nnn in code comments are private record IDs;
[REFERENCES.md](../REFERENCES.md) explains them. The rules here stand without them.

What this page does **not** own:

| Topic | Page |
|---|---|
| What an update check sends, and to which host | [Credentials and privacy — the network](../credentials-and-privacy.md#the-network) |
| The two update items' place and copy in the right-click menu | [menu actions](menu-actions.md) |
| The first-run window's sentence about the daily check | [First-run window](first-run-window.md) |
| The debug-logging default each build channel seeds | [Diagnostics — debug logging](diagnostics.md#debug-logging) |
| Why the app is not sandboxed matters for the data folder and the CLI | [Storage — where the data lives](storage.md#where-the-data-lives) |
| The single-instance lock the updater waits for | [Storage — the single-instance lock](storage.md#the-single-instance-lock); [app lifecycle](app-lifecycle.md) |
| The `kvotar` CLI's commands | [CLI](cli.md) |
| What a contributor's pull request contains | [CONTRIBUTING.md](../../CONTRIBUTING.md) |

## Distribution

- **Direct download, not the Mac App Store.** People download a zip from the website and drag
  `Kvotar.app` into Applications ([README — Install](../../README.md#install)). Release builds are
  signed and notarized; later versions arrive through the updater below.
- **Homebrew, from the maintainer's tap.** `brew install --cask vladamarkov/tap/kvotar` installs
  the same versioned zip the website serves, checked against its SHA-256
  ([vladamarkov/homebrew-tap](https://github.com/vladamarkov/homebrew-tap), `Casks/kvotar.rb`).
  The cask is marked `auto_updates true`. Homebrew can still replace the app: a plain
  `brew upgrade` does when the installed app's version is older than the cask's; `brew upgrade
  --cask kvotar` or `--greedy` does whenever the cask's version differs from the one Homebrew
  recorded at install, which after a Sparkle update can mean an older build. When Homebrew replaces
  the app it quits it first and reopens it afterwards. The cask points only at tagged releases. If a release is withdrawn, the cask goes back to the previous build in the
  feed, or is disabled when there is none. The cask is not in Homebrew's main repository.
  Reason: many developers look for a `brew install` line first.
- **Not sandboxed.** The app declares one entitlement, `com.apple.security.network.client`, and no
  sandbox. Reason: it reads Claude Code's and Codex's files in your home folder directly, and the CLI
  shares its data folder without an app group (see [storage](storage.md#where-the-data-lives)).
  (`App/Kvotar.entitlements`)
- **Hardened runtime on** (`ENABLE_HARDENED_RUNTIME: YES` in `project.yml`).
- **Bundle identifier `com.vladimirmarkovic.kvotar`** (`PRODUCT_BUNDLE_IDENTIFIER` in
  `project.yml`, read into `Info.plist`). The app's preferences, including the automatic-check
  setting, are stored under it, so changing it makes installed copies look like a different app.
- **One universal app** for Apple Silicon and Intel (`ARCHS: "arm64 x86_64"`), macOS 14 or newer
  (`deploymentTarget`).
- **What ships inside the bundle** besides the code: the price table (`Resources/pricing.json`) and
  the third-party licence notices (`Resources/THIRD_PARTY_NOTICES`), which must accompany the
  binary.
- **A build from source is unsigned.** `make build` runs an unsigned, universal Release build and
  prints its path; nothing in this repository signs or notarizes (`Makefile`). Such a build runs on
  your own Mac.

## The updater

Kvotar updates itself with [Sparkle](https://github.com/sparkle-project/Sparkle), pinned to an exact
version in `project.yml`. `App/UpdaterService.swift` is the only file that imports it.

- **It starts after the single-instance lock.** `AppDelegate` creates and starts `UpdaterService`
  only once this copy holds the lock (or runs unguarded because the lock path is unavailable), so a
  rejected second copy never checks.
  (`AppDelegate.applicationDidFinishLaunching`; `UpdaterService.start`)
- **A scheduled check every 24 hours** (`SUScheduledCheckInterval` = 86400). Sparkle's own scheduler
  decides the moment: at start it checks at once if 24 hours have passed since the last completed
  check (always true on the first launch), and otherwise when they do. Every completed check,
  scheduled or manual, starts the next 24 hours. Reason: one request a day is enough for a beta and
  is what the privacy page promises.
- **No permission prompt.** `SUEnableAutomaticChecks` is set, which skips Sparkle's "may we
  check?" question (Sparkle would otherwise ask on the second launch). Reason: a menu-bar app
  should not interrupt with a dialog. The opt-out is
  therefore always in the menu (below), and the first-run window tells the person about the daily
  check.
- **Nothing installs by itself.** `SUAllowsAutomaticUpdates` and `SUAutomaticallyUpdate` are both
  set to `false`, explicitly: leaving the first out does not mean false in Sparkle. A found update
  is shown, and it installs only when the person clicks **Install** in Sparkle's window. Reason:
  people see the release notes, and a bad build cannot reach everyone at once.
- **Sparkle's standard update window** shows a found update. Kvotar has no update UI of its own.
- **The app comes forward first.** Kvotar is a menu-bar app (`LSUIElement`), so Sparkle's window
  could open behind the app the person is using. A manual check activates the app before it starts,
  and Kvotar activates it again just before Sparkle shows a found update.
  (`UpdaterService.checkForUpdates`, `standardUserDriverWillHandleShowingUpdate`)
- **Builds from source and forks.** Every build made from this repository (`make build`, an Xcode
  run, a fork that leaves the keys alone) keeps `SUFeedURL` and `SUPublicEDKey`, so it checks the
  official feed and is shown the next official build once its build number is higher. Replacement
  on **Install** is possible only for a build with the same name: Sparkle's installer looks for the
  app inside the download by the installed app's file name, then by its bundle identifier. Whether
  a same-named local build is replaced is untested. A fork that changes its name and bundle
  identifier, as [TRADEMARK.md](../../TRADEMARK.md) requires, is not shown by the code to be
  replaced, but it still checks the official feed. **A distributed fork changes `SUFeedURL` and
  `SUPublicEDKey`, or removes the updater** (maintainer's ruling, 2026-10-04). Local builds stay as
  they are. Reason: a fork's users should get the fork's updates, not be pointed at Kvotar's feed.
- **The menu-bar item never changes for an update.** The window is the only notice.
- **Sparkle's window shows Kvotar's icon.** At launch `AppDelegate` registers the bundled icon under
  the application-icon name, because a locally rebuilt menu-bar app may not be known to macOS and
  Sparkle would draw the generic icon.
- **One feed for every build.** The feed URL is fixed in `Info.plist`; the build channel does not
  select a different feed.
- **Every download is checked against the public key in the app.** `SUPublicEDKey` is the public
  half of the EdDSA key that signs each update. Sparkle checks every download against the key in
  the installed app.

## The two controls

The person controls updates from two items in the right-click menu (also reached from the `⋯`
button in the app window). Their place and copy are [menu actions](menu-actions.md)'s; their behaviour is here.

- **Check for Updates…** starts a manual check now (`UpdaterService.checkForUpdates`). While a
  check is already running, Sparkle reports that no new check may start
  (`canCheckForUpdates`), and the item is built without an action, so it shows greyed. The menu is
  rebuilt each time it opens, so the item reflects the moment it opens.
  (`MenuBarController.contextMenu`)
- **Check for updates automatically** is a checkmark bound to Sparkle's
  `automaticallyChecksForUpdates`. Sparkle owns and stores the value in the app's user defaults, not
  in Kvotar's `settings` table, and the menu reads it live on every open. Turning it off stops the
  scheduled check; **Check for Updates…** still works. The default is on, from
  `SUEnableAutomaticChecks`. Removing the app's preferences resets it
  ([credentials and privacy — what Kvotar keeps](../credentials-and-privacy.md#what-kvotar-keeps)).
  (`UpdaterService.automaticallyChecksForUpdates`; the wiring in `AppDelegate`)

## Configuration keys

In `App/Info.plist`:

| Key | Value | What it does |
|---|---|---|
| `SUFeedURL` | the update feed | Where Sparkle asks for new versions. Shipped in every installed copy, so it must never change: a copy only ever asks the URL it was built with |
| `SUPublicEDKey` | a public key | Checks each download's signature (above). A public value |
| `SUEnableAutomaticChecks` | `true` | Scheduled checks on by default, with no first-launch prompt |
| `SUScheduledCheckInterval` | `86400` | 24 hours between scheduled checks |
| `SUAllowsAutomaticUpdates` | `false` | Sparkle never offers to install updates automatically |
| `SUAutomaticallyUpdate` | `false` | Nothing downloads and installs without the person's click |
| `SUEnableSystemProfiling` | absent, on purpose | No system profile is sent with a check |
| `CFBundleShortVersionString` | `$(MARKETING_VERSION)` | The version people see |
| `CFBundleVersion` | `$(CURRENT_PROJECT_VERSION)` | The build number; what Sparkle compares |
| `KvotarChannel` | `$(KVOTAR_CHANNEL)` | The build channel (below) |
| `LSUIElement` | `true` | Menu-bar app with no Dock icon |

In `project.yml` (target `Kvotar`, `settings.base`):

| Setting | Today | What it is |
|---|---|---|
| `MARKETING_VERSION` | `0.3.0` | The version |
| `CURRENT_PROJECT_VERSION` | `19` | The build number |
| `KVOTAR_PRERELEASE_LABEL` | `beta.10` | The beta label, for release file names only; it never reaches `Info.plist` |
| `KVOTAR_CHANNEL` | `release` | The build channel |
| `ENABLE_HARDENED_RUNTIME`, `CODE_SIGN_ENTITLEMENTS`, `ARCHS` | | See [Distribution](#distribution) |

The Sparkle package is pinned with `exactVersion` in `project.yml`'s `packages`. Reason: the
generated Xcode project is not committed, so its `Package.resolved` is not either, and nothing else
pins the version. A Sparkle upgrade changes this pin and the version named in
`Resources/THIRD_PARTY_NOTICES` together. Only the `Kvotar` target links Sparkle; the `KvotarTests`
target compiles app sources without it.

`make check` allows the feed's host only in `App/Info.plist` (R3 in
[safety checks](../safety-checks.md#static-checks-make-check)).

**Changing how often Kvotar checks** means changing `SUScheduledCheckInterval`, and with it every
place that promises "once a day": [README.md](../../README.md),
[credentials and privacy](../credentials-and-privacy.md#the-network), the Updates section of
[ARCHITECTURE.md](../../ARCHITECTURE.md#updates), and the first-run window's sentence
([first-run window](first-run-window.md)). Sparkle never schedules checks more than once an hour,
whatever the key says, and an `SUScheduledCheckInterval` value in the app's user defaults would
override the `Info.plist` one; Kvotar writes none. Network use is on the approval list in
[VISION.md](../../VISION.md#the-approval-list); agree it first.

## Update log lines

All are written by `UpdaterService` under the `AppLifecycle` component at info level, so they are in
the log whether or not debug logging is on. Their metadata is version strings, the feed URL, the
setting's value and error codes, nothing else.

| Line | When | Metadata |
|---|---|---|
| `Updater started` | Once per launch | `feed`, `automatic_checks`, `interval_s` |
| `Automatic update checks changed` | The checkmark is toggled | `enabled` |
| `Update available` | A check finds a newer build | `version`, `build` |
| `No update found` | A check finds nothing newer | `error_domain`, `error_code` |
| `Update check aborted` | A check fails | `error_domain`, `error_code` |
| `Installing update` | The person accepted and the install begins | `version`, `build` |
| `Update check finished` | Every check, at the end | `check` (`manual`, `scheduled`, `information`, or `unknown` for a future Sparkle check type), plus the error fields if it failed |

## The build channel

- **What it is.** A label baked into the app at build time: `release` or `beta`.
  `project.yml` sets the `KVOTAR_CHANNEL` build setting, `Info.plist` copies it into the
  `KvotarChannel` key (`ProductIdentity.buildChannelInfoKey`), and `BuildChannel.current` reads it.
  A missing or unknown value reads as `release`. (`DiagnosticsCapture.swift`: `BuildChannel`;
  `DiagnosticsCaptureFlagTests.testChannelDefaultsToReleaseWhenUnset`)
- **Today every build from this repository is `release`**, because `project.yml` says so. A `beta`
  build needs the setting overridden at build time.
- **What it may change** is [diagnostics](diagnostics.md#debug-logging)'s rule (the debug default
  and labels only). This page adds one thing: it never selects a different update feed.
- **The labels it changes:** the internal version string gets ` beta` appended (below), and the
  diagnostics bundle carries the channel in its name and manifest
  ([diagnostics](diagnostics.md#save-diagnostics)).
- **It is not the beta label.** The `beta.10` in a release's name is `KVOTAR_PRERELEASE_LABEL`,
  which only names release files. A build with that label is still a `release`-channel build unless
  `KVOTAR_CHANNEL` says otherwise.

## Version and build numbers

- **The build number** (`CURRENT_PROJECT_VERSION`, shown in brackets in
  [CHANGELOG.md](../../CHANGELOG.md)) is the number Sparkle compares to decide that an update is
  newer. It only goes up and is never reused, including for a build that was never released. Reason:
  a reused or lower number is invisible to every installed copy. A withdrawn build is fixed by a new
  build with a higher number, never by going back.
- **The version** (`MARKETING_VERSION`) changes with who the build is for, not with features. Every
  public beta build so far is `0.3.0`, from `0.3.0 beta.2 (11)` to `0.3.0 beta.10 (19)`.
- **The beta label** (`KVOTAR_PRERELEASE_LABEL`, `beta.N`) goes up by one with each beta cut. A cut
  that was not released still used its number: beta.1 was build 10.
- **A release bump** in `project.yml` changes the build number and the label, and the version only
  when the audience changes. These three values are the one place release tooling reads them from;
  the CLI carries its own copy of the version, bumped by hand ([CLI](cli.md)).
- **How the app writes its version.** People see `CFBundleShortVersionString` and `CFBundleVersion`
  in the About panel. Logs, `forecast_log` rows, lifecycle events and diagnostics use
  `ForecastLogRecorder.appVersionString`: `0.3.0 (18)` on a `release` build, `0.3.0 (18) beta` on a
  `beta` one. The channel is appended, not substituted, so every stored version keeps its shape.
  (`ForecastLogRecorderTests.testAppVersionFormatting`,
  `DiagnosticsCaptureFlagTests.testVersionStringCarriesChannelOnlyForBeta`)

## From a merged commit to a release

[CONTRIBUTING.md — How a merged change reaches a release](../../CONTRIBUTING.md#how-a-merged-change-reaches-a-release)
is the rule: a merged pull request ships in the next release, which is built from this repository,
and its author is credited in [CHANGELOG.md](../../CHANGELOG.md).

What a reader can check in this repository today:

- **What changed in each release:** [CHANGELOG.md](../../CHANGELOG.md), one heading per published
  build or group of builds with its version, build number and date, and an *Unreleased* section for merged changes not
  yet in a build.
- **What the next build will be called:** the three numbers in `project.yml`.
- **Which commit a published build came from:** from `0.3.0 beta.10 (19)` on, the tag
  `v<version>-<label>` (for example `v0.3.0-beta.10`) marks the commit the build was made from, and
  the GitHub Release of that tag gives the zip's SHA-256. Earlier builds were made before the code
  was public and have no tag here.

Signing, notarizing and publishing happen outside this repository.

## Rejected alternatives

- **Installing updates automatically.** People would never see the release notes, and a bad build
  would reach every copy at once.
- **An update reminder only as a menu row, or a changed menu-bar icon.** A row in the right-click
  menu is easy never to see; the menu-bar item stays about quota. Sparkle's window is the notice.
- **Sparkle's own "may we check for updates?" prompt.** A dialog on an early launch of a menu-bar
  app; the menu checkmark is the opt-out instead.
- **Storing the automatic-check choice in Kvotar's `settings` table.** Sparkle already owns and
  stores it; a second copy could drift from the one Sparkle obeys.

## Known gaps

| Gap | Today | Proposed |
|---|---|---|
| Nothing tests the update policy | No test or check reads the `SU*` keys; `UpdaterService` is outside the test target. Flipping `SUAllowsAutomaticUpdates` or `SUAutomaticallyUpdate` fails nothing | A test or a `make check` rule that reads `App/Info.plist` and asserts the policy keys above |
| The feed itself is not signed | Each download is signed and checked; the feed is fetched over HTTPS but carries no signature (`SURequireSignedFeed` absent) | Decide whether to require a signed feed; it needs every published feed signed first |
| Release tags are not signed | A release tag is annotated but carries no signature; the maintainer has no signing key set up for git. The protected `main` and the published SHA-256 are the guarantee today | Decide whether to sign tags once a signing key is set up |
| Comments describe the schedule loosely | `UpdaterService`'s doc comment says "a scheduled check on launch and every 24 h"; Sparkle checks at launch only when 24 hours have passed | Reword with the next change to the file |
| The cask can lag a release | The cask's version and SHA-256 are changed by hand after a release is published. Until then a new Homebrew install gets the previous build, and a named `brew upgrade` can take a self-updated copy back to it | Bump the cask on the day of each release |

## Code and test pointers

`App/UpdaterService.swift` (the Sparkle wrapper, its log lines, activation); `App/AppDelegate.swift`
(`applicationDidFinishLaunching`: the updater after the lock, icon registration, the four menu
closures); `App/MenuBarController.swift` (`contextMenu`, `checkForUpdates`,
`toggleAutomaticUpdateChecks`); `App/Info.plist`; `App/Kvotar.entitlements`; `project.yml`;
`Makefile` (`build`); `Packages/KvotarCore/Sources/KvotarCore/DiagnosticsCapture.swift`
(`BuildChannel`); `Packages/KvotarCore/Sources/KvotarCore/ProductIdentity.swift`
(`buildChannelInfoKey`, `buildChannelSetting`); `Packages/KvotarCore/Sources/KvotarCore/Forecast/ForecastLogRecorder.swift`
(`currentAppVersion`, `appVersionString`); `Packages/KvotarCLI/Sources/KvotarCLI/KvotarVersion.swift`;
`scripts/check_rules.sh` (R3 host list).

Tests in `Packages/KvotarCore/Tests/KvotarCoreTests/`: `DiagnosticsCaptureFlagTests`
(`testChannelDefaultsToReleaseWhenUnset`, `testVersionStringCarriesChannelOnlyForBeta`),
`ProductIdentityTests` (the channel key and setting names), `ForecastLogRecorderTests`
(`testAppVersionFormatting`). Nothing tests `UpdaterService` or the `SU*` keys (Known gaps).
