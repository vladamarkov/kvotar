import XCTest
import KvotarCore
@testable import CodexAdapter

/// STEP_117 / REV-71 §3.2 — the Codex twin of the Claude split: `~/.codex/auth.json` being absent
/// is a fact about the user; `auth.json` being unreadable is a fact about our process, and only the
/// first may reach `DetectionStatus.classify` as "never set up".
final class CodexAuthFileReaderTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("aptest-codexauth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let scratch {
            // Restore readability so the tree can be removed.
            let file = scratch.appendingPathComponent("auth.json")
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: scratch)
        }
        scratch = nil
        super.tearDown()
    }

    func testAbsentFileReturnsNil() throws {
        let reader = CodexAuthFileReader(path: scratch.appendingPathComponent("auth.json"))
        XCTAssertNil(try reader.credential())
    }

    /// The file is there and we cannot open it — the descriptor-exhaustion / permissions shape.
    func testUnreadableFileThrowsCredentialUnreadable() throws {
        let file = scratch.appendingPathComponent("auth.json")
        try Data(#"{"tokens":{"access_token":"tok"}}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)

        let reader = CodexAuthFileReader(path: file)
        XCTAssertThrowsError(try reader.credential()) { error in
            guard case AccountAdapterError.credentialUnreadable = error else {
                return XCTFail("expected credentialUnreadable, got \(error)")
            }
        }
    }

    func testReadableFileDecodesTokenAndAccountId() throws {
        let file = scratch.appendingPathComponent("auth.json")
        try Data(#"{"tokens":{"access_token":"tok","account_id":"acct"}}"#.utf8).write(to: file)

        let credential = try CodexAuthFileReader(path: file).credential()
        XCTAssertEqual(credential?.accessToken, "tok")
        XCTAssertEqual(credential?.accountId, "acct")
    }
}
