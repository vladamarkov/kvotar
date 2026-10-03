import XCTest
import KvotarCore
@testable import CodexAdapter

/// Regression test for BUG-1 on the Codex watcher: an append to a watched rollout file fires the
/// `DispatchSource` handler, which must schedule a flush and emit the parsed `TokenEvent` without
/// tripping the concurrency executor assertion ("Incorrect actor executor assumption" → SIGABRT).
/// Mirrors `ClaudeLocalAdapterWatcherTests`; drives a real filesystem write in a temp dir.
///
/// STEP_26 adds the `deltaSignals` coverage: batched `tokenEvents` delivery and the quota-429
/// observation from a token-less error flush (Codex burn-tier crossing is covered by the shared
/// `BurnTierTracker` tests in KvotarCore plus the Claude watcher test).
final class CodexLocalAdapterWatcherTests: XCTestCase {

    private actor Collector {
        private(set) var batches: [[TokenEvent]] = []
        private(set) var signals: [LocalDeltaSignal] = []
        private(set) var writes: [Date] = []
        func add(_ b: [TokenEvent]) { batches.append(b) }
        func add(_ s: LocalDeltaSignal) { signals.append(s) }
        func add(_ w: Date) { writes.append(w) }
        var events: [TokenEvent] { batches.flatMap { $0 } }
        var count: Int { batches.reduce(0) { $0 + $1.count } }
        var signalCount: Int { signals.count }
        var writeCount: Int { writes.count }
    }

    private let sessionMeta =
        #"{"type":"session_meta","payload":{"originator":"codex_cli_rs","source":"cli"}}"# + "\n"
    private let tokenCountLine =
        #"{"type":"response_item","timestamp":"2026-07-01T10:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":30,"output_tokens":10,"cached_input_tokens":0,"reasoning_output_tokens":0,"total_tokens":40}}}}"# + "\n"
    /// Working-assumption quota-429 error line (D1 — shape unconfirmed; see
    /// `CodexJSONLParser.detectQuota429`). No token usage → its flush has zero events.
    private let quota429Line =
        #"{"type":"event_msg","timestamp":"2026-07-01T10:06:00Z","payload":{"type":"error","message":"Rate limit exceeded (429): usage_limit_reached"}}"# + "\n"

    /// An ordinary mid-turn line: real rollouts are mostly `item_completed` / `message` /
    /// `reasoning` / `custom_tool_call`, and the turn's `token_count` lands only at the end.
    /// Carries no usage and nothing that looks like a quota 429.
    private let midTurnLine =
        #"{"type":"response_item","timestamp":"2026-07-01T10:05:30Z","payload":{"type":"reasoning","summary":[]}}"# + "\n"

    private func makeRoot() throws -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aptest-codex-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        // Pre-existing file whose line 1 is the session_meta (originator/surface), read at
        // startWatching; the offset is seeded past it, so only appended events are reported.
        let file = sessionsDir.appendingPathComponent("rollout.jsonl")
        try Data(sessionMeta.utf8).write(to: file)
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

        let adapter = CodexLocalAdapter(roots: [root], debounceInterval: .milliseconds(50))
        let collector = Collector()
        let consumer = Task { for await b in adapter.tokenEvents { await collector.add(b) } }
        defer { consumer.cancel() }

        await adapter.startWatching()

        try append(tokenCountLine, to: file)

        var delivered = await waitFor(collector, timeout: 3) { await $0.count > 0 }
        if !delivered {
            await adapter.flush()
            delivered = await waitFor(collector, timeout: 2) { await $0.count > 0 }
        }
        await adapter.stopWatching()

        XCTAssertTrue(delivered, "watcher did not emit a TokenEvent")
        let events = await collector.events
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.tool, .codex)
        XCTAssertEqual(event.surfaceBucket, "CLI")   // codex_cli_rs → CLI (§8.4)
        XCTAssertEqual(event.inputTokens, 30)
        XCTAssertEqual(event.outputTokens, 10)
        let batches = await collector.batches
        XCTAssertEqual(batches.count, 1, "one flush → one batch on the stream")
    }

    func testQuota429ObservationEmittedFromTokenlessFlush() async throws {
        let (root, file) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let adapter = CodexLocalAdapter(roots: [root], debounceInterval: .milliseconds(50))
        let collector = Collector()
        let consumer = Task { for await s in adapter.deltaSignals { await collector.add(s) } }
        defer { consumer.cancel() }

        await adapter.startWatching()
        try append(quota429Line, to: file)
        await adapter.flush()
        let delivered = await waitFor(collector, timeout: 3) { await $0.signalCount > 0 }
        await adapter.stopWatching()

        XCTAssertTrue(delivered, "no delta signal emitted for a 429-only flush")
        let signals = await collector.signals
        let signal = try XCTUnwrap(signals.first)
        XCTAssertEqual(signal.tool, .codex)
        XCTAssertFalse(signal.subagentCountChanged, "Codex has no subagent concept")
        XCTAssertEqual(signal.quota429Observations.count, 1)
        XCTAssertEqual(signal.quota429Observations.first?.sourceFile, "rollout.jsonl")
    }

    /// STEP_170 — the tester's 2026-09-03 case at the adapter seam. Codex appends a whole turn's
    /// worth of lines before it writes any `token_count`, so a flush reports `events=0` while the
    /// surface is plainly working. That flush must still report a **local write**: the liveness
    /// timestamp the Elsewhere notification's idle test reads.
    func testTokenlessAppendEmitsLocalWriteButNoTokenEvent() async throws {
        let (root, file) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let adapter = CodexLocalAdapter(roots: [root], debounceInterval: .milliseconds(50))
        let collector = Collector()
        let writes = Task { for await w in adapter.localWrites { await collector.add(w) } }
        let tokens = Task { for await b in adapter.tokenEvents { await collector.add(b) } }
        let deltas = Task { for await s in adapter.deltaSignals { await collector.add(s) } }
        defer { writes.cancel(); tokens.cancel(); deltas.cancel() }

        await adapter.startWatching()
        try append(midTurnLine, to: file)
        await adapter.flush()
        let delivered = await waitFor(collector, timeout: 3) { await $0.writeCount > 0 }
        await adapter.stopWatching()

        XCTAssertTrue(delivered, "a token-less append must report a local write")
        let count = await collector.count
        XCTAssertEqual(count, 0, "a mid-turn line carries no usage — it must add no TokenEvent")
        let signals = await collector.signalCount
        XCTAssertEqual(signals, 0, "liveness must not travel as a meaningful delta (no tripwire)")
    }

    /// The whole 2026-09-03 turn, appended the way Codex writes one: ten token-less lines over the
    /// working span, then the `token_count` half an hour later. Every append reports a local write,
    /// none of the first ten adds a `TokenEvent`, and the last one adds exactly one — the seam the
    /// tester's "idle here, working elsewhere" complaint turned on, driven from a committed fixture
    /// rather than a one-off harness (STEP_173).
    func testWholeLateTokenTurnReportsWritesThroughoutAndOneEventAtTheEnd() async throws {
        let (root, file) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fixture = try XCTUnwrap(Bundle.module.url(
            forResource: "codex_local_late_token_count", withExtension: "jsonl"))
        // Line 1 is the session_meta the temp file already carries; replay the rest as appends.
        let body = try String(contentsOf: fixture, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true).dropFirst()

        let adapter = CodexLocalAdapter(roots: [root], debounceInterval: .milliseconds(50))
        let collector = Collector()
        let writes = Task { for await w in adapter.localWrites { await collector.add(w) } }
        let tokens = Task { for await b in adapter.tokenEvents { await collector.add(b) } }
        defer { writes.cancel(); tokens.cancel() }

        await adapter.startWatching()
        for (index, line) in body.enumerated() {
            try append(String(line) + "\n", to: file)
            await adapter.flush()
            let delivered = await waitFor(collector, timeout: 3) { await $0.writeCount > index }
            XCTAssertTrue(delivered, "append \(index + 1) must report a local write")
            if index < body.count - 1 {
                let count = await collector.count
                XCTAssertEqual(count, 0,
                               "line \(index + 1) carries no token accounting — it must add no event")
            }
        }
        await adapter.stopWatching()

        let count = await collector.count
        XCTAssertEqual(count, 1, "only the closing token_count is usage")
    }

    /// Regression: a `session_meta` line longer than the old bounded 8192-byte first-line read
    /// (real Codex Desktop sessions embed instructions and run ~20 KB). The originator must still
    /// resolve — otherwise events fall back to the `Unknown` surface bucket even though line 1
    /// names the surface (dogfood: active session showed "Active surface: Unknown").
    func testLargeSessionMetaResolvesOriginator() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aptest-codex-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Inflate line 1 past 8192 bytes with a large (ignored) instructions field, exactly as a
        // real Codex Desktop session_meta does; originator/source still name the IDE-extension surface.
        let filler = String(repeating: "x", count: 16_000)
        let bigMeta = #"{"type":"session_meta","payload":{"originator":"codex_vscode","source":"vscode","instructions":"\#(filler)"}}"# + "\n"
        XCTAssertGreaterThan(bigMeta.utf8.count, 8192, "meta line must exceed the old read bound")
        let file = sessionsDir.appendingPathComponent("rollout.jsonl")
        try Data(bigMeta.utf8).write(to: file)

        let adapter = CodexLocalAdapter(roots: [root], debounceInterval: .milliseconds(50))
        let collector = Collector()
        let consumer = Task { for await b in adapter.tokenEvents { await collector.add(b) } }
        defer { consumer.cancel() }

        await adapter.startWatching()
        try append(tokenCountLine, to: file)
        var delivered = await waitFor(collector, timeout: 3) { await $0.count > 0 }
        if !delivered {
            await adapter.flush()
            delivered = await waitFor(collector, timeout: 2) { await $0.count > 0 }
        }
        await adapter.stopWatching()

        XCTAssertTrue(delivered, "watcher did not emit a TokenEvent")
        let events = await collector.events
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.surfaceBucket, "IDE extension",
                       "large session_meta line 1 must still resolve the surface, not fall back to Unknown")
        XCTAssertEqual(event.originator, "codex_vscode")
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
