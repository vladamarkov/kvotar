import Foundation

/// Where the `codex` binary lives, and in what order to look for it (Baseline §8.6).
///
/// One list, two consumers: `DefaultCodexBinaryLocator`, which spawns the `app-server` child, and
/// `DiagnosticsBundle`, which reports the installed version in `environment.txt`. The path used to
/// be a literal in each of them — CodexAdapter and the diagnostics builder live in packages that
/// cannot see one another — and that is exactly how both copies came to name an app that no longer
/// exists. KvotarCore is the one module both can reach, so the list lives here.
///
/// **The path is not stable and must never be recorded as "confirmed" again.** It has moved three
/// times in three months: `/Applications/Codex.app/Contents/Resources/codex` (the original §8.6
/// path) → inside `/Applications/ChatGPT.app` (noted in §20 P1-30, 2026-08-18) →
/// `/Applications/ChatGPT.app/Contents/Resources/codex` (`codex-cli 0.153.4`, observed 2026-09-09).
/// The durable handle is the **bundle identifier**, which ChatGPT.app carries on its top-level
/// `Info.plist`. Resolving an identifier to a bundle needs LaunchServices, which neither this
/// package nor CodexAdapter may import, so the App target resolves it and injects the URL — and
/// everything in this type stays a pure function over an injected filesystem probe.
public enum CodexBinaryCandidates {

    /// Codex Desktop's bundle identifier. Carried today by `/Applications/ChatGPT.app` itself,
    /// not by a nested helper — the app was renamed, not re-nested.
    public static let bundleIdentifier = "com.openai.codex"

    /// Probed inside whichever app bundle `bundleIdentifier` resolves to, in order.
    ///
    /// Deliberately **not** including anything under `Contents/Frameworks/Codex Framework.framework`.
    /// P1-30 recorded a path there as the binary; it is not. That directory holds the Electron
    /// helpers (`Codex (Renderer).app`, `Codex (GPU).app`, …) under a version-numbered
    /// `Versions/<n>/` directory, so hardcoding it would be the same mistake a fourth time.
    public static let bundleRelativePaths = [
        "Contents/Resources/codex",
        "Contents/MacOS/codex",
    ]

    /// Literal fallbacks, in order — bundled installs first, then the paths the standalone
    /// installer uses.
    ///
    /// The standalone entries are not redundant with the `which codex` fallback. A GUI-launched app
    /// inherits the `/etc/paths` default, which contains no `~/.local/bin`, so on a normal install
    /// `which` finds nothing that a user's interactive shell finds easily.
    static func literalCandidates(home: URL) -> [String] {
        [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            // Legacy. Kept because a tester who has not updated Codex Desktop still has it.
            "/Applications/Codex.app/Contents/Resources/codex",
            home.appendingPathComponent(".local/bin/codex").path,
            home.appendingPathComponent(".codex/packages/standalone/current/bin/codex").path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
    }

    /// The full ordered search list. A resolved app bundle wins over every literal path: it is the
    /// install the user is actually running, wherever they keep it.
    ///
    /// Duplicates are dropped while order is preserved — an injected bundle URL is very often
    /// `/Applications/ChatGPT.app`, which is also the first literal.
    public static func candidates(appBundle: URL?, home: URL) -> [String] {
        var ordered: [String] = []
        if let appBundle {
            ordered += bundleRelativePaths.map {
                appBundle.appendingPathComponent($0).standardizedFileURL.path
            }
        }
        ordered += literalCandidates(home: home).map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }

        var seen = Set<String>()
        return ordered.filter { seen.insert($0).inserted }
    }

    /// What a lookup found, and everything it looked at.
    ///
    /// `searched` exists so a failure can say what it tried rather than only that it failed — the
    /// STEP_117 honesty rule, which was written for this same function after an exhausted process
    /// table made a present binary report as absent.
    public struct Resolution: Sendable, Equatable {
        public let url: URL?
        public let searched: [String]

        public init(url: URL?, searched: [String]) {
            self.url = url
            self.searched = searched
        }
    }

    /// The first candidate the probe says is executable. Pure: no filesystem, no subprocess, no
    /// LaunchServices — `isExecutable` is the only way it can touch the world.
    public static func firstExecutable(
        appBundle: URL?,
        home: URL,
        isExecutable: (String) -> Bool
    ) -> Resolution {
        let searched = candidates(appBundle: appBundle, home: home)
        let hit = searched.first(where: isExecutable)
        return Resolution(url: hit.map { URL(fileURLWithPath: $0) }, searched: searched)
    }
}
