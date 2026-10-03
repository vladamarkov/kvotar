import XCTest
import SQLite3
import KvotarCore
@testable import ClaudeAdapter

/// Absolute rule R1 (STEP_239): Kvotar never stores prompts, code, transcripts or tool output.
/// A session file whose prompt, answer, tool call, tool output and one undecodable line all carry
/// a marker is ingested on both paths the app uses — the launch backfill and the live watcher —
/// with DEBUG logging and diagnostics capture on, the most a user can turn up. Afterwards the
/// marker is in no cell of any table, not in the log, and not in an ordinary diagnostics bundle.
final class NoContentStoredTests: XCTestCase {

    private let marker = "R1-MARKER-c0ffee"
    private var root: URL!
    private var dbPath: String!
    private var logBasename: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvotar-r1-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("projects/proj", isDirectory: true),
            withIntermediateDirectories: true)
        dbPath = root.appendingPathComponent("kvotar.db").path
        logBasename = "r1-claude-\(UUID().uuidString.prefix(8))"
        Logger.useLogFile(basename: logBasename)
        Logger.setDebugModeEnabled(true)
        DiagnosticsCapture.setEnabled(true)
    }

    override func tearDownWithError() throws {
        DiagnosticsCapture.setEnabled(false)
        Logger.setDebugModeEnabled(false)
        Logger.useLogFile(basename: ProductIdentity.logBasename)
        try? FileManager.default.removeItem(at: Logger.logFileURL(basename: logBasename))
        try? FileManager.default.removeItem(at: root)
    }

    func testConversationContentReachesNoTableLogOrBundle() async throws {
        let file = root.appendingPathComponent("projects/proj/session.jsonl")
        try Data(turn("a").utf8).write(to: file)
        let store = try SQLiteStore(path: dbPath)
        let adapter = ClaudeLocalAdapter(root: root.appendingPathComponent("projects"),
                                         debounceInterval: .milliseconds(50),
                                         diagnostics: LiveDiagnosticsSink(store: store))

        // Launch backfill.
        let summary = await adapter.backfillEvents(since: .distantPast) { events in
            (try? await store.backfillTokenEvents(events)) ?? .init(inserted: 0, insertedTokens: 0)
        }
        XCTAssertGreaterThan(summary.eventsInserted, 0)

        // Live watcher: a second turn appended while the app watches.
        let consumer = Task {
            for await batch in adapter.tokenEvents { try? await store.writeTokenEvents(batch) }
        }
        defer { consumer.cancel() }
        await adapter.startWatching()
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(turn("b").utf8))
        try handle.close()
        await adapter.flush()

        // Wait for every asynchronous write: the live batch, the anomaly rows, the log.
        try await waitUntil { (try? self.count("local_usage_events")) ?? 0 >= 2 }
        try await waitUntil { (try? self.count("parse_anomalies")) ?? 0 >= 1 }
        await adapter.stopWatching()
        let logURL = Logger.logFileURL(basename: logBasename)
        let sentinel = "r1-probe-complete-\(UUID().uuidString)"
        Logger.info(sentinel, component: .claudeLocalAdapter)
        try await waitUntil {
            ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").contains(sentinel)
        }

        for (table, column) in try cellsContaining(marker) {
            XCTFail("R1: content stored in \(table).\(column)")
        }
        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(log.contains(marker), "R1: content written to the log")

        DiagnosticsCapture.setEnabled(false)
        let bundleDirectory = root.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)
        let archive = try await DiagnosticsBundle.build(
            store: store,
            facts: .init(appVersion: "0.0.0 (0)", channel: .release,
                         notificationAuthorization: "authorized", openAtLogin: false),
            logDirectory: Logger.logDirectoryURL, destinationDirectory: bundleDirectory)
        for path in try unzippedFiles(archive) {
            let bytes = try Data(contentsOf: path)
            XCTAssertNil(bytes.range(of: Data(marker.utf8)),
                         "R1: content in the diagnostics bundle at \(path.lastPathComponent)")
        }
    }

    // MARK: - Fixture

    /// One turn: the prompt, an answer with a tool call, the tool's output, and a line the parser
    /// cannot decode (an anomaly, whose *field names* are stored).
    private func turn(_ id: String) -> String {
        let head = #""sessionId":"s1","cwd":"/tmp/proj","timestamp":"2026-07-05T08:00:0\#(id == "a" ? 1 : 2).000Z""#
        return [
            #"{"type":"user",\#(head),"message":{"role":"user","content":"\#(marker) prompt"}}"#,
            #"{"type":"assistant",\#(head),"requestId":"req-\#(id)","isSidechain":false,"message":{"id":"m-\#(id)","model":"claude-sonnet-4-6","content":[{"type":"text","text":"\#(marker) answer"},{"type":"tool_use","id":"t-\#(id)","name":"Bash","input":{"command":"echo \#(marker)"}}],"usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#,
            #"{"type":"user",\#(head),"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t-\#(id)","content":"\#(marker) output"}]},"toolUseResult":{"stdout":"\#(marker) stdout"}}"#,
            #"{"type":"assistant",\#(head),"requestId":"bad-\#(id)","message":{"id":"x-\#(id)","usage":"\#(marker) not an object"}}"#,
        ].joined(separator: "\n") + "\n"
    }

    // MARK: - Scanning

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw NSError(domain: "sqlite", code: 1)
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    private func rows(_ db: OpaquePointer, _ sql: String) -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [[String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((0..<sqlite3_column_count(statement)).map { i in
                sqlite3_column_text(statement, i).map { String(cString: $0) }
            })
        }
        return result
    }

    private func count(_ table: String) throws -> Int {
        try withDatabase { Int(rows($0, "SELECT COUNT(*) FROM \(table)").first?[0] ?? "0") ?? 0 }
    }

    /// Every (table, column) holding `needle` in any row, across every table in the file.
    private func cellsContaining(_ needle: String) throws -> [(String, String)] {
        try withDatabase { db in
            var hits: [(String, String)] = []
            for table in rows(db, "SELECT name FROM sqlite_master WHERE type = 'table'")
                .compactMap({ $0[0] }) {
                let columns = rows(db, "PRAGMA table_info(\"\(table)\")").compactMap { $0[1] }
                for row in rows(db, "SELECT * FROM \"\(table)\"") {
                    for (index, value) in row.enumerated() where value?.contains(needle) == true {
                        hits.append((table, index < columns.count ? columns[index] : "?"))
                    }
                }
            }
            return hits
        }
    }

    private func unzippedFiles(_ archive: URL) throws -> [URL] {
        let out = root.appendingPathComponent("unzipped", isDirectory: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, out.path]
        try ditto.run()
        ditto.waitUntilExit()
        let files = FileManager.default.enumerator(at: out, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath } ?? []
        XCTAssertFalse(files.isEmpty, "the bundle must actually contain files")
        return files
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(condition(), "timed out waiting for an asynchronous write")
    }
}
