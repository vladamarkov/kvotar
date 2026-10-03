import Foundation
import KvotarCore

/// Codex local JSONL adapter (Baseline §8.4, §8.5, task Step 11).
///
/// Watches Codex's session-log trees for new/appended logs, parses `payload.type == "token_count"`
/// events via `CodexJSONLParser`, and emits normalized `TokenEvent`s on `tokenEvents`. It is a
/// pure reporter: it never writes to `SQLiteStore` (ARCHITECTURE.md §Adapter protocols) — a
/// future consumer persists the stream via `SQLiteStore.writeTokenEvents(_:)`.
///
/// The shared filesystem plumbing (recursive directory watching, per-file `DispatchSource`s, offset
/// tracking, partial-line carry, fd bound, debounce) lives in `JSONLDirectoryWatcher` (STEP_24);
/// this adapter injects only its Codex-specific behavior.
///
/// **Differences from Claude:** originator/source live only on line 1 of each file
/// (`session_meta`, §8.4), not on every event — `fileOriginators` caches the resolved
/// `(originator, surfaceBucket)` pair per file, populated once via the watcher's `onNewFile` hook.
/// `fileMetadata` caches the `state_5.sqlite` model/cwd lookup (§8.5). Both are cleared via the
/// watcher's `onEvict` hook when a file is deleted/renamed. Codex has no subagent concept, so the
/// subagent-count delta never fires; surface-bucket change, burn-tier crossing, and quota-429
/// observation (working-assumption shape — see `CodexJSONLParser.detectQuota429`) all do.
///
/// `actor` because it owns the delta state, the per-file caches, and the stream continuations
/// touched from the watcher's callbacks.
public actor CodexLocalAdapter: LocalAdapter {

    /// Default JSONL roots (Baseline §5.3). Overridable for tests.
    ///
    /// **Two roots, not `~/.codex` itself (STEP_117 / REV-71 §3.1).** Watching the whole state
    /// folder cost one file handle per directory in it, including trees that can never hold a
    /// session log: on 2026-08-17 that was 2,551 directories, 2,056 of them a `node_modules` tree
    /// a Codex session had scaffolded inside `~/.codex/visualizations` that morning. It exhausted
    /// the process's ≈2,560-handle table, and every subsequent failure to open *anything* — both
    /// credential reads, the `which codex` lookup, Claude's own watcher — was then reported to the
    /// user as "this tool is not set up". Walking only the two trees that hold rollout files takes
    /// the count to ~51.
    ///
    /// **`archived_sessions` is load-bearing and nearly got dropped.** It holds three rollout
    /// files on the dogfood machine, one of which (`rollout-2026-06-03T18-04-22-…`) has 6 stored
    /// usage rows. Narrowing to `sessions/` alone would have silently amputated a real source.
    public static func defaultRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
        ]
    }

    private let parser: CodexJSONLParser
    private let metadataReader: CodexSQLiteMetadataReader
    private let watcher: JSONLDirectoryWatcher
    /// The watched roots, kept for the STEP_95 backfill sweep (the watcher holds its copy
    /// privately). Immutable and Sendable, so the nonisolated sweep can read them.
    private let jsonlRoots: [URL]

    /// Per-file resolved origination, captured once from line 1 (see type doc). `forkMarkerAt`
    /// is the `session_meta` line's own timestamp when it carries a fork marker (STEP_103) —
    /// the anchor for the parser's inherited-history drop window — and `nil` otherwise.
    private var fileOriginators:
        [String: (originator: String, surfaceBucket: String, forkMarkerAt: Date?)] = [:]
    /// Per-file `state_5.sqlite` lookup (task Step 12, §8.5). Refreshed on every flush — `threads.model`
    /// changes when the user switches model mid-session, so this holds the *last resolved* value only
    /// as a fallback for a transient miss (the row can be briefly absent/locked while Codex writes),
    /// not as a permanent cache.
    private var fileMetadata: [String: CodexSQLiteMetadataReader.ThreadMetadata] = [:]

    /// Last `turn_context` model seen per file (STEP_93). Codex writes the per-turn model on
    /// `turn_context` lines; a debounced flush (or 1 MiB backfill chunk) may contain token events
    /// whose `turn_context` arrived in an earlier read of the same file, so the parser's
    /// last-seen model is carried here across reads. Cleared on evict with the other caches.
    private var fileTurnContextModel: [String: String] = [:]

    /// Highest cumulative `total_token_usage.total_tokens` seen per file — the STEP_94
    /// re-emission guard's carry across debounced flushes. The live watcher only ever reads
    /// forward from its stored offset, so this value never regresses for a live path.
    private var fileCumulativeTotal: [String: Int] = [:]

    /// The backfill's own cumulative carry, deliberately **separate** from the live one: a
    /// backfill re-reads files from byte 0, and judging those bytes against a live carry
    /// already at end-of-file would drop every event as "not advanced". Reset at each file's
    /// first chunk (`isFirstChunk`) so consecutive sweeps over the same file start clean.
    private var backfillCumulativeTotal: [String: Int] = [:]

    // Delta tracking (cumulative for the adapter's lifetime).
    private var seenSurfaceBuckets: Set<String> = []
    private var burnTier = BurnTierTracker()
    /// Quota-429 observations collected during `parse` (per path), drained by the flush's delta.
    private var pendingQuota429s: [Quota429Observation] = []

    // Streams.
    public nonisolated let tokenEvents: AsyncStream<[TokenEvent]>
    private let tokenContinuation: AsyncStream<[TokenEvent]>.Continuation
    public nonisolated let deltaSignals: AsyncStream<LocalDeltaSignal>
    private let deltaContinuation: AsyncStream<LocalDeltaSignal>.Continuation
    public nonisolated let localWrites: AsyncStream<Date>
    private let writeContinuation: AsyncStream<Date>.Continuation

    public init(
        roots: [URL]? = nil,
        metadataReader: CodexSQLiteMetadataReader = CodexSQLiteMetadataReader(),
        debounceInterval: DispatchTimeInterval = .seconds(5),
        diagnostics: DiagnosticsSink? = nil
    ) {
        self.metadataReader = metadataReader
        // Nil sink ⇒ the parser behaves exactly as it did before STEP_72 (every existing test).
        self.parser = CodexJSONLParser(
            onAnomaly: diagnostics.map { sink in { sink.recordAnomaly($0) } })
        let resolvedRoots = roots ?? Self.defaultRoots()
        self.jsonlRoots = resolvedRoots
        self.watcher = JSONLDirectoryWatcher(
            roots: resolvedRoots,
            component: .codexLocalAdapter,
            debounceInterval: debounceInterval)
        (tokenEvents, tokenContinuation) = AsyncStream.makeStream(of: [TokenEvent].self)
        (deltaSignals, deltaContinuation) = AsyncStream.makeStream(of: LocalDeltaSignal.self)
        (localWrites, writeContinuation) = AsyncStream.makeStream(of: Date.self)
    }

    // MARK: - LocalAdapter

    public func startWatching() async {
        await watcher.start(
            onNewFile: { [weak self] path in await self?.captureOriginator(path) },
            onEvict: { [weak self] path in await self?.dropCaches(path) },
            parse: { [weak self] data, path in await self?.parseEvents(data, path: path) ?? [] },
            onFlush: { [weak self] batch in await self?.emit(batch) }
        )
    }

    public func stopWatching() async {
        await watcher.stop()
    }

    /// Forces a synchronous flush. Public for tests.
    public func flush() async {
        await watcher.flushNow()
    }

    // MARK: - Launch backfill (STEP_95)

    /// One-shot sweep over the bytes the watcher's end-of-file seed skips — see the Claude twin
    /// and `JSONLBackfillReader` for the full contract (token events only; no 429 replay, no
    /// delta emission; `write` persists and reports inserts).
    public nonisolated func backfillEvents(
        since cutoff: Date,
        write: @escaping @Sendable ([TokenEvent]) async -> JSONLBackfillReader.WriteCounts?
    ) async -> JSONLBackfillReader.Summary {
        let reader = JSONLBackfillReader(roots: jsonlRoots)
        return await reader.run(
            cutoff: cutoff,
            parse: { [weak self] data, path, isFirstChunk in
                await self?.backfillParse(data, path: path, isFirstChunk: isFirstChunk) ?? []
            },
            write: write
        )
    }

    /// Session ids (rollout-file basenames) of every file whose `session_meta` carries a fork
    /// marker with a usable timestamp (STEP_103). Read by the one-shot forked-history cleanup
    /// **after** a `backfillEvents` run has visited every file (each visit runs
    /// `captureOriginator`, populating the cache): the sweep must be seeded with these ids
    /// rather than deriving them from parsed events, because a 100%-phantom fork yields *zero*
    /// events under the drop rule — an event-driven collection would never even name it, and
    /// its stored rows would survive.
    public func forkMarkedSessionIds() -> [String] {
        fileOriginators.compactMap { path, resolved in
            resolved.forkMarkerAt != nil ? Self.sessionId(forFilePath: path) : nil
        }
    }

    /// Token events only — no 429 detection, no delta bookkeeping. `captureOriginator` runs
    /// per file (idempotent, cached) because a backfilled file can predate the live watcher's
    /// discovery pass; metadata resolution degrades to a null model exactly as live parsing does
    /// when `state_5.sqlite` no longer holds the thread row.
    private func backfillParse(_ data: Data, path: String, isFirstChunk: Bool) -> [TokenEvent] {
        captureOriginator(path)
        if isFirstChunk { backfillCumulativeTotal[path] = nil }
        let resolved = fileOriginators[path]
        let metadata = resolveMetadata(filePath: path)
        let batch = parser.parseTokenEvents(
            data,
            sessionId: Self.sessionId(forFilePath: path),
            surfaceBucket: resolved?.surfaceBucket ?? CodexJSONLParser.surfaceUnknown,
            originator: resolved?.originator,
            sessionModel: metadata?.model,
            carriedModel: fileTurnContextModel[path],
            carriedCumulativeTotal: backfillCumulativeTotal[path],
            forkMarkerAt: resolved?.forkMarkerAt,
            project: metadata?.cwd,
            sourceFile: (path as NSString).lastPathComponent
        )
        if let model = batch.lastTurnContextModel { fileTurnContextModel[path] = model }
        backfillCumulativeTotal[path] = batch.lastCumulativeTotal
        return batch.events
    }

    // MARK: - Parsing + emission (Codex-specific)

    private func parseEvents(_ data: Data, path: String) -> [TokenEvent] {
        pendingQuota429s.append(contentsOf: parser.detectQuota429(
            data, sourceFile: (path as NSString).lastPathComponent))
        let sessionId = Self.sessionId(forFilePath: path)
        let resolved = fileOriginators[path]
        let metadata = resolveMetadata(filePath: path)
        let batch = parser.parseTokenEvents(
            data,
            sessionId: sessionId,
            surfaceBucket: resolved?.surfaceBucket ?? CodexJSONLParser.surfaceUnknown,
            originator: resolved?.originator,
            sessionModel: metadata?.model,
            carriedModel: fileTurnContextModel[path],
            carriedCumulativeTotal: fileCumulativeTotal[path],
            forkMarkerAt: resolved?.forkMarkerAt,
            project: metadata?.cwd,
            sourceFile: (path as NSString).lastPathComponent
        )
        if let model = batch.lastTurnContextModel { fileTurnContextModel[path] = model }
        fileCumulativeTotal[path] = batch.lastCumulativeTotal
        return batch.events
    }

    private func emit(_ batch: [TokenEvent]) {
        // The watcher calls this only when a watched file gained completed lines (`sawData`), so
        // reaching here *is* the local-write fact — token-bearing or not (STEP_170). Liveness
        // only: no tokens, no tripwire, no turn-boundary hook.
        writeContinuation.yield(Date())
        if !batch.isEmpty { tokenContinuation.yield(batch) }
        emitDelta(for: batch)
    }

    // MARK: - Origination capture (line 1 only, §8.4)

    /// Reads a file's first line directly (independent of append-offset tracking) and caches its
    /// resolved origination. A malformed/missing first line leaves the file uncached — later events
    /// from it fall back to the `Unknown` bucket rather than being dropped. Invoked once per file via
    /// the watcher's `onNewFile` hook.
    private func captureOriginator(_ path: String) {
        guard fileOriginators[path] == nil else { return }
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        // First line only, but session_meta is not always short: it embeds the session's
        // instructions/config and is regularly larger than a single small read (20 KB observed on
        // real data). Accumulate fixed-size chunks until the first newline rather than reading a
        // bounded prefix — a prefix that stops mid-line finds no newline and the originator/surface
        // silently never resolve (session shows the `Unknown` bucket). Cap the scan so a file with
        // no newline at all can't drive an unbounded read.
        var buffer = Data()
        let chunkSize = 64 * 1024
        let scanLimit = 1 << 20   // 1 MiB — far beyond any real session_meta line
        while buffer.count < scanLimit {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            buffer.append(chunk)
            guard let newlineIndex = buffer.firstIndex(of: 0x0A) else { continue }
            let firstLine = buffer[buffer.startIndex..<newlineIndex]
            guard let resolved = parser.parseSessionMeta(Data(firstLine)) else { return }
            fileOriginators[path] = resolved
            return
        }
    }

    /// Clears per-path caches for a deleted/renamed file (watcher `onEvict` hook) so a path that is
    /// later recreated re-resolves its origination and metadata instead of reusing stale values.
    private func dropCaches(_ path: String) {
        fileOriginators[path] = nil
        fileMetadata[path] = nil
        fileTurnContextModel[path] = nil
        fileCumulativeTotal[path] = nil
        backfillCumulativeTotal[path] = nil
    }

    // MARK: - SQLite metadata resolution (`state_5.sqlite`, §8.5, task Step 12)

    /// Looks up `model`/`cwd` for `filePath` from `state_5.sqlite` via `rollout_path` (§8.5 — the
    /// JSONL file basename used as `sessionId` doesn't match `threads.id`, a bare ULID; see
    /// `CodexSQLiteMetadataReader.threadMetadata(rolloutPath:)`). Re-queried on every flush rather
    /// than cached-once: `threads.model` is updated by Codex when the user switches model mid-session,
    /// and a permanently-cached first value leaves the session pinned to the stale model (gpt-5.4
    /// shown after a switch to gpt-5.5, observed on real data). The last resolved value is kept only
    /// as a fallback for a transient miss — the `threads` row may not exist yet, or be momentarily
    /// locked while Codex writes.
    ///
    /// **`state_5.sqlite` is no longer under a watched root** *(corrected STEP_117 — this comment
    /// used to argue that watching it was unnecessary because writes to it triggered the directory
    /// watcher's flush).* It sits at `~/.codex/state_5.sqlite`, outside both narrowed roots. Nothing
    /// is lost: the lookup is re-run on every flush, and flushes are driven by writes to the rollout
    /// files themselves plus the REV-20 45-second rescan.
    private func resolveMetadata(filePath: String) -> CodexSQLiteMetadataReader.ThreadMetadata? {
        if let metadata = metadataReader.threadMetadata(rolloutPath: filePath) {
            fileMetadata[filePath] = metadata
            return metadata
        }
        return fileMetadata[filePath]
    }

    // MARK: - Delta detection (Baseline §13.1 — no subagent concept on Codex; the rest fire)

    private func emitDelta(for batch: [TokenEvent]) {
        let beforeSurfaces = seenSurfaceBuckets.count
        for event in batch {
            seenSurfaceBuckets.insert(event.surfaceBucket)
        }
        let burnCrossed = burnTier.record(
            tokens: batch.reduce(0) { $0 + $1.inputTokens + $1.outputTokens })
        let quota429s = pendingQuota429s
        pendingQuota429s.removeAll()
        let signal = LocalDeltaSignal(
            tool: .codex,
            subagentCountChanged: false,
            surfaceBucketChanged: seenSurfaceBuckets.count != beforeSurfaces,
            burnTierCrossed: burnCrossed,
            quota429Observations: quota429s
        )
        guard signal.isMeaningful else { return }
        deltaContinuation.yield(signal)
    }

    // MARK: - Session identity

    /// Session identity: file basename without extension (§17.1: "file basename for Codex" — not
    /// `session_meta.payload.id`, which is the `state_5.sqlite.threads.id` FK target for Step 12's
    /// SQLite join, out of scope here).
    static func sessionId(forFilePath path: String) -> String {
        (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
    }

    deinit {
        tokenContinuation.finish()
        deltaContinuation.finish()
        writeContinuation.finish()
    }
}
