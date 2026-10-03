import XCTest
@testable import KvotarCore

/// Absolute rule R2 (STEP_239): Kvotar never writes under `~/.claude` or `~/.codex`. Every writer
/// in this package runs against a fake home that holds both trees, each on the path it would use
/// in the app — derived from that home — and afterwards both trees are byte-for-byte what they
/// were, with no file added.
///
/// The static check in `scripts/check_rules.sh` only catches a *new* writer; this test is what
/// catches a bad destination inside an approved one.
final class CredentialTreesUntouchedTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvotar-fakehome-\(UUID().uuidString)", isDirectory: true)
        try CredentialTrees.populate(home)
    }

    override func tearDownWithError() throws {
        if home != nil { try? FileManager.default.removeItem(at: home) }
        DiagnosticsCapture.setEnabled(false)
    }

    func testEveryWriterLeavesTheCredentialTreesAlone() async throws {
        let fileManager = FakeHomeFileManager(home: home)
        let before = try CredentialTrees.snapshot(home)

        // Every destination comes from the home, and is proven to be inside it before any write.
        let legacyDatabase = ProductIdentity.legacyDatabaseURL(fileManager: fileManager)
        let databasePath = try SQLiteStore.defaultPath(fileManager: fileManager)
        let supportDirectory = URL(fileURLWithPath: databasePath).deletingLastPathComponent()
        let receipt = supportDirectory.appendingPathComponent(ProductIdentity.migrationReceiptFilename)
        let pidPath = try PIDLock.defaultPath(fileManager: fileManager)
        let logDirectory = ProductIdentity.logDirectory(fileManager: fileManager)
        let desktop = fileManager.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        for path in [legacyDatabase.path, databasePath, receipt.path, pidPath, logDirectory.path,
                     desktop.path] {
            XCTAssertTrue(path.hasPrefix(home.path + "/"), "destination escapes the fake home: \(path)")
        }
        try FileManager.default.createDirectory(at: legacyDatabase.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)

        // Legacy store → copy-only migrator → the Kvotar store, with its migrations and a write.
        let legacy = try SQLiteStore(path: legacyDatabase.path)
        try await legacy.writeSetting(key: "probe", value: "legacy")
        _ = try LegacyDataMigrator(
            legacyDatabaseURL: legacyDatabase,
            kvotarDatabaseURL: URL(fileURLWithPath: databasePath),
            receiptURL: receipt, fileManager: fileManager).migrateIfNeeded()
        let store = try SQLiteStore(path: databasePath)
        try await store.writeSetting(key: "probe", value: "kvotar")
        try await store.writeLifecycleEvent(.launch, appVersion: "0.0.0 (0)", occurredAt: Date())

        // Both PID locks.
        let lock = PIDLock(path: pidPath)
        XCTAssertEqual(lock.acquire(), .acquired)
        let legacyPid = try XCTUnwrap(PIDLock.legacyCompatibilityPath(fileManager: fileManager))
        XCTAssertTrue(legacyPid.hasPrefix(home.path + "/"))
        let legacyLock = PIDLock(path: legacyPid)
        XCTAssertEqual(legacyLock.acquire(), .acquired)

        // The log writer.
        let writer = LogFileWriter(basename: ProductIdentity.logBasename, directory: logDirectory)
        writer.writeLine("credential trees probe")
        await withCheckedContinuation { done in writer.drainForTesting { done.resume() } }

        // An ordinary diagnostics bundle, to the Desktop the app would use.
        _ = try await DiagnosticsBundle.build(
            store: store,
            facts: .init(appVersion: "0.0.0 (0)", channel: .release,
                         notificationAuthorization: "authorized", openAtLogin: false),
            logDirectory: logDirectory, destinationDirectory: desktop)

        lock.release()
        legacyLock.release()
        let after = try CredentialTrees.snapshot(home)
        let added = Set(after.keys).subtracting(before.keys).sorted()
        let removed = Set(before.keys).subtracting(after.keys).sorted()
        XCTAssertEqual(added, [], "R2: written under the credential trees: \(added)")
        XCTAssertEqual(removed, [], "R2: removed from the credential trees: \(removed)")
        for (path, contents) in before where after[path] != contents {
            XCTFail("R2: \(path) changed")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: databasePath),
                      "the writers really ran in the fake home")
    }
}

/// A `FileManager` whose user-domain directories live under a fake home.
final class FakeHomeFileManager: FileManager, @unchecked Sendable {
    let home: URL
    init(home: URL) { self.home = home; super.init() }

    override var homeDirectoryForCurrentUser: URL { home }

    override func urls(for directory: FileManager.SearchPathDirectory,
                       in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        switch directory {
        case .applicationSupportDirectory:
            return [home.appendingPathComponent("Library/Application Support", isDirectory: true)]
        case .libraryDirectory:
            return [home.appendingPathComponent("Library", isDirectory: true)]
        case .desktopDirectory:
            return [home.appendingPathComponent("Desktop", isDirectory: true)]
        default:
            return super.urls(for: directory, in: domainMask)
        }
    }
}

/// The two credential trees, as fixtures: what a real `~/.claude` and `~/.codex` hold that a
/// stray write could damage.
enum CredentialTrees {
    static let files = [
        ".claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r"}}"#,
        ".claude/settings.json": "{}",
        ".claude/projects/-tmp-project/session.jsonl": #"{"type":"user"}"#,
        ".claude.json": #"{"oauthAccount":{"emailAddress":"user@example.com"}}"#,
        ".codex/auth.json": #"{"tokens":{"access_token":"a","refresh_token":"r"}}"#,
        ".codex/config.toml": "model = \"gpt\"",
        ".codex/sessions/2026/01/01/rollout.jsonl": #"{"type":"session_meta"}"#,
    ]

    static func populate(_ home: URL) throws {
        for (path, contents) in files {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                ofItemAtPath: url.path)
        }
    }

    /// Every entry under the two trees (and `~/.claude.json`): contents plus modification time,
    /// directories included, so an added empty directory counts as a change too.
    static func snapshot(_ home: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let fm = FileManager.default
        for root in [".claude", ".codex"] {
            let base = home.appendingPathComponent(root)
            result[root] = "dir"
            let enumerator = fm.enumerator(atPath: base.path)
            while let relative = enumerator?.nextObject() as? String {
                let url = base.appendingPathComponent(relative)
                var isDirectory: ObjCBool = false
                fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
                result[root + "/" + relative] = isDirectory.boolValue ? "dir" : try fingerprint(url)
            }
        }
        result[".claude.json"] = try fingerprint(home.appendingPathComponent(".claude.json"))
        return result
    }

    private static func fingerprint(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let mtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
        return "\(data.base64EncodedString())@\((mtime as? Date)?.timeIntervalSince1970 ?? -1)"
    }
}
