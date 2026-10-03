import Foundation

/// One-shot launch backfill sweep over a tool's JSONL trees (STEP_95, REV-62 §4.2).
///
/// `JSONLDirectoryWatcher` seeds every file's read offset to end-of-file at launch, so anything
/// written while the app was not running was lost permanently — 204 Claude events (37.4M tokens)
/// and 822 Codex events (93.7M tokens) on the dogfood machine at measurement time, 97 of the
/// Claude gaps sitting *mid-stream* in sessions the app otherwise tracked. This reader covers the
/// bytes the watcher's seed skips: it re-reads candidate files **from byte 0 to their current
/// end** and hands the parsed events to a write closure whose dedup makes re-reading free.
///
/// Candidates are files whose modification time is newer than `cutoff` — the per-tool watermark
/// (`jsonl_backfill_watermark_<tool>`, sweep-start unix seconds) on a routine relaunch, or
/// `now − 90 days` when no watermark exists (first run; 90 days is the app's standing retention
/// horizon, user decision 2026-08-12). Newest-first, so the display-relevant 30-day window fills
/// soonest.
///
/// Deliberately a plain `struct` driven by the caller's task, not an actor: the sweep runs on one
/// background `.utility` task and must not occupy the adapters' actors — only the injected `parse`
/// closure hops onto an adapter, one chunk at a time, so live flushes interleave freely.
///
/// What the sweep does **not** do (both deliberate, both load-bearing):
/// - **No delta signals.** Events bypass the adapters' `emit`/`emitDelta` path — historic bursts
///   must not fire the JSONL tripwire, cross burn tiers, or arm the STEP_77 alignment timer.
/// - **No quota-429 replay.** `writeQuota429Events` pairs an observation with the *current*
///   snapshot's utilization; replaying historic 429s would pollute the §9.4 self-learning ceiling.
public struct JSONLBackfillReader: Sendable {

    /// What one write call actually inserted (dedup drops the rest).
    public struct WriteCounts: Sendable {
        public let inserted: Int
        /// Displayed-count tokens of the inserted rows (Baseline §4 per-tool fork).
        public let insertedTokens: Int
        public init(inserted: Int, insertedTokens: Int) {
            self.inserted = inserted
            self.insertedTokens = insertedTokens
        }
    }

    /// One sweep's outcome — the coordinator logs this so the one-off jump in the 30-day
    /// figures is explainable rather than alarming (STEP_95 task 4).
    public struct Summary: Sendable {
        public var filesScanned = 0
        /// Candidates that disappeared between discovery and read (Codex deletes old rollout
        /// files; 39 DB rows already reference such files). Skipped, never fatal (task 3).
        public var filesVanished = 0
        public var eventsParsed = 0
        public var eventsInserted = 0
        public var insertedTokens = 0
        public init() {}
    }

    /// Every tree swept — the same set the watcher watches. Codex has two since STEP_117
    /// (`~/.codex/sessions` and `~/.codex/archived_sessions`); Claude has one. These **must** stay
    /// in step with `JSONLDirectoryWatcher`'s roots: a sweep narrower than the watcher would leave
    /// a tree whose pre-launch bytes are never recovered (the archived Codex tree holds a session
    /// with 6 stored rows), and a sweep wider than the watcher would ingest files the app has
    /// deliberately stopped looking at.
    private let roots: [URL]
    /// Read granularity. Bounds memory per file — no buffer scales with file size (task 2).
    private let chunkSize: Int
    /// Ceiling on events handed to one `write` call, so no transaction scales with file size.
    private let maxBatchEvents: Int

    public init(roots: [URL], chunkSize: Int = 1 << 20, maxBatchEvents: Int = 2000) {
        self.roots = roots
        self.chunkSize = chunkSize
        self.maxBatchEvents = maxBatchEvents
    }

    /// Single-root convenience — Claude sweeps exactly one tree.
    public init(root: URL, chunkSize: Int = 1 << 20, maxBatchEvents: Int = 2000) {
        self.init(roots: [root], chunkSize: chunkSize, maxBatchEvents: maxBatchEvents)
    }

    /// Runs the sweep: every `.jsonl` under any root with mtime > `cutoff`, newest first, read
    /// whole in `chunkSize` slices split at line boundaries. `parse` converts newline-complete
    /// bytes for a path into events (the adapters' backfill parse — token events only, no 429
    /// detection); its third argument is true for the first parsed chunk of each file, so an
    /// adapter keeping per-file carry state (the Codex cumulative-total re-emission guard,
    /// STEP_94) can reset it at byte 0 — a re-read against a carry left at end-of-file would
    /// classify every event as already counted. `write` persists a batch and reports what it
    /// actually inserted (nil on a write error — the sweep continues; dedup makes the next
    /// launch's retry free).
    public func run(
        cutoff: Date,
        parse: @Sendable (Data, String, _ isFirstChunk: Bool) async -> [TokenEvent],
        write: @Sendable ([TokenEvent]) async -> WriteCounts?
    ) async -> Summary {
        var summary = Summary()
        for url in candidates(cutoff: cutoff) {
            await sweepFile(url.path, parse: parse, write: write, into: &summary)
        }
        return summary
    }

    // MARK: - Discovery

    /// All `.jsonl` files under **any** root modified after `cutoff`, newest first across the
    /// combined set — the ordering rationale (display-relevant 30 days fill soonest) is global, so
    /// the sort happens once over every root's candidates, not per root. A root that does not
    /// exist contributes nothing and is not an error (the watcher owns that report).
    private func candidates(cutoff: Date) -> [URL] {
        var found: [(URL, Date)] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl" else { continue }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                let mtime = values?.contentModificationDate ?? .distantPast
                if mtime > cutoff { found.append((url, mtime)) }
            }
        }
        return found.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    // MARK: - Per-file sweep

    private func sweepFile(
        _ path: String,
        parse: @Sendable (Data, String, _ isFirstChunk: Bool) async -> [TokenEvent],
        write: @Sendable ([TokenEvent]) async -> WriteCounts?,
        into summary: inout Summary
    ) async {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            summary.filesVanished += 1
            return
        }
        defer { try? handle.close() }
        summary.filesScanned += 1

        // Partial-line carry across chunks, local to this file (same approach as the watcher's
        // `readAppended`). An unterminated final line is a write in progress — the live watcher
        // owns it; a mid-file read error abandons the remainder (next touched-file sweep retries).
        var residual = Data()
        var pending: [TokenEvent] = []
        var isFirstChunk = true
        while true {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            residual.append(chunk)
            guard let lastNewline = residual.lastIndex(of: 0x0A) else { continue }
            let complete = Data(residual[residual.startIndex...lastNewline])
            let tailStart = residual.index(after: lastNewline)
            residual = tailStart < residual.endIndex ? Data(residual[tailStart...]) : Data()

            let events = await parse(complete, path, isFirstChunk)
            isFirstChunk = false
            summary.eventsParsed += events.count
            pending.append(contentsOf: events)
            while pending.count >= maxBatchEvents {
                let batch = Array(pending.prefix(maxBatchEvents))
                pending.removeFirst(batch.count)
                await flush(batch, write: write, into: &summary)
            }
        }
        await flush(pending, write: write, into: &summary)
    }

    private func flush(
        _ batch: [TokenEvent],
        write: @Sendable ([TokenEvent]) async -> WriteCounts?,
        into summary: inout Summary
    ) async {
        guard !batch.isEmpty, let counts = await write(batch) else { return }
        summary.eventsInserted += counts.inserted
        summary.insertedTokens += counts.insertedTokens
    }
}
