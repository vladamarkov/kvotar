# STEP_278 — Kvotar installs with `brew install --cask vladamarkov/tap/kvotar`, from the first release tagged in this repository

**refs:**
- [docs/spec/updates-and-releases.md](../docs/spec/updates-and-releases.md) — "Distribution", "The
  updater", "Known gaps".
- [README.md](../README.md) — "Install".
- [docs/credentials-and-privacy.md](../docs/credentials-and-privacy.md) — "What Kvotar keeps".
- [docs/spec/storage.md](../docs/spec/storage.md) — "Where the data lives".
- [VISION.md](../VISION.md) — the approval list.
- [STEP_276_github_checks.md](STEP_276_github_checks.md) — the format.
- Homebrew documentation, checked 2026-10-05:
  [How to Create and Maintain a Tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap),
  [Cask Cookbook](https://docs.brew.sh/Cask-Cookbook),
  [Brew Livecheck](https://docs.brew.sh/Brew-Livecheck),
  [Acceptable Casks](https://docs.brew.sh/Acceptable-Casks), [Manpage](https://docs.brew.sh/Manpage)
  (`brew upgrade`, `--greedy`, `--greedy-auto-updates`).
- Homebrew source, release 6.0.10 (commit `76ca8d74e4`), for what the docs leave out:
  - `Library/Homebrew/cask/cask.rb` — `outdated_version` (l. 406–427) and
    `auto_updates_bundle_outdated?` (l. 722–766);
  - `Library/Homebrew/cask/upgrade.rb` — `outdated_casks` (l. 36–80; a named cask is checked with
    `outdated?(greedy: true)`, l. 65);
  - `Library/Homebrew/env_config.rb` — `HOMEBREW_UPGRADE_AUTO_UPDATES_CASKS`, default on (l. 712–722),
    and `HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS` (l. 613–617);
  - `Library/Homebrew/cask/dsl.rb` `disable!` (l. 777) and `Library/Homebrew/deprecate_disable.rb`.

**Approval:** the maintainer, 2026-10-05, with these rulings: the cask points at the first release
tagged in this repository, never at an earlier build; `auto_updates true` stays, with no promise
that Homebrew leaves Kvotar alone; every install, launch, update, uninstall and zap check runs in a
second standard macOS user account, never in the maintainer's own account; the session may create the tap
repository only when the maintainer authorizes it at that time. Touches *new tools or platforms* on
the [VISION.md](../VISION.md) approval list: Homebrew as a second way to install. Nothing changes in
the app.

**blocked_by:** the first release built from a commit of this repository and tagged here (its own
step). It must be published on the update feed and served by `https://kvotar.com/download`. This
step reads its version, label, build number, tag and SHA-256 from that release; they are written
`<version>`, `<label>`, `<build>`, `<tag>` and `<sha256>` below.

## Goal

Many Mac developers look for a `brew install` line first. Today Kvotar has only the website download.
After this step `brew install --cask vladamarkov/tap/kvotar` installs the same signed, notarized zip
the website serves, checked against its SHA-256 and made from a tagged commit of this repository.
The app keeps updating itself through Sparkle. Homebrew can still replace it in some cases, and the
docs say exactly which ones.

## How Homebrew treats a cask marked `auto_updates true` (Homebrew 6.0.10, source above)

| Command | Replaces Kvotar when |
|---|---|
| `brew upgrade` (no name) | the installed app's own `CFBundleShortVersionString` / `CFBundleVersion` is older than the cask's version. On by default; `HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS` turns it off |
| `brew upgrade --cask kvotar` (named), `--greedy`, `--greedy-auto-updates`, `HOMEBREW_UPGRADE_GREEDY` | the version **Homebrew recorded at install** differs from the cask's version. Homebrew does not read the app, so after a Sparkle update this can install a build **older** than the one the app updated itself to, when the cask is behind |
| `brew outdated` | the same tests as the matching `upgrade` form |

With Kvotar's version form (`<version>-<label>,<build>` in the cask; `<version>` and `<build>` in
the app) the unnamed test compares the build number. A replayed copy of Homebrew's comparison gave:
app build 18 vs cask build 19 → replaced; 19 vs 19 and 20 vs 19 → left alone; app 0.3.0 vs cask
0.4.0 or 1.0.0 → replaced. Proof items 4–6 confirm this on a real install.

## Contract

1. **The tap repository.** If `vladamarkov/homebrew-tap` does not exist, stop and ask the maintainer.
   Create it (`gh repo create vladamarkov/homebrew-tap --public`, default branch `main`, no other
   settings) only when the maintainer authorizes it in this session. It gets exactly three files in
   one commit, `Add the kvotar cask (<version> <label>, build <build>)`:
   - `Casks/kvotar.rb` — the cask below.
   - `README.md` — item 2, word for word.
   - `LICENSE` — Apache-2.0, the same as Kvotar.
   No `.github/workflows/` (`brew tap-new`'s workflows build formula bottles; this tap holds one
   cask) and no `Formula/` folder.

   The cask (only the five placeholders change):

   ```ruby
   cask "kvotar" do
     version "<version>-<label>,<build>"
     sha256 "<sha256>"

     url "https://updates.kvotar.com/builds/Kvotar-#{version.csv.first}-build.#{version.csv.second}-macos-universal.zip",
         verified: "updates.kvotar.com/builds/"
     name "Kvotar"
     desc "Menu bar monitor for Claude Code and Codex quota"
     homepage "https://kvotar.com/"

     # The feed's shortVersionString has no beta label; the label is only in the file name.
     livecheck do
       url "https://updates.kvotar.com/appcast.xml"
       strategy :sparkle do |item|
         match = item.url&.match(/Kvotar-(.+)-build\.(\d+)-macos-universal\.zip/i)
         next if match.blank?

         "#{match[1]},#{match[2]}"
       end
     end

     auto_updates true
     depends_on macos: :sonoma

     app "Kvotar.app"

     uninstall quit: "com.vladimirmarkovic.kvotar"

     zap trash: [
       "~/Library/Application Support/Kvotar",
       "~/Library/Caches/com.vladimirmarkovic.kvotar",
       "~/Library/HTTPStorages/com.vladimirmarkovic.kvotar",
       "~/Library/Logs/Kvotar",
       "~/Library/Preferences/com.vladimirmarkovic.kvotar.plist",
       "~/Library/WebKit/com.vladimirmarkovic.kvotar",
     ]
   end
   ```

   For a release without a label the version is `<version>,<build>`; the URL form above then needs
   the zip to be named without a label too. Stop and ask if it is not.

   Why each part:
   - **`version "<version>-<label>,<build>"`.** The zip name carries both, and the feed's
     `shortVersionString` is the bare version (`0.3.0` for every beta so far), so livecheck reads
     the label from the enclosure file name.
   - **`verified:`** because the download host (`updates.kvotar.com`) is not the homepage host. If
     `brew audit` calls it unnecessary, remove it and record that in the commit body.
   - **`auto_updates true`** because the app's "Check for Updates…" downloads and installs. It tells
     Homebrew the app replaces itself; it does not stop every `brew upgrade` (table above).
   - **`depends_on macos: :sonoma`** = macOS 14 or newer, the app's deployment target (the string form
     `">= :sonoma"` is deprecated).
   - **`uninstall quit:`** quits the running app before Homebrew removes or replaces it. It names
     Kvotar's bundle identifier, so on a Mac where Kvotar is running it quits that copy.
   - **`zap`** lists every place the app writes (storage.md, credentials-and-privacy.md) plus the
     three folders macOS and Sparkle create under the bundle identifier. It never names `~/.claude`,
     `~/.codex` or any Keychain item: those belong to Claude Code and Codex.

2. **Tap `README.md`**, word for word (placeholders filled):

   ```markdown
   # vladamarkov/homebrew-tap

   Homebrew casks maintained by the author of [Kvotar](https://github.com/vladamarkov/kvotar).

   ## Kvotar

       brew install --cask vladamarkov/tap/kvotar

   This installs the same signed, notarized build as [kvotar.com/download](https://kvotar.com/download),
   made from tag `<tag>` of the Kvotar repository.

   Kvotar updates itself: it checks daily and installs an update only when you click **Install**.
   `brew upgrade` replaces it only when your copy is older than this tap's. `brew upgrade --cask
   kvotar` and `--greedy` install this tap's build whenever it differs from the one Homebrew
   installed, even if Kvotar has already updated itself past it.

   To remove the app: `brew uninstall --cask kvotar`. To remove it and its data (database, logs,
   preferences, caches): `brew uninstall --zap --cask kvotar`. Neither touches Claude Code's or
   Codex's own files or sign-ins.

   Report problems at [vladamarkov/kvotar](https://github.com/vladamarkov/kvotar/issues).
   ```

3. **`README.md` (this repository), "Install"**, a new paragraph after the numbered list and before
   "Release builds are signed…":

   *Or with Homebrew: `brew install --cask vladamarkov/tap/kvotar`. Kvotar still updates itself; see
   the [tap's notes](https://github.com/vladamarkov/homebrew-tap#kvotar) for how it and `brew
   upgrade` interact.*

4. **`docs/spec/updates-and-releases.md`.**
   - "Distribution" gains a bullet after "Direct download, not the Mac App Store":
     *- **Homebrew, from the maintainer's tap.** `brew install --cask vladamarkov/tap/kvotar`
     installs the same versioned zip the website serves, checked against its SHA-256
     ([vladamarkov/homebrew-tap](https://github.com/vladamarkov/homebrew-tap), `Casks/kvotar.rb`).
     The cask is marked `auto_updates true`. Homebrew can still replace the app: a plain
     `brew upgrade` does when the installed app's version is older than the cask's; `brew upgrade
     --cask kvotar` or `--greedy` does whenever the cask's version differs from the one Homebrew
     recorded at install, which after a Sparkle update can mean an older build. The cask points only
     at tagged releases. If a release is withdrawn, the cask goes back to the previous build in the
     feed, or is disabled when there is none. The cask is not in Homebrew's main repository.
     Reason: many developers look for a `brew install` line first.*
   - "Known gaps" gains a row:
     | The cask can lag a release | The cask's version and SHA-256 are changed by hand after a release is published. Until then a new Homebrew install gets the previous build, and a named `brew upgrade` can take a self-updated copy back to it | Bump the cask on the day of each release |
   - The page's last line becomes `Checked against the code at <parent> + STEP_278`.
5. **`docs/credentials-and-privacy.md`, "What Kvotar keeps".** The removal paragraph becomes:
   *To remove Kvotar's data: quit Kvotar, delete the app, and delete those two folders. macOS and the
   updater also keep caches under Kvotar's identifier: `~/Library/Caches/com.vladimirmarkovic.kvotar`,
   `~/Library/HTTPStorages/com.vladimirmarkovic.kvotar` and `~/Library/WebKit/com.vladimirmarkovic.kvotar`;
   delete them too. Diagnostics zips you saved stay on your Desktop until you delete them, and the
   update settings live in Kvotar's preferences (`defaults delete com.vladimirmarkovic.kvotar`). If
   you installed Kvotar with Homebrew, `brew uninstall --zap --cask kvotar` removes the app and all
   of these except the zips.*
   The page's last line becomes `Checked against the code at <parent> + STEP_278`.
6. **`TASKS.md`** loses this step's row when the step lands.

## Proof

**Where.** `brew style`, `brew audit` and `brew livecheck` (item 1) only read, so they may run on the
maintainer's Mac. Everything that installs, launches, updates, quits, uninstalls or zaps (items 2–8)
runs in a **disposable test account**: a new standard macOS user (for example `kvotar-brew-test`)
with no Claude Code or Codex sign-in, its own Homebrew cloned into its home folder (never the
maintainer's `/opt/homebrew`), and casks installed into `~/Applications` (`--appdir`). The
maintainer creates the account and deletes it afterwards. Before item 2, note the PID of any Kvotar
running in the maintainer's session; item 8 checks it is unchanged.

The session cannot click in a GUI. The maintainer logs into the test account for each click
(Sparkle's **Install**, opening the app), handed over one at a time, and the session checks the
result from the shell.

1. **Read-only checks, local tap.** Clone the tap, add the three files, `brew tap vladamarkov/tap
   <path-to-the-clone>`. All pass, output in the tap commit body:
   - `brew style vladamarkov/tap`
   - `brew audit --cask --strict --online vladamarkov/tap/kvotar`
   - `brew livecheck --cask vladamarkov/tap/kvotar` shows `<version>-<label>,<build>` as both current
     and latest.
   Problems that `brew audit --cask --new` reports only about notability or repository age are
   recorded, not fixed: they apply to Homebrew's main repository.
2. **Fresh install and launch** (test account, local tap). `brew install --cask --appdir=~/Applications
   vladamarkov/tap/kvotar`. `codesign --verify --deep --strict` passes; `spctl -a -vv` says
   `accepted` and `source=Notarized Developer ID`; `CFBundleVersion` is `<build>`. Open the app: it
   starts without a Gatekeeper workaround, its menu-bar item appears, and its log under
   `~/Library/Logs/Kvotar/` shows the launch line. Quit it.
3. **Upgrade through Homebrew.** Uninstall. Point the local tap at the previous build in the feed
   (version, SHA-256 from its public release notes or a local download; this edit is never pushed),
   install, open it once, then put the tap back at `<build>`. `brew outdated` lists Kvotar; plain
   `brew upgrade` quits the running app, installs `<build>`, and the database written by the first
   launch is still there.
4. **A copy Sparkle already updated, tap lagging.** Uninstall. Install the previous build from the
   edited local tap and leave the tap at that build. Open the app, choose **Check for Updates…**,
   and the maintainer clicks **Install**. Then `CFBundleVersion` is `<build>` while `brew info --cask
   kvotar` still shows the previous build. Record: `brew outdated`, `brew outdated --greedy`, plain
   `brew upgrade` and `brew upgrade --cask kvotar` all leave the app at `<build>` (the recorded and
   cask versions are equal).
5. **The tap catches up.** Put the local tap back at `<build>`. Plain `brew upgrade` leaves the app
   alone (its own version equals the cask's); `brew upgrade --cask kvotar` reinstalls `<build>` and
   `brew info` now shows it. The app opens and its data is still there.
6. **The tap lags behind a self-updated copy.** Repeat item 4 (app updated by Sparkle to `<build>`,
   Homebrew recorded the previous build). Point the local tap at a build **older** than the recorded
   one (any earlier zip still served under `https://updates.kvotar.com/builds/`). Record: plain `brew
   upgrade` leaves the app at `<build>`; `brew upgrade --cask kvotar` installs the older build. If
   either result differs from the table above, stop and report: the docs in items 2–4 must say what
   Homebrew does.
7. **Withdrawal with no earlier build.** Add `disable! date: "<today>", because: "has no published
   build right now; a fixed build is coming"` to the local cask. `brew install --cask kvotar`
   refuses and prints the reason; `brew upgrade` skips Kvotar with the reason; `brew uninstall
   --cask kvotar` still works. Remove the line.
8. **Uninstall and zap.** With the app running, `brew uninstall --cask kvotar` quits it and removes
   it. Reinstall, open once, create `~/.claude/` and `~/.codex/` with a placeholder file each, then
   `brew uninstall --zap --cask kvotar`: the six zap paths are gone (listing before and after), the
   two placeholder folders are still there. The PID of the maintainer's Kvotar, noted before item 2,
   is unchanged.
9. **From GitHub.** Push the tap commit to `main`, `brew untap vladamarkov/tap` in the test account,
   and repeat item 2's install from GitHub (`brew install --cask --appdir=~/Applications
   vladamarkov/tap/kvotar` taps automatically). Uninstall and untap.
10. **This repository.** `make check` passes; the changed docs' links resolve.

Outputs of items 2–9 go in the commit body of this repository's step commit, shortened to the lines
that show each result.

## Deliberately untouched

The app, its updater keys and the feed; signing, notarizing, publishing and tagging releases;
Homebrew's main repository (it needs notability); a GitHub workflow in the tap; automatic cask bumps
(the release routine bumps the cask, outside this repository); repository settings beyond creating
the tap.

## Definition of done

- The proof items hold, and the docs describe what items 4–6 showed.
- The tap has one commit with the three files, and `brew install --cask vladamarkov/tap/kvotar`
  works from GitHub.
- One commit lands in this repository (`STEP_278: …`), through a pull request with a green `checks`
  run, and work stops. The maintainer adds the cask bump and withdrawal lines to the release routine
  before the step is called complete.
