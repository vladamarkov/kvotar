import XCTest
import SQLite3
@testable import CodexAdapter

/// Step 12 fixture tests for `CodexSQLiteMetadataReader` (Baseline §8.5; task Step 12).
final class CodexSQLiteMetadataReaderTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-sqlite-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    // MARK: 1 — model/cwd populated from `threads`, keyed by `rollout_path` (the full JSONL file
    // path — confirmed on real data (2026-07-03) that `threads.id`, a bare ULID, does not match
    // the `rollout-<timestamp>-<ulid>` file basename `CodexLocalAdapter` uses as its session ID).

    func testThreadMetadataPopulatedByRolloutPath() throws {
        let statePath = tempDir.appendingPathComponent("state_5.sqlite")
        let rolloutPath = "/Users/dev/.codex/sessions/rollout-2026-07-03T00-00-00-01ABC.jsonl"
        try execSQL(statePath, """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY, rollout_path TEXT, model TEXT, cwd TEXT, source TEXT, git_branch TEXT,
                unrelated_future_column TEXT
            );
            INSERT INTO threads (id, rollout_path, model, cwd, source, git_branch, unrelated_future_column)
            VALUES ('01ABC', '\(rolloutPath)', 'gpt-5.5', '/Users/dev/project', 'cli', 'main', 'ignored');
            """)

        let reader = CodexSQLiteMetadataReader(statePath: statePath, goalsPath: missingPath())
        let metadata = reader.threadMetadata(rolloutPath: rolloutPath)

        XCTAssertEqual(metadata?.model, "gpt-5.5")
        XCTAssertEqual(metadata?.cwd, "/Users/dev/project")
        XCTAssertEqual(metadata?.source, "cli")
        XCTAssertEqual(metadata?.gitBranch, "main")
    }

    // MARK: 2 — unknown rollout path → nil, not an error

    func testThreadMetadataMissingRowReturnsNil() throws {
        let statePath = tempDir.appendingPathComponent("state_5.sqlite")
        try execSQL(statePath, """
            CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, model TEXT, cwd TEXT, source TEXT, git_branch TEXT);
            """)

        let reader = CodexSQLiteMetadataReader(statePath: statePath, goalsPath: missingPath())
        XCTAssertNil(reader.threadMetadata(rolloutPath: "/never/seen.jsonl"))
    }

    // MARK: 3 — empty `thread_goals` is normal, not an error

    func testEmptyThreadGoalsIsNotUsageLimited() throws {
        let goalsPath = tempDir.appendingPathComponent("goals_1.sqlite")
        try execSQL(goalsPath, """
            CREATE TABLE thread_goals (thread_id TEXT PRIMARY KEY, status TEXT);
            """)

        let reader = CodexSQLiteMetadataReader(statePath: missingPath(), goalsPath: goalsPath)
        XCTAssertFalse(reader.hasUsageLimitedGoal())
    }

    // MARK: 4 — `usage_limited` row detected

    func testUsageLimitedRowDetected() throws {
        let goalsPath = tempDir.appendingPathComponent("goals_1.sqlite")
        try execSQL(goalsPath, """
            CREATE TABLE thread_goals (thread_id TEXT PRIMARY KEY, status TEXT);
            INSERT INTO thread_goals (thread_id, status) VALUES ('t1', 'active');
            INSERT INTO thread_goals (thread_id, status) VALUES ('t2', 'usage_limited');
            """)

        let reader = CodexSQLiteMetadataReader(statePath: missingPath(), goalsPath: goalsPath)
        XCTAssertTrue(reader.hasUsageLimitedGoal())
    }

    // MARK: 5 — missing SQLite files → graceful nil/false, never throws

    func testMissingDatabaseFilesFallBackGracefully() {
        let reader = CodexSQLiteMetadataReader(statePath: missingPath(), goalsPath: missingPath())
        XCTAssertNil(reader.threadMetadata(rolloutPath: "/anything.jsonl"))
        XCTAssertFalse(reader.hasUsageLimitedGoal())
    }

    // MARK: 6 — missing table (fresh Codex install) → graceful nil/false

    func testMissingTableFallsBackGracefully() throws {
        let statePath = tempDir.appendingPathComponent("state_5.sqlite")
        try execSQL(statePath, "CREATE TABLE unrelated (id TEXT);")

        let reader = CodexSQLiteMetadataReader(statePath: statePath, goalsPath: missingPath())
        XCTAssertNil(reader.threadMetadata(rolloutPath: "/anything.jsonl"))
    }

    // MARK: 7 — STEP_214: a closed WAL-mode file (no `-wal`/`-shm`) is still read.
    // Codex's databases are WAL-mode; once no process has one open, a plain read-only connection
    // cannot create `-shm` and every query fails with SQLITE_CANTOPEN. Seen live 2026-09-01 → 09-17.

    func testClosedWALGoalsFileIsRead() throws {
        let goalsPath = tempDir.appendingPathComponent("goals_1.sqlite")
        try execSQL(goalsPath, """
            PRAGMA journal_mode=WAL;
            CREATE TABLE thread_goals (thread_id TEXT PRIMARY KEY, status TEXT);
            INSERT INTO thread_goals (thread_id, status) VALUES ('t1', 'usage_limited');
            """)
        assertClosedWALReproducesTheFailure(goalsPath, table: "thread_goals")

        let reader = CodexSQLiteMetadataReader(statePath: missingPath(), goalsPath: goalsPath)
        XCTAssertTrue(reader.hasUsageLimitedGoal())
    }

    func testClosedWALStateFileIsRead() throws {
        let statePath = tempDir.appendingPathComponent("state_5.sqlite")
        let rolloutPath = "/Users/dev/.codex/sessions/rollout-2026-09-17T00-00-00-01DEF.jsonl"
        try execSQL(statePath, """
            PRAGMA journal_mode=WAL;
            CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, model TEXT, cwd TEXT, source TEXT, git_branch TEXT);
            INSERT INTO threads VALUES ('01DEF', '\(rolloutPath)', 'gpt-5.5', '/Users/dev/project', 'cli', 'main');
            """)
        assertClosedWALReproducesTheFailure(statePath, table: "threads")

        let reader = CodexSQLiteMetadataReader(statePath: statePath, goalsPath: missingPath())
        XCTAssertEqual(reader.threadMetadata(rolloutPath: rolloutPath)?.model, "gpt-5.5")
    }

    // MARK: 8 — STEP_214: a closed WAL file with no such table still falls back to nil, not a crash

    func testClosedWALFileMissingTableFallsBackGracefully() throws {
        let statePath = tempDir.appendingPathComponent("state_5.sqlite")
        try execSQL(statePath, "PRAGMA journal_mode=WAL; CREATE TABLE unrelated (id TEXT);")

        let reader = CodexSQLiteMetadataReader(statePath: statePath, goalsPath: missingPath())
        XCTAssertNil(reader.threadMetadata(rolloutPath: "/anything.jsonl"))
    }

    // MARK: 9 — STEP_214: while Codex holds the file open, writes still in the WAL are seen.
    // Guards the order of the two attempts: `immutable=1` first would ignore the WAL and miss them.

    func testOpenWALFileSeesUncheckpointedWrites() throws {
        let goalsPath = tempDir.appendingPathComponent("goals_1.sqlite")
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(goalsPath.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE thread_goals (thread_id TEXT PRIMARY KEY, status TEXT);
            INSERT INTO thread_goals (thread_id, status) VALUES ('t1', 'usage_limited');
            """, nil, nil, nil), SQLITE_OK)

        // The table lives only in the WAL: an immutable read of the main file cannot see it.
        XCTAssertNotEqual(prepareCode(immutableURI(goalsPath), "SELECT 1 FROM thread_goals",
                                      flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI), SQLITE_OK)

        let reader = CodexSQLiteMetadataReader(statePath: missingPath(), goalsPath: goalsPath)
        XCTAssertTrue(reader.hasUsageLimitedGoal())
    }

    // MARK: - Fixture helpers

    /// Proves the fixture is in the broken state the fix targets, so the test can't pass vacuously:
    /// sidecars gone, and a plain read-only query fails with SQLITE_CANTOPEN.
    private func assertClosedWALReproducesTheFailure(_ path: URL, table: String,
                                                     file: StaticString = #filePath, line: UInt = #line) {
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: path.path + "-wal"), "WAL sidecar still present", file: file, line: line)
        XCTAssertFalse(fm.fileExists(atPath: path.path + "-shm"), "SHM sidecar still present", file: file, line: line)
        XCTAssertEqual(prepareCode(path.path, "SELECT 1 FROM \(table)", flags: SQLITE_OPEN_READONLY),
                       SQLITE_CANTOPEN, "plain read-only open no longer fails — fixture no longer reproduces",
                       file: file, line: line)
    }

    private func immutableURI(_ path: URL) -> String {
        URL(fileURLWithPath: path.path).absoluteString + "?immutable=1"
    }

    /// Primary result code of opening `filename` with `flags` and preparing `sql`.
    private func prepareCode(_ filename: String, _ sql: String, flags: Int32) -> Int32 {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        let openCode = sqlite3_open_v2(filename, &db, flags, nil)
        guard openCode == SQLITE_OK else { return openCode & 0xff }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return sqlite3_errcode(db) & 0xff
        }
        return SQLITE_OK
    }

    private func missingPath() -> URL {
        tempDir.appendingPathComponent("does-not-exist-\(UUID().uuidString).sqlite")
    }

    /// Builds a throwaway `.sqlite` fixture via the raw `sqlite3` C API — the same layer
    /// production code reads through, and avoids committing binary fixture files.
    private func execSQL(_ path: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path.path, &db) == SQLITE_OK else {
            XCTFail("failed to create fixture db at \(path.path)")
            return
        }
        defer { sqlite3_close(db) }
        // Apple's system SQLite keeps `-wal`/`-shm` after the last close (persistent WAL); the
        // SQLite Codex bundles deletes them. Match Codex, so a closed WAL fixture has no sidecars.
        var persistWAL: Int32 = 0
        sqlite3_file_control(db, "main", SQLITE_FCNTL_PERSIST_WAL, &persistWAL)
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            XCTFail("fixture SQL failed: \(message)")
            return
        }
    }
}
