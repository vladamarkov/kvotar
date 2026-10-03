import Foundation
import KvotarCore

/// Claude Code local JSONL adapter (Baseline §7.2, task Step 7).
///
/// Watches `~/.claude/projects/` for new/appended session logs, parses `type == "assistant"`
/// events via `ClaudeJSONLParser`, and emits normalized `TokenEvent`s on `tokenEvents`. It is a
/// pure reporter: it never writes to `SQLiteStore` (ARCHITECTURE.md §Adapter protocols) — a
/// future consumer persists the stream via `SQLiteStore.writeTokenEvents(_:)`.
///
/// A companion `deltaSignals` stream carries the "meaningful JSONL delta" trigger (Baseline §13.1):
/// subagent-count change, surface-bucket change, burn-tier crossing (`BurnTierTracker`), and
/// quota-429 observation (working-assumption shape — see `ClaudeJSONLParser.detectQuota429`).
///
/// The shared filesystem plumbing (recursive directory watching, per-file `DispatchSource`s, offset
/// tracking, partial-line carry, fd bound, debounce) lives in `JSONLDirectoryWatcher` (STEP_24);
/// this adapter injects only its Claude-specific parsing and delta rule. `actor` because it owns the
/// delta state and stream continuations touched from the watcher's callbacks.
public actor ClaudeLocalAdapter: LocalAdapter {

    /// Default JSONL root (Baseline §5.3). Overridable for tests.
    public static func defaultRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    private let parser: ClaudeJSONLParser
    private let watcher: JSONLDirectoryWatcher
    /// The watched root, kept for the STEP_95 backfill sweep (the watcher holds its copy
    /// privately). Immutable and Sendable, so the nonisolated sweep can read it.
    private let jsonlRoot: URL

    // Delta tracking (cumulative for the adapter's lifetime).
    private var seenSurfaceBuckets: Set<String> = []
    private var seenSubagentBuckets: Set<String> = []
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

    public init(root: URL? = nil, debounceInterval: DispatchTimeInterval = .seconds(5),
                diagnostics: DiagnosticsSink? = nil) {
        // Nil sink ⇒ the parser behaves exactly as it did before STEP_72 (every existing test).
        self.parser = ClaudeJSONLParser(
            onAnomaly: diagnostics.map { sink in { sink.recordAnomaly($0) } })
        let resolvedRoot = root ?? Self.defaultRoot()
        self.jsonlRoot = resolvedRoot
        self.watcher = JSONLDirectoryWatcher(
            root: resolvedRoot,
            component: .claudeLocalAdapter,
            debounceInterval: debounceInterval)
        (tokenEvents, tokenContinuation) = AsyncStream.makeStream(of: [TokenEvent].self)
        (deltaSignals, deltaContinuation) = AsyncStream.makeStream(of: LocalDeltaSignal.self)
        (localWrites, writeContinuation) = AsyncStream.makeStream(of: Date.self)
    }

    // MARK: - LocalAdapter

    public func startWatching() async {
        await watcher.start(
            onNewFile: { _ in },
            onEvict: { _ in },
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

    /// One-shot sweep over the bytes the watcher's end-of-file seed skips: every file touched
    /// after `cutoff` is re-read from byte 0 and parsed for **token events only**. `write`
    /// persists a batch and reports what it actually inserted (`SQLiteStore.backfillTokenEvents`
    /// — the adapter stays a pure reporter and never writes the store itself).
    ///
    /// `nonisolated` so the sweep runs on the caller's `.utility` task, not this actor — only
    /// `backfillParse` hops on, one chunk at a time, so live flushes interleave freely.
    ///
    /// Deliberately absent (see `JSONLBackfillReader`): `detectQuota429` (a historic 429 would
    /// pair with *today's* utilization in `quota_limit_events` and pollute the §9.4 self-learning
    /// ceiling) and the `emit`/delta path (a historic burst must not fire the JSONL tripwire,
    /// cross burn tiers, or arm the STEP_77 alignment timer).
    public nonisolated func backfillEvents(
        since cutoff: Date,
        write: @escaping @Sendable ([TokenEvent]) async -> JSONLBackfillReader.WriteCounts?
    ) async -> JSONLBackfillReader.Summary {
        let reader = JSONLBackfillReader(root: jsonlRoot)
        return await reader.run(
            cutoff: cutoff,
            // The first-chunk flag serves per-file carry state; Claude parsing has none.
            parse: { [weak self] data, path, _ in await self?.backfillParse(data, path: path) ?? [] },
            write: write
        )
    }

    /// Token events only — no 429 detection, no `pendingQuota429s`, no delta bookkeeping.
    private func backfillParse(_ data: Data, path: String) -> [TokenEvent] {
        parser.parse(data, sourceFile: (path as NSString).lastPathComponent)
    }

    // MARK: - Parsing + emission (Claude-specific)

    private func parseEvents(_ data: Data, path: String) -> [TokenEvent] {
        pendingQuota429s.append(contentsOf: parser.detectQuota429(
            data, sourceFile: (path as NSString).lastPathComponent))
        return parser.parse(data, sourceFile: (path as NSString).lastPathComponent)
    }

    private func emit(_ batch: [TokenEvent]) {
        // The watcher calls this only when a watched file gained completed lines (`sawData`), so
        // reaching here *is* the local-write fact — token-bearing or not (STEP_170). Liveness
        // only: no tokens, no tripwire, no turn-boundary hook.
        writeContinuation.yield(Date())
        if !batch.isEmpty { tokenContinuation.yield(batch) }
        emitDelta(for: batch)
    }

    // MARK: - Delta detection (Baseline §13.1 — all four signal kinds as of STEP_26)

    private func emitDelta(for batch: [TokenEvent]) {
        let beforeSurfaces = seenSurfaceBuckets.count
        let beforeSubagents = seenSubagentBuckets.count
        for event in batch {
            seenSurfaceBuckets.insert(event.surfaceBucket)
            if event.surfaceBucket.hasPrefix("Subagent") {
                seenSubagentBuckets.insert(event.surfaceBucket)
            }
        }
        let surfaceChanged = seenSurfaceBuckets.count != beforeSurfaces
        let subagentChanged = seenSubagentBuckets.count != beforeSubagents
        let burnCrossed = burnTier.record(
            tokens: batch.reduce(0) { $0 + $1.inputTokens + $1.outputTokens })
        let quota429s = pendingQuota429s
        pendingQuota429s.removeAll()
        let signal = LocalDeltaSignal(
            tool: .claude,
            subagentCountChanged: subagentChanged,
            surfaceBucketChanged: surfaceChanged,
            burnTierCrossed: burnCrossed,
            quota429Observations: quota429s
        )
        guard signal.isMeaningful else { return }
        deltaContinuation.yield(signal)
    }

    deinit {
        tokenContinuation.finish()
        deltaContinuation.finish()
        writeContinuation.finish()
    }
}
