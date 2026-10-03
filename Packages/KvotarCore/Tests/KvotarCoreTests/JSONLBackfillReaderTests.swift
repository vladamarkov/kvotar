import XCTest
@testable import KvotarCore

/// STEP_95 sweep machinery in isolation: candidate selection (mtime vs cutoff), chunked reading
/// with line-boundary splitting, batching, vanished files, and insert accounting. The parse
/// closure is a trivial line-counter — the real parsers are exercised in the adapter targets.
final class JSONLBackfillReaderTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aptest-backfill-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        root = nil
        super.tearDown()
    }

    private func writeFile(_ name: String, lines: [String], mtime: Date? = nil,
                           terminated: Bool = true) throws -> URL {
        let url = root.appendingPathComponent(name)
        var content = lines.joined(separator: "\n")
        if terminated, !lines.isEmpty { content += "\n" }
        try Data(content.utf8).write(to: url)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
        return url
    }

    /// One synthetic event per newline-complete line handed to `parse`.
    private static func lineEvents(_ data: Data, path: String) -> [TokenEvent] {
        String(data: data, encoding: .utf8)!
            .split(separator: "\n")
            .map { line in
                TokenEvent(tool: .claude, sessionId: (path as NSString).lastPathComponent,
                           surfaceBucket: "Claude Code", inputTokens: 1, outputTokens: 0,
                           cacheCreationTokens: 0, cacheReadTokens: 0,
                           recordedAt: Date(timeIntervalSince1970: 1_800_000_000),
                           dedupKey: String(line))
            }
    }

    /// Accepts everything and reports it inserted, recording batch shapes.
    private actor AcceptAllWriter {
        private(set) var batches: [[TokenEvent]] = []
        func write(_ events: [TokenEvent]) -> JSONLBackfillReader.WriteCounts {
            batches.append(events)
            return .init(inserted: events.count,
                         insertedTokens: events.reduce(0) { $0 + $1.inputTokens })
        }
        var batchSizes: [Int] { batches.map(\.count) }
        var allKeys: [String] { batches.flatMap { $0 }.map(\.dedupKey) }
    }

    func testCutoffExcludesOldFilesAndIncludesNewOnes() async throws {
        let cutoff = Date(timeIntervalSinceNow: -3600)
        _ = try writeFile("old.jsonl", lines: ["o1", "o2"],
                          mtime: cutoff.addingTimeInterval(-60))
        _ = try writeFile("new.jsonl", lines: ["n1", "n2"],
                          mtime: cutoff.addingTimeInterval(60))

        let writer = AcceptAllWriter()
        let summary = await JSONLBackfillReader(root: root).run(
            cutoff: cutoff,
            parse: { data, path, _ in Self.lineEvents(data, path: path) },
            write: { await writer.write($0) })

        XCTAssertEqual(summary.filesScanned, 1, "only the file touched after the cutoff is a candidate")
        XCTAssertEqual(summary.eventsParsed, 2)
        let keys = await writer.allKeys
        XCTAssertEqual(Set(keys), ["n1", "n2"])
    }

    func testChunkBoundarySplitsAtNewlinesOnly() async throws {
        // Lines far longer than the chunk size: every read ends mid-line, so the reader must
        // carry the partial tail across chunks or the parse closure sees torn JSON.
        let lines = (0..<5).map { "line-\($0)-" + String(repeating: "x", count: 100) }
        _ = try writeFile("big.jsonl", lines: lines)

        let writer = AcceptAllWriter()
        let summary = await JSONLBackfillReader(root: root, chunkSize: 16).run(
            cutoff: .distantPast,
            parse: { data, path, _ in Self.lineEvents(data, path: path) },
            write: { await writer.write($0) })

        XCTAssertEqual(summary.eventsParsed, 5)
        let keys = await writer.allKeys
        XCTAssertEqual(keys, lines, "each line must arrive whole and in order")
    }

    func testUnterminatedFinalLineIsNotDelivered() async throws {
        // A missing trailing newline is a write in progress — the live watcher owns that tail.
        _ = try writeFile("tail.jsonl", lines: ["done", "partial"], terminated: false)

        let writer = AcceptAllWriter()
        let summary = await JSONLBackfillReader(root: root).run(
            cutoff: .distantPast,
            parse: { data, path, _ in Self.lineEvents(data, path: path) },
            write: { await writer.write($0) })

        XCTAssertEqual(summary.eventsParsed, 1)
        let keys = await writer.allKeys
        XCTAssertEqual(keys, ["done"])
    }

    func testBatchesAreCappedAtMaxBatchEvents() async throws {
        _ = try writeFile("many.jsonl", lines: (0..<5).map { "e\($0)" })

        let writer = AcceptAllWriter()
        let summary = await JSONLBackfillReader(root: root, maxBatchEvents: 2).run(
            cutoff: .distantPast,
            parse: { data, path, _ in Self.lineEvents(data, path: path) },
            write: { await writer.write($0) })

        XCTAssertEqual(summary.eventsInserted, 5)
        XCTAssertEqual(summary.insertedTokens, 5)
        let sizes = await writer.batchSizes
        XCTAssertEqual(sizes, [2, 2, 1], "no write call may exceed the batch cap")
    }

    func testVanishedCandidateIsSkippedNotFatal() async throws {
        // Codex deletes old rollout files (39 DB rows already reference such files — task 3).
        // Newest-first ordering makes the first file's parse a hook to delete the second before
        // the reader opens it: exactly the discovery-to-read race the sweep must survive.
        let newer = Date(), older = Date(timeIntervalSinceNow: -60)
        _ = try writeFile("first.jsonl", lines: ["a"], mtime: newer)
        let victim = try writeFile("second.jsonl", lines: ["b"], mtime: older)

        let writer = AcceptAllWriter()
        let summary = await JSONLBackfillReader(root: root).run(
            cutoff: .distantPast,
            parse: { data, path, _ in
                try? FileManager.default.removeItem(at: victim)
                return Self.lineEvents(data, path: path)
            },
            write: { await writer.write($0) })

        XCTAssertEqual(summary.filesScanned, 1)
        XCTAssertEqual(summary.filesVanished, 1)
        XCTAssertEqual(summary.eventsParsed, 1)
        let keys = await writer.allKeys
        XCTAssertEqual(keys, ["a"], "the sweep completes without the vanished file")
    }

    /// STEP_117 / REV-71 §3.1: the sweep must cover **every** root the watcher watches. Codex has
    /// two since the narrowing, and a single-root sweep would silently stop recovering pre-launch
    /// bytes from `~/.codex/archived_sessions` while the watcher still watched it. Ordering is
    /// newest-first across the combined set, not per root.
    func testSweepCoversEveryRootNewestFirst() async throws {
        let second = FileManager.default.temporaryDirectory
            .appendingPathComponent("aptest-backfill-archived-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: second) }

        // Oldest in root, newest in the second root, middle in root — so a per-root sort would
        // produce a different order from the combined one.
        _ = try writeFile("middle.jsonl", lines: ["m"], mtime: Date(timeIntervalSince1970: 2_000))
        _ = try writeFile("oldest.jsonl", lines: ["o"], mtime: Date(timeIntervalSince1970: 1_000))
        let newest = second.appendingPathComponent("newest.jsonl")
        try Data("n\n".utf8).write(to: newest)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 3_000)], ofItemAtPath: newest.path)

        let writer = AcceptAllWriter()
        let summary = await JSONLBackfillReader(roots: [root, second]).run(
            cutoff: .distantPast,
            parse: { data, path, _ in Self.lineEvents(data, path: path) },
            write: { await writer.write($0) })

        XCTAssertEqual(summary.filesScanned, 3, "files under either root are candidates")
        let keys = await writer.allKeys
        XCTAssertEqual(keys, ["n", "m", "o"], "newest-first across the combined candidate set")
    }

    func testFailedWriteDoesNotAbortSweep() async throws {
        _ = try writeFile("one.jsonl", lines: ["a", "b"])

        let summary = await JSONLBackfillReader(root: root).run(
            cutoff: .distantPast,
            parse: { data, path, _ in Self.lineEvents(data, path: path) },
            write: { _ in nil })   // store error → nil; next launch's re-sweep retries

        XCTAssertEqual(summary.eventsParsed, 2)
        XCTAssertEqual(summary.eventsInserted, 0)
        XCTAssertEqual(summary.insertedTokens, 0)
    }
}
