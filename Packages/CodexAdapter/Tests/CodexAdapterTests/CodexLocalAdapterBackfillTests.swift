import XCTest
import KvotarCore
@testable import CodexAdapter

/// STEP_95 backfill through the real Codex adapter: a whole session file that was never watched
/// (10 such files were missing on the dogfood machine) is swept with its originator resolved
/// from the `session_meta` first line — the sweep cannot rely on the live watcher's discovery
/// pass having seen the file.
final class CodexLocalAdapterBackfillTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aptest-codex-backfill-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: root.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        root = nil
        super.tearDown()
    }

    private let sessionMeta =
        #"{"type":"session_meta","payload":{"originator":"codex_cli_rs","source":"cli"}}"# + "\n"

    private func tokenLine(timestamp: String, total: Int) -> String {
        #"{"type":"response_item","timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":30,"output_tokens":10,"cached_input_tokens":0,"reasoning_output_tokens":0,"total_tokens":\#(total)}}}}"# + "\n"
    }

    func testWholeUnwatchedFileIsSweptWithOriginatorResolved() async throws {
        let file = root.appendingPathComponent("sessions/rollout-2026-06-01.jsonl")
        try Data((sessionMeta
                  + tokenLine(timestamp: "2026-06-01T10:05:00Z", total: 40)
                  + tokenLine(timestamp: "2026-06-01T10:06:00Z", total: 41)).utf8)
            .write(to: file)

        actor Collector {
            private(set) var events: [TokenEvent] = []
            func add(_ batch: [TokenEvent]) -> JSONLBackfillReader.WriteCounts {
                events.append(contentsOf: batch)
                return .init(inserted: batch.count,
                             insertedTokens: batch.reduce(0) { $0 + $1.inputTokens + $1.outputTokens })
            }
        }
        let collector = Collector()

        // No `startWatching()` — the sweep must resolve everything itself.
        let adapter = CodexLocalAdapter(roots: [root])
        let summary = await adapter.backfillEvents(since: .distantPast) { events in
            await collector.add(events)
        }

        XCTAssertEqual(summary.filesScanned, 1)
        XCTAssertEqual(summary.eventsParsed, 2)
        XCTAssertEqual(summary.eventsInserted, 2)
        XCTAssertEqual(summary.insertedTokens, 80)

        let events = await collector.events
        XCTAssertEqual(events.count, 2)
        for event in events {
            XCTAssertEqual(event.tool, .codex)
            XCTAssertEqual(event.sessionId, "rollout-2026-06-01",
                           "session identity is the file basename (§17.1)")
            XCTAssertEqual(event.surfaceBucket, "CLI",
                           "originator must resolve from the session_meta first line")
            XCTAssertEqual(event.originator, "codex_cli_rs")
        }
        XCTAssertEqual(Set(events.map(\.dedupKey)).count, 2,
                       "dedup keys keep the basename_timestamp_total format")
        XCTAssertTrue(events.allSatisfy { $0.dedupKey.hasPrefix("rollout-2026-06-01_") })
    }
}
