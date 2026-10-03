import XCTest
@testable import KvotarCore

/// First coverage this discovery has ever had. It shipped with a single hardcoded path that went
/// stale three times without a test noticing (Baseline §8.6, §20 P1-30).
final class CodexBinaryCandidatesTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/tester")

    private func resolve(_ present: Set<String>, appBundle: URL? = nil)
        -> CodexBinaryCandidates.Resolution {
        CodexBinaryCandidates.firstExecutable(
            appBundle: appBundle, home: home, isExecutable: { present.contains($0) })
    }

    func testChatGPTBundleBeatsLegacyCodexApp() {
        let result = resolve([
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
        ])
        XCTAssertEqual(result.url?.path, "/Applications/ChatGPT.app/Contents/Resources/codex")
    }

    /// A tester who has not updated Codex Desktop still resolves.
    func testLegacyPathStillResolvesWhenItIsAllThereIs() {
        let result = resolve(["/Applications/Codex.app/Contents/Resources/codex"])
        XCTAssertEqual(result.url?.path, "/Applications/Codex.app/Contents/Resources/codex")
    }

    /// The point of resolving the bundle identifier: the install wins wherever the user keeps it.
    func testResolvedBundleBeatsEveryLiteralCandidate() {
        let bundle = URL(fileURLWithPath: "/Users/tester/Applications/Renamed.app")
        let result = resolve([
            "/Users/tester/Applications/Renamed.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
        ], appBundle: bundle)
        XCTAssertEqual(result.url?.path,
                       "/Users/tester/Applications/Renamed.app/Contents/Resources/codex")
    }

    func testResourcesIsPreferredOverMacOSInsideTheSameBundle() {
        let bundle = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        let result = resolve([
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/MacOS/codex",
        ], appBundle: bundle)
        XCTAssertEqual(result.url?.path, "/Applications/ChatGPT.app/Contents/Resources/codex")
    }

    /// A GUI-launched app has no `~/.local/bin` on PATH, so the standalone install must be a
    /// literal candidate rather than something `which` is trusted to find.
    func testStandaloneInstallPathsExpandUnderTheInjectedHome() {
        XCTAssertEqual(resolve(["/Users/tester/.local/bin/codex"]).url?.path,
                       "/Users/tester/.local/bin/codex")
        XCTAssertEqual(
            resolve(["/Users/tester/.codex/packages/standalone/current/bin/codex"]).url?.path,
            "/Users/tester/.codex/packages/standalone/current/bin/codex")
    }

    func testNothingExecutableReturnsNilAndNamesEverythingItTried() {
        let result = resolve([])
        XCTAssertNil(result.url)
        XCTAssertEqual(result.searched, CodexBinaryCandidates.candidates(
            appBundle: nil, home: home))
        XCTAssertTrue(result.searched.contains("/Applications/ChatGPT.app/Contents/Resources/codex"))
    }

    /// A bundle URL that is also the first literal must not be probed twice, or the honesty log
    /// prints the same path back at the reader.
    func testCandidatesAreDeduplicatedInOrder() {
        let candidates = CodexBinaryCandidates.candidates(
            appBundle: URL(fileURLWithPath: "/Applications/ChatGPT.app"), home: home)
        XCTAssertEqual(candidates.count, Set(candidates).count)
        XCTAssertEqual(candidates.first, "/Applications/ChatGPT.app/Contents/Resources/codex")
    }

    /// Pins the order itself. Bundled installs first: on the dogfood machine the bundle carries
    /// 0.153.4 while PATH carries an older 0.145.0, and the bundled binary is the one the running
    /// desktop app uses against the same `~/.codex` state.
    func testOrderIsPinned() {
        XCTAssertEqual(CodexBinaryCandidates.candidates(appBundle: nil, home: home), [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Users/tester/.local/bin/codex",
            "/Users/tester/.codex/packages/standalone/current/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ])
    }

    /// P1-30 recorded a path under `Contents/Frameworks/Codex Framework.framework/…/Helpers` as
    /// the binary. It is not — that tree holds the Electron helpers under a version-numbered
    /// directory. Hardcoding it would be the same mistake a fourth time.
    func testNoVersionedFrameworkHelperPathIsSearched() {
        let all = CodexBinaryCandidates.candidates(
            appBundle: URL(fileURLWithPath: "/Applications/ChatGPT.app"), home: home)
        XCTAssertFalse(all.contains { $0.contains("Frameworks") })
    }
}
