import Foundation
import SQLite3
import KvotarCore

/// Read-only reader for Codex-owned SQLite databases in `~/.codex/` (Baseline §8.5, task
/// Step 12): `state_5.sqlite` (`threads`) and `goals_1.sqlite` (`thread_goals`).
///
/// These are *not* Kvotar's own database — they're index files Codex itself maintains.
/// `SQLiteStore` (ARCHITECTURE.md §SQLite access) owns the only GRDB `DatabasePool` in the
/// codebase and is scoped to `kvotar.db`; it has no notion of a second, foreign,
/// externally-written file. This reader talks to `sqlite3` directly instead, opening
/// read-only and closing per call — polling cadence (≥45s, §9) makes a persistent
/// connection unnecessary, and it sidesteps holding a lock against Codex's own writer.
///
/// **Both files are WAL-mode, and a closed one cannot be read plainly** *(STEP_214)*. When no
/// Codex process has the file open, the `-wal`/`-shm` sidecars are gone, and a read-only
/// connection cannot create `-shm`: the open succeeds, then every query fails with
/// `SQLITE_CANTOPEN` ("unable to open database file"). That was the steady state from at least
/// 2026-09-01 to 2026-09-17 — 200–800 silent DEBUG failures a day, the `usage_limited` signal
/// effectively never read. See `prepareReadOnly` for the two-attempt open.
///
/// Selects named columns only (never `SELECT *`) so unrecognized additional columns or
/// tables in either database (§8.5 "tolerate additional columns and tables silently") never
/// affect parsing. A missing file, missing table, or any query failure returns a nil/false
/// result rather than throwing — callers fall back to JSONL-only behavior.
public struct CodexSQLiteMetadataReader: Sendable {

    /// Subset of `threads` columns used by Kvotar (§8.5). `model` here is one mutable value
    /// per thread — the session-level **fallback** since STEP_93: the per-turn model lives on
    /// JSONL `turn_context` lines (`payload.model`, REV-62 §4.3 — the old claim that it was
    /// absent from JSONL was wrong), and this value covers files predating `turn_context` plus
    /// events before the first `turn_context` the parser has seen. Still absent from RPC/wham.
    public struct ThreadMetadata: Sendable, Equatable {
        public let model: String?
        public let cwd: String?
        public let source: String?
        public let gitBranch: String?
    }

    /// Default `state_5.sqlite` path (Baseline §5.3).
    public static func defaultStatePath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/state_5.sqlite")
    }

    /// Default `goals_1.sqlite` path (Baseline §5.3).
    public static func defaultGoalsPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/goals_1.sqlite")
    }

    private let statePath: URL
    private let goalsPath: URL

    public init(statePath: URL? = nil, goalsPath: URL? = nil) {
        self.statePath = statePath ?? Self.defaultStatePath()
        self.goalsPath = goalsPath ?? Self.defaultGoalsPath()
    }

    /// Looks up `threads` metadata by `rollout_path` — the full JSONL file path (Baseline §8.5).
    /// This is the correlation key, not `id`: `threads.id` is a bare ULID (`01900000-...`), while
    /// the JSONL file basename `CodexLocalAdapter` uses as `local_sessions.session_id` is
    /// `rollout-<timestamp>-<ulid>` — confirmed on real data (2026-07-03) that these never match.
    /// `rollout_path` is Codex's own full path to the file, which `CodexLocalAdapter` already has.
    /// Returns `nil` when the database file is missing, the table doesn't exist yet, or no row
    /// matches — task Step 12's "if SQLite unavailable" fallback.
    public func threadMetadata(rolloutPath: String) -> ThreadMetadata? {
        let sql = "SELECT model, cwd, source, git_branch FROM threads WHERE rollout_path = ? LIMIT 1"
        guard let prepared = prepareReadOnly(statePath, sql: sql, context: "threads") else { return nil }
        defer { prepared.close() }
        let statement = prepared.statement
        sqlite3_bind_text(statement, 1, rolloutPath, -1, Self.transient)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return ThreadMetadata(
            model: columnText(statement, 0),
            cwd: columnText(statement, 1),
            source: columnText(statement, 2),
            gitBranch: columnText(statement, 3)
        )
    }

    /// True when `thread_goals` has any row with `status = 'usage_limited'` (Baseline §8.5 —
    /// secondary over-quota signal). An empty or missing table is the normal case, not an
    /// error — never logged above DEBUG.
    public func hasUsageLimitedGoal() -> Bool {
        let sql = "SELECT 1 FROM thread_goals WHERE status = 'usage_limited' LIMIT 1"
        guard let prepared = prepareReadOnly(goalsPath, sql: sql, context: "thread_goals") else { return false }
        defer { prepared.close() }
        return sqlite3_step(prepared.statement) == SQLITE_ROW
    }

    // MARK: - Helpers

    /// `SQLITE_TRANSIENT` — tells sqlite3 to copy the bound string rather than assume it
    /// outlives the call (no C macro import for this constant in Swift).
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// An open connection with `sql` prepared on it. The caller owns both handles.
    private struct Prepared {
        let db: OpaquePointer
        let statement: OpaquePointer

        func close() {
            sqlite3_finalize(statement)
            sqlite3_close(db)
        }
    }

    /// Opens `url` read-only and prepares `sql`, in up to two attempts *(STEP_214)*:
    ///
    /// 1. **Plain read-only.** Works whenever a Codex process has the file open (the sidecars
    ///    exist), and it is the only mode that sees writes still sitting in the WAL.
    /// 2. **`immutable=1`, only on `SQLITE_CANTOPEN`.** That error means the sidecars are gone,
    ///    so Codex closed the file and checkpointed everything into it: the main file is the
    ///    whole truth and needs no locking. Never tried first — while Codex is writing, immutable
    ///    would ignore the WAL and could read a half-checkpointed page.
    ///
    /// Any other failure (missing table, corrupt file) is logged at DEBUG and returns nil, as before.
    private func prepareReadOnly(_ url: URL, sql: String, context: String) -> Prepared? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        switch Self.prepare(sql, filename: url.path, flags: SQLITE_OPEN_READONLY) {
        case .success(let prepared):
            return prepared
        case .failure(let code, let message) where code != SQLITE_CANTOPEN:
            logQueryFailure(message, context: context)
            return nil
        case .failure:
            break
        }

        let immutableURI = URL(fileURLWithPath: url.path).absoluteString + "?immutable=1"
        switch Self.prepare(sql, filename: immutableURI, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI) {
        case .success(let prepared):
            return prepared
        case .failure(_, let message):
            logQueryFailure(message, context: context)
            return nil
        }
    }

    private enum PrepareResult {
        case success(Prepared)
        /// `code` is the primary result code (extended bits masked off).
        case failure(code: Int32, message: String)
    }

    private static func prepare(_ sql: String, filename: String, flags: Int32) -> PrepareResult {
        var db: OpaquePointer?
        let openCode = sqlite3_open_v2(filename, &db, flags, nil)
        guard let db else { return .failure(code: openCode, message: "out of memory") }
        guard openCode == SQLITE_OK else {
            let failure = PrepareResult.failure(code: openCode & 0xff, message: String(cString: sqlite3_errmsg(db)))
            sqlite3_close(db)
            return failure
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let failure = PrepareResult.failure(
                code: sqlite3_errcode(db) & 0xff, message: String(cString: sqlite3_errmsg(db)))
            sqlite3_close(db)
            return failure
        }
        return .success(Prepared(db: db, statement: statement))
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private func logQueryFailure(_ message: String, context: String) {
        Logger.debug("Codex SQLite query unavailable", component: .codexLocalAdapter,
                     metadata: ["table": context, "error": message])
    }
}
