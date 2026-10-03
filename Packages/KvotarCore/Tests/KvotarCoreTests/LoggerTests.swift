import XCTest
@testable import KvotarCore

/// The attribution half of STEP_135: a log line must say which process wrote it, and a run must
/// say what build, host and clock produced it. Neither fact appeared anywhere in the file before,
/// which made a log that left the machine unattributable.
final class LoggerTests: XCTestCase {

    private var logDirectory: URL { Logger.logDirectoryURL }

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    }

    func testTheLinePrefixCarriesTheProcessID() throws {
        let line = try captureLine { Logger.info("Poll complete", component: .pollEngine,
                                                 metadata: ["util": "7%"]) }

        XCTAssertTrue(line.contains("[\(Logger.processID)]["), "pid sits between level and component")
        XCTAssertTrue(line.contains("[PollEngine] Poll complete · util=7%"))
    }

    /// One structured line, not a block — `kvotar logs` filters per line, so a ten-line banner
    /// would be ten records a `--component` filter could split apart.
    func testTheLaunchBannerIsOneLineNamingBuildHostAndClock() throws {
        let line = try captureLine {
            Logger.launchBanner(appVersion: "0.2.0 (5) beta", channel: "beta",
                                databasePath: "/tmp/kvotar.db", schemaMigration: "v20_x")
        }

        XCTAssertEqual(line.filter(\.isNewline).count, 0)
        XCTAssertTrue(line.contains("Kvotar started"))
        for fragment in [#"version="0.2.0 (5) beta""#, "channel=beta", "pid=\(Logger.processID)",
                         "schema=v20_x", "db=/tmp/kvotar.db",
                         "tz=\(TimeZone.current.identifier)"] {
            XCTAssertTrue(line.contains(fragment), "banner is missing \(fragment)")
        }
        // Timezone is load-bearing: every figure in this app is timestamp arithmetic against UTC
        // buckets, so a tester in another zone produces numbers that look like engine bugs.
        XCTAssertTrue(line.contains("utc_offset_s="))
    }

    /// The blob is space-separated and a token with no `=` is discarded, so an unquoted spaced
    /// value did not truncate — it read as something else. `error=unable to open database file`
    /// parsed as `error=unable`, four words dropped silently, in the live log for months.
    func testAValueContainingSpacesIsQuotedSoItSurvivesTheBlobGrammar() throws {
        let line = try captureLine {
            Logger.warning("Codex SQLite query unavailable", component: .codexLocalAdapter,
                           metadata: ["error": "unable to open database file",
                                      "table": "thread_goals"])
        }

        XCTAssertTrue(line.contains(#"error="unable to open database file""#))
        XCTAssertTrue(line.contains("table=thread_goals"), "an unspaced value stays bare")
    }

    func testAValueWithAQuoteInItRoundTripsThroughEscaping() {
        XCTAssertEqual(Logger.metadataValue(#"say "hi" now"#), #""say \"hi\" now""#)
        XCTAssertEqual(Logger.metadataValue("7%"), "7%", "no quoting where none is needed")
    }

    /// The banner's own two spaced values — the reason this defect surfaced at all.
    func testTheBannerQuotesItsDatabasePathAndOSString() throws {
        let line = try captureLine {
            Logger.launchBanner(appVersion: "0.2.0 (5)", channel: "beta",
                                databasePath: "/Users/x/Library/Application Support/Kvotar/kvotar.db",
                                schemaMigration: "v20_x")
        }
        XCTAssertTrue(line.contains(#"db="/Users/x/Library/Application Support/Kvotar/kvotar.db""#))
        XCTAssertTrue(line.contains(#"version="0.2.0 (5)""#))
    }

    func testAnUnknownSchemaAndDatabaseAreNamedRatherThanOmitted() throws {
        let line = try captureLine {
            Logger.launchBanner(appVersion: "0.2.0", channel: "release",
                                databasePath: nil, schemaMigration: nil)
        }
        XCTAssertTrue(line.contains("schema=unknown"))
        XCTAssertTrue(line.contains("db=unavailable"))
    }

    /// `NSError`'s domain and code are the two fields worth filtering on and they are buried in the
    /// middle of its description. The rendering must also be one line — the offline error that
    /// prompted this carries a nested `UserInfo` block several lines deep.
    func testAnErrorRendersAsGreppableOneLineMetadata() {
        let error = NSError(domain: NSURLErrorDomain, code: -1009, userInfo: [
            NSLocalizedDescriptionKey: "The Internet connection appears\nto be offline.",
        ])
        let metadata = Logger.metadata(for: error)

        XCTAssertEqual(metadata["error_domain"], NSURLErrorDomain)
        XCTAssertEqual(metadata["error_code"], "-1009")
        XCTAssertEqual(metadata["error"], "The Internet connection appears ⏎ to be offline.")
        XCTAssertFalse(metadata.values.contains { $0.contains(where: \.isNewline) })
    }

    // MARK: - Adapter errors are legible in the line (REV-91)

    /// Before REV-91 a failed poll logged only
    /// `error="The operation couldn't be completed. (KvotarCore.AccountAdapterError error 4.)"`.
    /// The associated value — the only part naming the failing field — was dropped by the
    /// `NSError` bridge, so the 2026-09-08 Codex decode outage was invisible in a log that had
    /// recorded it 22 times.
    func testDecodingErrorNamesTheFieldInTheLogLine() throws {
        let error = AccountAdapterError.decoding(
            "typeMismatch(Swift.String, codingPath: [rate_limit_reached_type])")

        let line = try captureLine {
            Logger.warning("Poll failed", component: .pollEngine,
                           metadata: Logger.metadata(for: error))
        }

        XCTAssertTrue(line.contains("rate_limit_reached_type"), "the failing field must be named")
        XCTAssertTrue(line.contains("decoding:"), "the case must be named, not numbered")
        XCTAssertFalse(line.contains("The operation couldn’t be completed"))
    }

    /// Each case renders as a stable, greppable name. This is what makes the ordinal irrelevant:
    /// Swift bridges multi-payload enum cases by layout, not declaration order (`decoding` is 4,
    /// `credentialExpired` is 2), so reordering the cases silently renumbers `error_code`.
    func testEveryAdapterErrorCaseRendersItsName() {
        let details = RateLimit429Details(statusCode: 429, headers: [:], body: "redacted",
                                          category: "rate_pressure")
        let expected: [(AccountAdapterError, String)] = [
            (.setupRequired, "setup_required"),
            (.credentialUnreadable("fd exhaustion"), "credential_unreadable: fd exhaustion"),
            (.reauthRequired, "reauth_required"),
            (.rateLimited(retryAfter: 120, details: details),
             "rate_limited: retry_after=120s category=rate_pressure"),
            (.credentialExpired(details: nil), "credential_expired: category=none"),
            (.httpStatus(503), "http_status: 503"),
            (.decoding("bad shape"), "decoding: bad shape"),
        ]

        for (error, description) in expected {
            XCTAssertEqual((error as NSError).localizedDescription, description)
        }
    }

    /// The privacy line (PATTERNS.md §Logger privacy boundary, Baseline §10.6): the two cases
    /// that carry a captured response print its *category*, never its body.
    func testRateLimitDetailsBodyNeverReachesTheDescription() {
        let details = RateLimit429Details(
            statusCode: 429, headers: ["Retry-After": "120"],
            body: "{\"error\":\"secret-body-content\"}", category: "rate_pressure")

        for error: AccountAdapterError in [.rateLimited(retryAfter: 120, details: details),
                                           .credentialExpired(details: details)] {
            let rendered = (error as NSError).localizedDescription
            XCTAssertFalse(rendered.contains("secret-body-content"))
            XCTAssertTrue(rendered.contains("rate_pressure"))
        }
    }

    // MARK: - Helpers

    /// Runs `body` against a private log file and returns the single line it wrote.
    private func captureLine(_ body: () -> Void) throws -> String {
        let basename = "logger-test-\(UUID().uuidString.prefix(8))"
        let url = Logger.logFileURL(basename: basename)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        Logger.useLogFile(basename: basename)
        defer { Logger.useLogFile(basename: ProductIdentity.logBasename) }
        body()

        let drained = expectation(description: "log write drained")
        Logger.currentFileWriterForTesting.drainForTesting { drained.fulfill() }
        wait(for: [drained], timeout: 5)

        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 1, "expected exactly one record")
        return lines.first ?? ""
    }
}
