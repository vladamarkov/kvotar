import XCTest
@testable import KvotarCLI

/// Absolute rule R2 (STEP_239) for the CLI's two writers: importing a zipped bundle — `BundleReader`
/// expanding it, `AnalysisStore` creating the corpus at its default path — leaves a fake home's
/// `~/.claude` and `~/.codex` exactly as they were. The core package's writers have the same test
/// (`KvotarCoreTests.CredentialTreesUntouchedTests`); the fixture is repeated here because test
/// targets cannot share code.
final class CredentialTreesUntouchedTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvotar-cli-fakehome-\(UUID().uuidString)", isDirectory: true)
        for (path, contents) in Self.trees {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
    }

    override func tearDownWithError() throws {
        if home != nil { try? FileManager.default.removeItem(at: home) }
    }

    func testImportingABundleLeavesTheCredentialTreesAlone() throws {
        let before = try snapshot()
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let directory = try BundleFixture.make(
            in: downloads, named: "tester-bundle",
            sql: ["CREATE TABLE poll_snapshots (id INTEGER, tool TEXT)",
                  "INSERT INTO poll_snapshots VALUES (1, 'claude')"])
        let zip = try BundleFixture.archive(directory)

        let corpus = Import.defaultAnalysisPath(fileManager: FakeHome(home))
        XCTAssertTrue(corpus.hasPrefix(home.path + "/"), "destination escapes the fake home: \(corpus)")
        var reader = BundleReader()
        let bundle = try reader.read(path: zip.path)
        let store = try AnalysisStore(path: corpus)
        _ = try store.importBundle(bundle, tester: "tester")

        let after = try snapshot()
        let added = Set(after.keys).subtracting(before.keys).sorted()
        XCTAssertEqual(added, [], "R2: written under the credential trees: \(added)")
        for (path, contents) in before where after[path] != contents {
            XCTFail("R2: \(path) changed")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: corpus), "the import really ran")
    }

    private static let trees = [
        ".claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r"}}"#,
        ".claude/projects/-tmp-project/session.jsonl": #"{"type":"user"}"#,
        ".codex/auth.json": #"{"tokens":{"access_token":"a","refresh_token":"r"}}"#,
        ".codex/sessions/2026/01/01/rollout.jsonl": #"{"type":"session_meta"}"#,
    ]

    /// Contents plus modification time of everything under the two trees, directories included.
    private func snapshot() throws -> [String: String] {
        var result: [String: String] = [:]
        let fm = FileManager.default
        for root in [".claude", ".codex"] {
            let base = home.appendingPathComponent(root)
            let enumerator = fm.enumerator(atPath: base.path)
            while let relative = enumerator?.nextObject() as? String {
                let url = base.appendingPathComponent(relative)
                var isDirectory: ObjCBool = false
                fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
                guard !isDirectory.boolValue else { result[root + "/" + relative] = "dir"; continue }
                let mtime = try fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
                result[root + "/" + relative] =
                    "\(try Data(contentsOf: url).base64EncodedString())@\(mtime?.timeIntervalSince1970 ?? -1)"
            }
        }
        return result
    }
}

/// Application Support under the fake home.
private final class FakeHome: FileManager, @unchecked Sendable {
    let home: URL
    init(_ home: URL) { self.home = home; super.init() }
    override func urls(for directory: FileManager.SearchPathDirectory,
                       in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        directory == .applicationSupportDirectory
            ? [home.appendingPathComponent("Library/Application Support", isDirectory: true)]
            : super.urls(for: directory, in: domainMask)
    }
}
