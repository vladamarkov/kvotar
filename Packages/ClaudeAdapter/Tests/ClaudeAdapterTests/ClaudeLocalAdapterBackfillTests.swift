import XCTest
import KvotarCore
@testable import ClaudeAdapter

/// STEP_95 backfill through the real adapter + real store: the mid-stream-gap case (97 of the
/// 200 missing Claude events sat *inside* sessions the app otherwise tracked), and the two
/// deliberate exclusions — no delta signals and no quota-429 replay — that keep a historic
/// sweep from impersonating live activity.
final class ClaudeLocalAdapterBackfillTests: XCTestCase {

    private var root: URL!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aptest-claude-backfill-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: root.appendingPathComponent("proj", isDirectory: true),
            withIntermediateDirectories: true)
        dbPath = NSTemporaryDirectory()
            .appending("aptest-claude-backfill-\(UUID().uuidString).db")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        root = nil
        dbPath = nil
        super.tearDown()
    }

    private func assistantLine(request: String, timestamp: String) -> String {
        #"{"type":"assistant","sessionId":"s1","requestId":"\#(request)","timestamp":"\#(timestamp)","cwd":"/home/u/proj","isSidechain":false,"message":{"id":"m-\#(request)","model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":20,"cache_read_input_tokens":10}}}"# + "\n"
    }

    /// Working-assumption quota-429 error line (see `ClaudeJSONLParser.detectQuota429`).
    private let quota429Line = #"{"type":"assistant","sessionId":"s1","timestamp":"2026-07-05T08:00:00.000Z","isApiErrorMessage":true,"message":{"id":"e1","content":[{"type":"text","text":"Claude AI usage limit reached|1751702400"}]}}"# + "\n"

    /// Crosses the burn tier in one flush, so a live delta signal is observable on demand.
    private let heavyLine = #"{"type":"assistant","sessionId":"s1","requestId":"req-heavy","cwd":"/home/u/proj","isSidechain":false,"message":{"id":"m-heavy","model":"claude-sonnet-4-6","usage":{"input_tokens":20000,"output_tokens":5000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"# + "\n"

    private func seedEvent(dedupKey: String) -> TokenEvent {
        TokenEvent(tool: .claude, sessionId: "s1", surfaceBucket: "Claude Code",
                   inputTokens: 100, outputTokens: 50, cacheCreationTokens: 20,
                   cacheReadTokens: 10,
                   recordedAt: Date(timeIntervalSince1970: 1_780_000_000), dedupKey: dedupKey)
    }

    /// Head and tail of the session are already in the store (the app was tailing, stopped,
    /// rejoined at end-of-file); the sweep must recover exactly the middle event.
    func testMidStreamGapIsFilledExactly() async throws {
        let file = root.appendingPathComponent("proj/session.jsonl")
        let lines = assistantLine(request: "req-1", timestamp: "2026-07-05T08:00:00.000Z")
            + assistantLine(request: "req-2", timestamp: "2026-07-05T08:05:00.000Z")
            + assistantLine(request: "req-3", timestamp: "2026-07-05T08:10:00.000Z")
        try Data(lines.utf8).write(to: file)

        let store = try SQLiteStore(path: dbPath)
        try await store.writeTokenEvents([seedEvent(dedupKey: "req-1"),
                                          seedEvent(dedupKey: "req-3")])

        let adapter = ClaudeLocalAdapter(root: root)
        let summary = await adapter.backfillEvents(since: .distantPast) { events in
            try? await store.backfillTokenEvents(events)
        }

        XCTAssertEqual(summary.filesScanned, 1)
        XCTAssertEqual(summary.eventsParsed, 3)
        XCTAssertEqual(summary.eventsInserted, 1, "only the mid-stream gap is new")
        XCTAssertEqual(summary.insertedTokens, 180)

        // Re-run: the whole file is known now — a re-read costs nothing and changes nothing.
        let again = await adapter.backfillEvents(since: .distantPast) { events in
            try? await store.backfillTokenEvents(events)
        }
        XCTAssertEqual(again.eventsParsed, 3)
        XCTAssertEqual(again.eventsInserted, 0)
    }

    /// The sweep parses a file containing a quota-429 line and heavy token lines, and neither a
    /// delta signal nor a 429 observation may surface — verified by then triggering a genuine
    /// live delta and checking it carries no backfill residue.
    func testBackfillEmitsNoDeltaSignalsAndQueuesNoQuota429s() async throws {
        let file = root.appendingPathComponent("proj/session.jsonl")
        try Data((assistantLine(request: "req-1", timestamp: "2026-07-05T08:00:00.000Z")
                  + quota429Line).utf8).write(to: file)

        let adapter = ClaudeLocalAdapter(root: root, debounceInterval: .milliseconds(50))
        actor Signals {
            private(set) var received: [LocalDeltaSignal] = []
            func add(_ s: LocalDeltaSignal) { received.append(s) }
        }
        let signals = Signals()
        let consumer = Task { for await s in adapter.deltaSignals { await signals.add(s) } }
        defer { consumer.cancel() }

        await adapter.startWatching()
        let summary = await adapter.backfillEvents(since: .distantPast) { events in
            .init(inserted: events.count, insertedTokens: 0)
        }
        // 2, not 1: the error line is still `type == "assistant"` with a message id, so it
        // parses as a zero-usage token event — exactly as it does on the live path.
        XCTAssertEqual(summary.eventsParsed, 2)

        // Nothing may have surfaced from the sweep itself.
        try await Task.sleep(nanoseconds: 200_000_000)
        var count = await signals.received.count
        XCTAssertEqual(count, 0, "backfill must not emit delta signals")

        // Now a genuine live append: its delta must be clean of the historic 429.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(heavyLine.utf8))
        try handle.close()
        await adapter.flush()
        await adapter.stopWatching()

        for _ in 0..<20 {
            count = await signals.received.count
            if count > 0 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let received = await signals.received
        let live = try XCTUnwrap(received.first, "the live append should produce a delta")
        XCTAssertTrue(live.quota429Observations.isEmpty,
                      "the sweep must not queue historic 429s into a later live delta")
    }
}
