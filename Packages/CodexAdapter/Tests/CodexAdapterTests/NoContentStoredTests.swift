import XCTest
import SQLite3
import KvotarCore
@testable import CodexAdapter

/// Absolute rule R1 (STEP_239), Codex side — the Claude twin is
/// `ClaudeAdapterTests.NoContentStoredTests`, and the scanning helpers are repeated because test
/// targets cannot share code. A rollout whose prompt, answer, reasoning, tool call, tool output and
/// one undecodable line all carry a marker is ingested on the backfill and the live path, with
/// DEBUG logging and capture on; the marker must reach no table, no log and no ordinary bundle.
final class NoContentStoredTests: XCTestCase {

    private let marker = "R1-MARKER-c0ffee"
    private var root: URL!
    private var dbPath: String!
    private var logBasename: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvotar-r1-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sessions/2026/01/01", isDirectory: true),
            withIntermediateDirectories: true)
        dbPath = root.appendingPathComponent("kvotar.db").path
        logBasename = "r1-codex-\(UUID().uuidString.prefix(8))"
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
        let file = root.appendingPathComponent(
            "sessions/2026/01/01/rollout-2026-01-01T00-00-00-01900000-0000-7000-8000-0000000000aa.jsonl")
        try Data((sessionMeta + turn("a")).utf8).write(to: file)
        let store = try SQLiteStore(path: dbPath)
        let adapter = CodexLocalAdapter(
            roots: [root.appendingPathComponent("sessions")],
            metadataReader: CodexSQLiteMetadataReader(
                statePath: root.appendingPathComponent("state_5.sqlite"),
                goalsPath: root.appendingPathComponent("goals_1.sqlite")),
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
        Logger.info(sentinel, component: .codexLocalAdapter)
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

    private var sessionMeta: String {
        #"{"timestamp":"2026-01-01T00:00:00.000Z","type":"session_meta","payload":{"id":"01900000-0000-7000-8000-0000000000aa","cwd":"/tmp/proj","originator":"codex_cli_rs","source":"cli","thread_source":"user","cli_version":"0.150.0","instructions":"\#(marker) instructions"}}"# + "\n"
    }

    /// One turn: the prompt, reasoning, a tool call and its output, the answer, the token count,
    /// and a line the parser cannot decode.
    private func turn(_ id: String) -> String {
        let n = id == "a" ? 1 : 2
        let t = #""timestamp":"2026-01-01T00:0\#(n):00.000Z""#
        return [
            #"{\#(t),"type":"turn_context","payload":{"model":"gpt-5.5","cwd":"/tmp/proj"}}"#,
            #"{\#(t),"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"\#(marker) prompt"}]}}"#,
            #"{\#(t),"type":"event_msg","payload":{"type":"agent_reasoning","text":"\#(marker) reasoning"}}"#,
            #"{\#(t),"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":\"echo \#(marker)\"}","call_id":"c-\#(id)"}}"#,
            #"{\#(t),"type":"response_item","payload":{"type":"function_call_output","call_id":"c-\#(id)","output":"\#(marker) output"}}"#,
            #"{\#(t),"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"\#(marker) answer"}]}}"#,
            #"{\#(t),"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(100 * n),"cached_input_tokens":0,"output_tokens":\#(50 * n),"reasoning_output_tokens":0,"total_tokens":\#(150 * n)},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":50,"reasoning_output_tokens":0,"total_tokens":150}}}}"#,
            #"{\#(t),"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":"\#(marker) not an object"}}}"#,
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
