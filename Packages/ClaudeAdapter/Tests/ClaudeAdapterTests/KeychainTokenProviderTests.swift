import XCTest
import KvotarCore
@testable import ClaudeAdapter

/// STEP_117 / REV-71 §3.2 — the credential read tells "not there" apart from "could not look".
///
/// The provider delegates to `/usr/bin/security`, and `securityToolPath` is injectable, so a
/// scripted stand-in can produce each outcome exactly. What matters is the *shape* of the answer:
/// `nil` becomes `setupRequired` upstream and is read by the app as "this tool was never set up",
/// so only a genuinely absent Keychain item may produce it.
final class KeychainTokenProviderTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("aptest-keychain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        scratch = nil
        super.tearDown()
    }

    /// Writes an executable stand-in for `/usr/bin/security` that ignores its arguments.
    private func fakeSecurity(body: String) throws -> String {
        let url = scratch.appendingPathComponent("security")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// The descriptor-exhaustion shape: the tool cannot be launched at all. This must never be
    /// mistaken for an absent credential — it is what happened on 2026-08-17.
    func testUnlaunchableSecurityToolThrowsCredentialUnreadable() {
        let provider = KeychainTokenProvider(
            securityToolPath: scratch.appendingPathComponent("does-not-exist").path)
        XCTAssertThrowsError(try provider.credential()) { error in
            guard case AccountAdapterError.credentialUnreadable = error else {
                return XCTFail("expected credentialUnreadable, got \(error)")
            }
        }
    }

    /// Exit 44 is `errSecItemNotFound` — the one exit that really does mean "not set up".
    func testItemNotFoundReturnsNil() throws {
        let provider = KeychainTokenProvider(securityToolPath: try fakeSecurity(body: "exit 44"))
        XCTAssertNil(try provider.credential())
    }

    /// Any other non-zero exit means the item may well exist and the read was refused.
    func testDeniedReadThrowsCredentialUnreadable() throws {
        let provider = KeychainTokenProvider(securityToolPath: try fakeSecurity(body: "exit 51"))
        XCTAssertThrowsError(try provider.credential()) { error in
            guard case AccountAdapterError.credentialUnreadable = error else {
                return XCTFail("expected credentialUnreadable, got \(error)")
            }
        }
    }

    /// The happy path still parses `claudeAiOauth.accessToken` (§8.0.1) — the split above must not
    /// have disturbed it.
    func testSuccessfulReadDecodesTheOAuthBlock() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"tok","subscriptionType":"max","expiresAt":123}}"#
        let provider = KeychainTokenProvider(
            securityToolPath: try fakeSecurity(body: "cat <<'JSON'\n\(json)\nJSON"))
        let credential = try provider.credential()
        XCTAssertEqual(credential?.accessToken, "tok")
        XCTAssertEqual(credential?.subscriptionType, "max")
    }
}
