import XCTest
@testable import KvotarCore

final class DiagnosticsPayloadSanitizerTests: XCTestCase {
    func testForbiddenContentAndCredentialsNeverSurvive() throws {
        let input = Data(#"""
        {
          "usage": 42,
          "access_token": "secret-token",
          "nested": {"prompt": "private prompt", "code": "private code"},
          "authorization": "Bearer abcdef"
        }
        """#.utf8)

        let output = try XCTUnwrap(
            DiagnosticsPayloadSanitizer.sanitize(
                endpoint: DiagnosticsEndpoint.claudeUsage, body: input))
        let text = String(decoding: output, as: UTF8.self)

        XCTAssertTrue(text.contains("\"usage\":42"))
        XCTAssertFalse(text.contains("secret-token"))
        XCTAssertFalse(text.contains("private prompt"))
        XCTAssertFalse(text.contains("private code"))
        XCTAssertFalse(text.contains("abcdef"))
        XCTAssertTrue(text.contains("<redacted>"))
    }

    /// 2026-08-31 tester bundle: the log said `email=<redacted>` while the captured bodies kept
    /// the address. Identity fields are redacted; a bare `name` (plan/model names) is not.
    func testIdentityFieldsAreRedacted() throws {
        let input = Data(#"""
        {
          "account": {"email": "someone@example.com", "full_name": "Some One",
                      "display_name": "Some", "name": "plus"},
          "plan_type": "plus"
        }
        """#.utf8)

        let output = try XCTUnwrap(
            DiagnosticsPayloadSanitizer.sanitize(endpoint: "account/read", body: input))
        let text = String(decoding: output, as: UTF8.self)

        XCTAssertFalse(text.contains("someone@example.com"))
        XCTAssertFalse(text.contains("Some One"))
        XCTAssertFalse(text.contains("\"display_name\":\"Some\""))
        XCTAssertTrue(text.contains("\"name\":\"plus\""), "a bare `name` key is not identity")
        XCTAssertTrue(text.contains("\"plan_type\":\"plus\""))
    }

    /// STEP_171: the 2026-08-31 amendment redacted the profile's names and address but left its
    /// three UUIDs — account, organization and application — verbatim in every captured body.
    /// The organisation fields beside them must survive: `ClaudeAccountAdapter` reads
    /// `rate_limit_tier`, `organization_type` and `seat_tier` for plan and enterprise detection,
    /// and redacting the wrapping object rather than the leaf would take them with it.
    func testProfileUUIDsAreRedactedWhileOrganisationShapeSurvives() throws {
        let input = Data(#"""
        {
          "account": {"uuid": "11111111-2222-3333-4444-555555555555", "name": "max"},
          "organization": {"uuid": "66666666-7777-8888-9999-aaaaaaaaaaaa",
                           "name": "Example", "organization_type": "personal",
                           "rate_limit_tier": "default", "seat_tier": "standard"},
          "application": {"uuid": "bbbbbbbb-cccc-dddd-eeee-ffffffffffff", "slug": "claude-code"}
        }
        """#.utf8)

        let output = try XCTUnwrap(
            DiagnosticsPayloadSanitizer.sanitize(
                endpoint: DiagnosticsEndpoint.claudeProfile, body: input))
        let text = String(decoding: output, as: UTF8.self)

        XCTAssertFalse(text.contains("11111111"), "the account UUID survived")
        XCTAssertFalse(text.contains("66666666"), "the organization UUID survived")
        XCTAssertFalse(text.contains("bbbbbbbb"), "the application UUID survived")
        XCTAssertEqual(text.components(separatedBy: "\"uuid\":\"<redacted>\"").count - 1, 3,
                       "all three UUID keys keep their name and lose their value")

        XCTAssertTrue(text.contains("\"organization_type\":\"personal\""))
        XCTAssertTrue(text.contains("\"rate_limit_tier\":\"default\""))
        XCTAssertTrue(text.contains("\"seat_tier\":\"standard\""))
        XCTAssertTrue(text.contains("\"slug\":\"claude-code\""))
        XCTAssertTrue(text.contains("\"name\":\"Example\""), "a bare `name` key is not identity")
    }

    func testUnknownEndpointAndNonJSONAreRejected() {
        XCTAssertNil(DiagnosticsPayloadSanitizer.sanitize(
            endpoint: DiagnosticsEndpoint.claudeOther, body: Data("{}".utf8)))
        XCTAssertNil(DiagnosticsPayloadSanitizer.sanitize(
            endpoint: DiagnosticsEndpoint.claudeUsage, body: Data("not json".utf8)))
    }
}
