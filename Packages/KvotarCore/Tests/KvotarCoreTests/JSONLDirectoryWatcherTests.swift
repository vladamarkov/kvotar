import XCTest
@testable import KvotarCore

/// STEP_24 regression tests for the shared watcher's hardening fixes, driven directly with trivial
/// parse closures (each numeric line → one `TokenEvent` whose `inputTokens` is that number). Covers
/// the three defects that the old per-adapter watchers exhibited: rotated-file re-registration,
/// partial-line loss, and unbounded file-descriptor growth.
final class JSONLDirectoryWatcherTests: XCTestCase {

    private actor Collector {
        private(set) var events: [TokenEvent] = []
        func add(_ batch: [TokenEvent]) { events.append(contentsOf: batch) }
        var count: Int { events.count }
    }

    /// A parse closure turning each complete numeric line into one `TokenEvent`.
    private static func numericParse() -> @Sendable (Data, String) async -> [TokenEvent] {
        { data, _ in
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let n = Int(trimmed) else { return nil }
                return TokenEvent(tool: .claude, sessionId: "s", surfaceBucket: "x",
                                  inputTokens: n, outputTokens: 0, cacheCreationTokens: 0,
                                  cacheReadTokens: 0, recordedAt: Date(), dedupKey: trimmed)
            }
        }
    }

    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aptest-watcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func startWatcher(_ watcher: JSONLDirectoryWatcher, _ collector: Collector) async {
        await watcher.start(
            onNewFile: { _ in }, onEvict: { _ in },
            parse: Self.numericParse(),
            onFlush: { batch in await collector.add(batch) })
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return await condition()
    }

    // MARK: 1 — rotated file (delete + recreate same path) re-registers and is read fresh

    func testRotatedFileIsReReadFromStart() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: Data())  // empty at start

        let watcher = JSONLDirectoryWatcher(root: root, component: .claudeLocalAdapter,
                                            debounceInterval: .milliseconds(50))
        let collector = Collector()
        await startWatcher(watcher, collector)
        defer { Task { await watcher.stop() } }

        // Append a complete line and drain it.
        try appendLine("10", to: file)
        await watcher.flushNow()
        var tokens = await collector.events.map(\.inputTokens)
        XCTAssertEqual(tokens, [10])

        // Delete the file → its per-file source must be evicted (fd released, offset dropped).
        try FileManager.default.removeItem(at: file)
        let evicted = await waitUntil(timeout: 3) { await watcher.fileSourceCount == 0 }
        XCTAssertTrue(evicted, "the deleted file's source was not evicted")

        // Recreate the same path with new content → treated as brand-new, read from byte 0 (the old
        // stale offset must not apply). This is the case the old `guard sources[path]==nil` broke.
        FileManager.default.createFile(atPath: file.path, contents: Data())
        try appendLine("20", to: file)
        await watcher.flushNow()
        tokens = await collector.events.map(\.inputTokens)
        XCTAssertEqual(tokens, [10, 20])
    }

    // MARK: 2 — a JSONL line split across two appends is carried, not dropped

    func testPartialLineIsCarriedAcrossFlushes() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: Data())

        let watcher = JSONLDirectoryWatcher(root: root, component: .claudeLocalAdapter,
                                            debounceInterval: .milliseconds(50))
        let collector = Collector()
        await startWatcher(watcher, collector)
        defer { Task { await watcher.stop() } }

        // Write half a line (no newline) → nothing emitted, the tail is carried.
        try append("4", to: file)
        await watcher.flushNow()
        let partialCount = await collector.count
        XCTAssertEqual(partialCount, 0, "a mid-line flush must not emit or drop the partial line")

        // Complete the line → exactly one event with the full value 42.
        try append("2\n", to: file)
        await watcher.flushNow()
        let tokens = await collector.events.map(\.inputTokens)
        XCTAssertEqual(tokens, [42])
    }

    // MARK: 3 — only active files get a source; historical files cost no fd

    func testHistoricalFilesGetNoSource() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let oldDate = Date().addingTimeInterval(-3600)  // 1h ago — outside the 30-min window
        for i in 0..<300 {
            let path = root.appendingPathComponent("old-\(i).jsonl").path
            FileManager.default.createFile(atPath: path, contents: Data("0\n".utf8))
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: path)
        }
        for i in 0..<5 {
            FileManager.default.createFile(
                atPath: root.appendingPathComponent("live-\(i).jsonl").path, contents: Data("0\n".utf8))
        }

        let watcher = JSONLDirectoryWatcher(root: root, component: .claudeLocalAdapter,
                                            debounceInterval: .milliseconds(50))
        await startWatcher(watcher, Collector())
        defer { Task { await watcher.stop() } }

        // Only the 5 recently-modified files are watched — the 300 historical ones open no fd.
        let sourceCount = await watcher.fileSourceCount
        XCTAssertEqual(sourceCount, 5)
    }

    // MARK: 4 — the source count is capped even when every file is active

    func testFileSourceCountIsCapped() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        for i in 0..<200 {  // all fresh → all active
            FileManager.default.createFile(
                atPath: root.appendingPathComponent("f-\(i).jsonl").path, contents: Data("0\n".utf8))
        }

        let watcher = JSONLDirectoryWatcher(root: root, component: .claudeLocalAdapter,
                                            debounceInterval: .milliseconds(50), maxFileSources: 128)
        await startWatcher(watcher, Collector())
        defer { Task { await watcher.stop() } }

        let sourceCount = await watcher.fileSourceCount
        XCTAssertEqual(sourceCount, 128, "live per-file sources must be capped")
    }

    // MARK: 5 — rescan timer picks up a resumed known-but-unwatched file (REV-20)

    func testRescanPromotesResumedUnwatchedFile() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // A historical session file: known at start (offset seeded to EOF) but unwatched —
        // its mtime is outside the active window.
        let file = root.appendingPathComponent("resumed.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: Data("1\n".utf8))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: file.path)

        let watcher = JSONLDirectoryWatcher(root: root, component: .claudeLocalAdapter,
                                            debounceInterval: .milliseconds(50),
                                            rescanInterval: 0.2)
        let collector = Collector()
        await startWatcher(watcher, collector)
        defer { Task { await watcher.stop() } }
        let watchedAtStart = await watcher.fileSourceCount
        XCTAssertEqual(watchedAtStart, 0, "the historical file must start unwatched")

        // The session resumes: an append to the unwatched file fires no FS event on any watched
        // source (dir vnodes only see entry create/rename/delete). Only the rescan can find it.
        try appendLine("7", to: file)

        let drained = await waitUntil(timeout: 3) { await collector.count > 0 }
        XCTAssertTrue(drained, "rescan did not promote and drain the resumed file")
        let tokens = await collector.events.map(\.inputTokens)
        XCTAssertEqual(tokens, [7], "must resume from the seeded offset — never re-read history")
        let watchedAfter = await watcher.fileSourceCount
        XCTAssertEqual(watchedAfter, 1)
    }

    // MARK: 6 — STEP_117: both Codex roots are walked, and a missing root is survivable

    /// The Codex watcher watches `~/.codex/sessions` **and** `~/.codex/archived_sessions`
    /// (REV-71 §3.1). Both must be discovered and drained by one flush — narrowing to `sessions`
    /// alone would silently amputate the archived tree, which on the dogfood machine holds a
    /// session with 6 stored usage rows.
    func testBothRootsAreDiscoveredAndDrained() async throws {
        let live = try tempRoot()
        let archived = try tempRoot()
        defer {
            try? FileManager.default.removeItem(at: live)
            try? FileManager.default.removeItem(at: archived)
        }
        let liveFile = live.appendingPathComponent("live.jsonl")
        let archivedFile = archived.appendingPathComponent("archived.jsonl")
        FileManager.default.createFile(atPath: liveFile.path, contents: Data())
        FileManager.default.createFile(atPath: archivedFile.path, contents: Data())

        let collector = Collector()
        let watcher = JSONLDirectoryWatcher(roots: [live, archived], component: .codexLocalAdapter,
                                            debounceInterval: .milliseconds(50))
        await startWatcher(watcher, collector)
        defer { Task { await watcher.stop() } }

        try appendLine("11", to: liveFile)
        try appendLine("22", to: archivedFile)
        await watcher.flushNow()

        let tokens = await collector.events.map(\.inputTokens).sorted()
        XCTAssertEqual(tokens, [11, 22], "one flush must drain appends under either root")
        let watched = await watcher.fileSourceCount
        XCTAssertEqual(watched, 2, "one per-file source per root")
    }

    /// A root that does not exist is normal (a machine that has never archived a Codex session has
    /// no `~/.codex/archived_sessions`) and must not stop the other root from working.
    func testMissingRootDoesNotDisableTheOtherRoot() async throws {
        let live = try tempRoot()
        defer { try? FileManager.default.removeItem(at: live) }
        let absent = live.appendingPathComponent("no-such-root", isDirectory: true)
        let file = live.appendingPathComponent("live.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: Data())

        let collector = Collector()
        let watcher = JSONLDirectoryWatcher(roots: [absent, live], component: .codexLocalAdapter,
                                            debounceInterval: .milliseconds(50))
        await startWatcher(watcher, collector)
        defer { Task { await watcher.stop() } }

        try appendLine("5", to: file)
        await watcher.flushNow()

        let tokens = await collector.events.map(\.inputTokens)
        XCTAssertEqual(tokens, [5], "the surviving root must still be watched and drained")
    }

    // MARK: helpers

    private func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func appendLine(_ text: String, to file: URL) throws {
        try append(text + "\n", to: file)
    }
}
