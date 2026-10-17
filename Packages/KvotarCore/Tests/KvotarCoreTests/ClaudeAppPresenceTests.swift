import XCTest
@testable import KvotarCore

final class ClaudeAppPresenceTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-presence-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private var app: URL { root.appendingPathComponent("Claude.app") }
    private var support: URL { root.appendingPathComponent("Claude") }
    private func seed() throws {
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "2.3.4"], format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data(#"{"oauth:tokenCacheV2":"fake-token-sensitive","email":"fake-private@example.invalid","uuid":"11111111-1111-4111-8111-111111111111"}"#.utf8)
            .write(to: support.appendingPathComponent("config.json"))
    }
    func testDetectorAndEnvironmentContainOnlyMetadata() throws {
        try seed()
        let detector = ClaudeAppDetector(applicationURL: app, supportURL: support)
        let presence = detector.detect()
        XCTAssertTrue(presence.canConnect)
        XCTAssertEqual(presence.version, "2.3.4")
        XCTAssertEqual(presence.codeSessions.presence, .absent)
        let facts = DiagnosticsBundle.HostFacts(appVersion: "test", channel: .release,
            notificationAuthorization: "unknown", openAtLogin: false, claudeApp: presence)
        let report = DiagnosticsBundle.environmentReport(facts: facts, now: Date(), logsCollected: [])
        for sentinel in ["fake-token-sensitive", "fake-private@example.invalid", "11111111-1111-4111-8111-111111111111"] {
            XCTAssertFalse(report.contains(sentinel))
        }
        XCTAssertTrue(report.contains("Credential sources (existence only — contents never read here):"))
        XCTAssertTrue(report.contains("Claude app metadata and cache-marker presence (no value is decoded, kept or printed)"))
        XCTAssertEqual(presence.diagnosticsLines.count, 5)
    }
    func testMissingOversizedAndSymlinkAreDistinct() throws {
        let detector = ClaudeAppDetector(applicationURL: app, supportURL: support)
        XCTAssertEqual(detector.detect().app, .absent)
        try seed()
        let url = support.appendingPathComponent("config.json")
        try Data(repeating: 65, count: ClaudeAppDetector.configByteCap + 1).write(to: url)
        XCTAssertEqual(detector.detect().cacheMarker, .unknown)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(detector.detect().config, .unknown)
        XCTAssertFalse(detector.detect().canConnect)
    }
    func testMarkerAbsentAndFolderCountsCappedWithoutFollowingSymlinks() throws {
        try seed()
        try Data("{}".utf8).write(to: support.appendingPathComponent("config.json"))
        let folder = support.appendingPathComponent("claude-code-sessions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<4 { try Data().write(to: folder.appendingPathComponent("\(index).json")) }
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("loop"), withDestinationURL: folder)
        let bounded = ClaudeAppDetector(applicationURL: app, supportURL: support, fileCap: 2).detect()
        XCTAssertEqual(bounded.cacheMarker, .absent)
        XCTAssertTrue(bounded.codeSessions.capped)
        let exact = ClaudeAppDetector(applicationURL: app, supportURL: support).detect()
        XCTAssertEqual(exact.codeSessions.files, 4)
        XCTAssertFalse(exact.codeSessions.capped)
    }
    func testConnectionAndReboundAreWrittenTogetherWithoutIdentityPayloadInEvent() async throws {
        let store = try SQLiteStore(path: root.appendingPathComponent("fixture.sqlite").path)
        let binding = ClaudeAppBinding(identityDigest: String(repeating: "a", count: 64), connectionRequested: true)
        try await store.writeSetting(key: "last_open_snapshot_claude", value: "synthetic-old-snapshot")
        try await store.writeClaudeAppBinding(binding, rebound: true)
        let oldSnapshot = try await store.readSetting(key: "last_open_snapshot_claude")
        XCTAssertNil(oldSnapshot)
        let restored = try await store.readClaudeAppBinding()
        XCTAssertEqual(restored, binding)
        try await store.writeClaudeAppBinding(binding, rebound: true)
        let events = try await store.discontinuityEvents(tool: .claude, since: .distantPast,
            until: .distantFuture, types: ["account_rebound"])
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events.first?.oldValue)
        XCTAssertNil(events.first?.newValue)
    }
}
