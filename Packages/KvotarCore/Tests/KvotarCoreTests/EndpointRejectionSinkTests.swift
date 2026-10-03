import XCTest
import GRDB
@testable import KvotarCore

/// The always-on half of STEP_75: the standing-rejection signal runs on the **release** channel,
/// where diagnostics capture is off — the tester who needs the signal is exactly the one not
/// capturing payloads.
final class EndpointRejectionSinkTests: XCTestCase {

    private var dbPath: String!

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory()
            .appending("kvotar-rejection-sink-\(UUID().uuidString).db")
        DiagnosticsCapture.setEnabled(false)
    }

    override func tearDown() {
        DiagnosticsCapture.setEnabled(false)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        dbPath = nil
        super.tearDown()
    }

    /// `GRDB.Row` is not `Sendable`, so rows are projected to this inside the read.
    private struct HealthRow: Sendable {
        let category: String?
        let endpoint: String?
        let consecutiveCount: Int?
        let responseBody: String?
    }

    /// The sink writes fire-and-forget on a detached `Task`, so the assertion waits for the row
    /// rather than assuming it has landed.
    private func healthRows(_ store: SQLiteStore, expected: Int,
                            timeout: TimeInterval = 3) async throws -> [HealthRow] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let found = try await store.withPool { pool in
                try pool.read { db in
                    try Row.fetchAll(db, sql: "SELECT * FROM poll_health_events ORDER BY id")
                        .map {
                            HealthRow(category: $0["category"], endpoint: $0["endpoint"],
                                      consecutiveCount: $0["consecutive_count"],
                                      responseBody: $0["response_body"])
                        }
                }
            }
            if found.count >= expected || Date() >= deadline { return found }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func rawPayloadCount(_ store: SQLiteStore) async throws -> Int {
        try await store.withPool { pool in
            try pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM raw_payloads") ?? 0
            }
        }
    }

    func testEpisodeIsRecordedWithCaptureOffAndNoPayloadIsStored() async throws {
        let store = try SQLiteStore(path: dbPath)
        let sink = LiveDiagnosticsSink(store: store)
        let body = Data(#"{"error":"only available for Pro and Max plans"}"#.utf8)

        for _ in 1...5 {
            sink.capture(tool: .claude, endpoint: DiagnosticsEndpoint.claudePrepaid,
                         body: body, httpStatus: 403)
        }

        let health = try await healthRows(store, expected: 1)
        XCTAssertEqual(health.count, 1, "five rejections, one row — and it fired with capture off")
        XCTAssertEqual(health.first?.category, "endpoint_rejected")
        XCTAssertEqual(health.first?.endpoint, "claude_prepaid")
        XCTAssertEqual(health.first?.consecutiveCount, 3)
        XCTAssertNil(health.first?.responseBody,
                     "release-channel rows carry no provider payload (§10.7a posture unchanged)")

        try await Task.sleep(nanoseconds: 300_000_000)
        let payloads = try await rawPayloadCount(store)
        XCTAssertEqual(payloads, 0, "payload capture stays gated — only the signal is always-on")
    }

    func testHealthRowNeverStoresBodyWhenExtendedCaptureIsOn() async throws {
        DiagnosticsCapture.setEnabled(true)
        let store = try SQLiteStore(path: dbPath)
        let sink = LiveDiagnosticsSink(store: store)
        let body = Data(#"{"error":"only available for Pro and Max plans"}"#.utf8)

        for _ in 1...3 {
            sink.capture(tool: .claude, endpoint: DiagnosticsEndpoint.claudePrepaid,
                         body: body, httpStatus: 403)
        }

        let health = try await healthRows(store, expected: 1)
        XCTAssertNil(health.first?.responseBody,
                     "persistent health evidence never stores response content")
    }

    func testRecoveryWritesTheClearRowThroughTheSink() async throws {
        let store = try SQLiteStore(path: dbPath)
        let sink = LiveDiagnosticsSink(store: store)
        let body = Data("{}".utf8)

        for _ in 1...4 {
            sink.capture(tool: .claude, endpoint: DiagnosticsEndpoint.claudePrepaid,
                         body: body, httpStatus: 403)
        }
        sink.capture(tool: .claude, endpoint: DiagnosticsEndpoint.claudePrepaid,
                     body: body, httpStatus: 200)

        let health = try await healthRows(store, expected: 2)
        XCTAssertEqual(health.count, 2)
        XCTAssertEqual(health.last?.category, "endpoint_rejected_cleared")
        XCTAssertEqual(health.last?.consecutiveCount, 4,
                       "the clear-row carries the episode's true occurrence count")
        XCTAssertNil(health.last?.responseBody,
                     "the clearing response is a success payload — it would misrepresent the row")
    }

    func testUnmappedEndpointWritesNoRow() async throws {
        let store = try SQLiteStore(path: dbPath)
        let sink = LiveDiagnosticsSink(store: store)

        for _ in 1...5 {
            sink.capture(tool: .codex, endpoint: "account/rateLimits/read",
                         body: Data("{}".utf8), httpStatus: 500)
        }

        try await Task.sleep(nanoseconds: 300_000_000)
        let health = try await healthRows(store, expected: 0, timeout: 0.3)
        XCTAssertTrue(health.isEmpty,
                      "no health-table vocabulary for this name — the log line carries it instead")
    }
}
