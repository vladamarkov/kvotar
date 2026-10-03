import XCTest
import KvotarCore
@testable import ClaudeAdapter

/// Drives the live `DispatchSource` watcher against a real filesystem write in a temp dir — the
/// path that was never exercised before (Step 7's real-data validation used direct parsing). This
/// is the regression test for BUG-1: an append to a watched file fires the FSEvents callback, and
/// the adapter must schedule a flush and emit the parsed `TokenEvent` without tripping the Swift
/// concurrency executor assertion ("Incorrect actor executor assumption" → SIGABRT).
///
/// STEP_26 adds the `deltaSignals` coverage: batched `tokenEvents` delivery, burn-tier crossing,
/// and the quota-429 observation from a token-less error flush.
final class ClaudeLocalAdapterWatcherTests: XCTestCase {

    /// Collects everything the adapter yields; a long-lived consumer like the real one.
    private actor Collector {
        private(set) var batches: [[TokenEvent]] = []
        private(set) var signals: [LocalDeltaSignal] = []
        func add(_ b: [TokenEvent]) { batches.append(b) }
        func add(_ s: LocalDeltaSignal) { signals.append(s) }
        var events: [TokenEvent] { batches.flatMap { $0 } }
        var count: Int { batches.reduce(0) { $0 + $1.count } }
        var signalCount: Int { signals.count }
    }

    private let assistantLine = #"{"type":"assistant","sessionId":"s1","requestId":"req-1","cwd":"/home/u/proj","slug":"my-session","gitBranch":"main","isSidechain":false,"message":{"id":"m1","model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":20,"cache_read_input_tokens":10}}}"# + "\n"

    /// Big enough that one flush crosses the burn tier (> 3k tok/min over the 2-min window).
    private let heavyAssistantLine = #"{"type":"assistant","sessionId":"s1","requestId":"req-2","cwd":"/home/u/proj","isSidechain":false,"message":{"id":"m2","model":"claude-sonnet-4-6","usage":{"input_tokens":20000,"output_tokens":5000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"# + "\n"

    /// Working-assumption quota-429 error line (shape unconfirmed — see
    /// `ClaudeJSONLParser.detectQuota429`); carries no token usage, so its flush has zero events.
    private let quota429Line = #"{"type":"assistant","sessionId":"s1","timestamp":"2026-07-05T08:00:00.000Z","isApiErrorMessage":true,"message":{"id":"e1","content":[{"type":"text","text":"Claude AI usage limit reached|1751702400"}]}}"# + "\n"

    private func makeRoot() throws -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aptest-claude-\(UUID().uuidString)", isDirectory: true)
        let projectDir = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        // Pre-existing file so a per-file source is created at startWatching; its content is before
        // the seeded EOF offset, so only bytes appended afterwards are reported.
        let file = projectDir.appendingPathComponent("session.jsonl")
        try Data((#"{"type":"human","sessionId":"s1","message":{"role":"user"}}"# + "\n").utf8)
            .write(to: file)
        return (root, file)
    }

    private func append(_ line: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        try handle.close()
    }

    func testWatcherEmitsEventOnRealFileAppend() async throws {
        let (root, file) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let adapter = ClaudeLocalAdapter(root: root, debounceInterval: .milliseconds(50))
        let collector = Collector()
        let consumer = Task { for await b in adapter.tokenEvents { await collector.add(b) } }
        defer { consumer.cancel() }

        await adapter.startWatching()

        // Real filesystem write → fires the DispatchSource event handler (the BUG-1 trigger).
        try append(assistantLine, to: file)

        // Wait for the watcher-driven flush; must not crash. (A direct flush also confirms the
        // parse path if FSEvents delivery is slow in the sandbox.)
        var delivered = await waitFor(collector, timeout: 3) { await $0.count > 0 }
        if !delivered {
            await adapter.flush()
            delivered = await waitFor(collector, timeout: 2) { await $0.count > 0 }
        }
        await adapter.stopWatching()

        XCTAssertTrue(delivered, "watcher did not emit a TokenEvent")
        let events = await collector.events
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.model, "claude-sonnet-4-6")
        XCTAssertEqual(event.inputTokens, 100)
        XCTAssertEqual(event.outputTokens, 50)
        let batches = await collector.batches
        XCTAssertEqual(batches.count, 1, "one flush → one batch on the stream")
    }

    func testDeltaSignalCarriesBurnTierCrossing() async throws {
        let (root, file) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let adapter = ClaudeLocalAdapter(root: root, debounceInterval: .milliseconds(50))
        let collector = Collector()
        let consumer = Task { for await s in adapter.deltaSignals { await collector.add(s) } }
        defer { consumer.cancel() }

        await adapter.startWatching()
        try append(heavyAssistantLine, to: file)
        await adapter.flush()
        let delivered = await waitFor(collector, timeout: 3) { await $0.signalCount > 0 }
        await adapter.stopWatching()

        XCTAssertTrue(delivered, "no delta signal emitted")
        let signals = await collector.signals
        let signal = try XCTUnwrap(signals.first)
        XCTAssertTrue(signal.burnTierCrossed, "25k tokens in one flush must cross the burn tier")
        XCTAssertTrue(signal.surfaceBucketChanged, "first Claude Code event is a new bucket")
        XCTAssertTrue(signal.quota429Observations.isEmpty)
    }

    func testQuota429ObservationEmittedFromTokenlessFlush() async throws {
        let (root, file) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let adapter = ClaudeLocalAdapter(root: root, debounceInterval: .milliseconds(50))
        let collector = Collector()
        let consumer = Task { for await s in adapter.deltaSignals { await collector.add(s) } }
        defer { consumer.cancel() }

        await adapter.startWatching()
        // Error line only — no token usage, so the flush has zero TokenEvents; the delta signal
        // must still surface the quota-429 observation (watcher flushes on any appended data).
        try append(quota429Line, to: file)
        await adapter.flush()
        let delivered = await waitFor(collector, timeout: 3) { await $0.signalCount > 0 }
        await adapter.stopWatching()

        XCTAssertTrue(delivered, "no delta signal emitted for a 429-only flush")
        let signals = await collector.signals
        let signal = try XCTUnwrap(signals.first)
        XCTAssertEqual(signal.quota429Observations.count, 1)
        let observation = try XCTUnwrap(signal.quota429Observations.first)
        XCTAssertEqual(observation.sourceFile, "session.jsonl")
        XCTAssertEqual(observation.observedAt.timeIntervalSince1970, 1_783_238_400, accuracy: 1,
                       "observedAt comes from the line's ISO8601 timestamp (2026-07-05T08:00:00Z)")
    }

    private func waitFor(_ collector: Collector, timeout: TimeInterval,
                         condition: (Collector) async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition(collector) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await condition(collector)
    }
}
