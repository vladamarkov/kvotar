import Foundation

/// Shared two-level JSONL directory watcher (PATTERNS.md §JSONL watching / Decision 5; STEP_24).
///
/// `ClaudeLocalAdapter` and `CodexLocalAdapter` were ~80%-identical copies of this machinery, so
/// the same defects lived in both. This type owns the shared plumbing — recursive directory
/// watching, per-file `DispatchSource`s, byte offsets, partial-line carry, debounce, discovery, and
/// file-descriptor lifecycle — so each fix lands once. The adapters stay separate and inject their
/// genuinely distinct behavior (parser, delta rule, Codex originator/SQLite metadata) through the
/// closures passed to `start(...)`.
///
/// `actor` for the same reason the adapters were: it owns mutable source/offset/residual state
/// accessed from FSEvents callbacks that run on `queue` (a `DispatchQueue`) and hop back in via
/// `Task`. The `@Sendable` handler closures are load-bearing (BUG-1): without it a handler inherits
/// the enclosing method's actor isolation and the compiler inserts an executor precondition at the
/// closure's entry, which `DispatchSource` — invoking on `queue`, not the actor executor — fails
/// ("Incorrect actor executor assumption"). A `@Sendable` closure is non-isolated; the inner `Task`
/// hops onto this actor via `await`.
///
/// **fd bound (STEP_24 core fix):** the old code opened one fd per JSONL file *ever* discovered and
/// never released it, so a daily user's session history eventually exhausted the process descriptor
/// table and every SQLite/URLSession/log write failed. Here per-file sources are bounded to the
/// *active* set: only files modified within `activeFileWindow` get a source, most-recently-modified
/// first, capped at `maxFileSources`. Historical files (never re-appended) get no source and cost no
/// fd. Offsets are still tracked for every discovered file so a later promotion resumes from where
/// it left off rather than re-reading the whole file.
///
/// **The real descriptor ceiling is ≈2,560, not 256** *(corrected STEP_117 / REV-71 §2.2 — this doc
/// and `maxFileSources` both used to say 256)*. The number was measured from an actual failure on
/// 2026-08-17: the process held 2,596 open handles, the highest numbered 2,559, and every further
/// `open()` returned `EMFILE`. That undocumented 10× of headroom is the only reason the unbounded
/// *directory* sources below survived 44 days as REV-12 without anyone noticing — and why, when they
/// finally exhausted it, everything failed at once.
///
/// **Directory sources are still unbounded (REV-12, open).** `roots` narrows *where* we walk —
/// STEP_117 cut Codex from ~2,614 directories to ~51 by watching `~/.codex/sessions` and
/// `~/.codex/archived_sessions` instead of all of `~/.codex` — but every directory found under a
/// root still costs one fd forever. `sessions/` gains one directory per day and is never pruned, so
/// this buys years, not immunity. The durable fix (a single `FSEvents` subtree stream, or a windowed
/// directory bound) is REV-12 and is deliberately not in STEP_117.
public actor JSONLDirectoryWatcher {

    /// Every tree walked. One entry for Claude (`~/.claude/projects`), two for Codex
    /// (`sessions` + `archived_sessions` — STEP_117). Roots may legitimately not exist.
    private let roots: [URL]
    private let component: LogComponent
    private let debounceInterval: DispatchTimeInterval
    /// A file counts as *active* (watchable) if its mtime is within this window of now.
    private let activeFileWindow: TimeInterval
    /// Hard ceiling on live per-file `DispatchSource`s (fd bound). Keeps the most-recently-modified.
    private let maxFileSources: Int
    /// Periodic rescan cadence (REV-20). Appends to a *known-but-unwatched* file (demoted, or outside
    /// `activeFileWindow` at launch) fire no FS event — dir sources only see entry create/rename/
    /// delete — and re-promotion otherwise happens only inside `flushNow()`, which itself only runs
    /// when an already-watched source fires. A resumed Claude Code session is exactly such a file, so
    /// without the timer it stays invisible indefinitely. The rescan bounds that blind window; it
    /// also bounds the new-day-dir case (REV-12).
    private let rescanInterval: TimeInterval

    private let queue: DispatchQueue

    // Watching state.
    private var dirSources: [String: any DispatchSourceFileSystemObject] = [:]
    private var fileSources: [String: any DispatchSourceFileSystemObject] = [:]
    /// Byte offset consumed per path. Tracked for *every* discovered file (cheap, no fd) so a file
    /// promoted later resumes from its seed point instead of re-reading historical content.
    private var fileOffsets: [String: UInt64] = [:]
    /// Un-terminated trailing bytes carried between appends so a JSONL line split across two reads
    /// is never handed to the parser half-formed (and lost). Dropped on truncation/rotation.
    private var residual: [String: Data] = [:]
    /// Roots already reported absent/unreadable, so the 45-second rescan does not re-log them.
    private var reportedRoots: Set<String> = []
    private var debounceItem: DispatchWorkItem?
    private var rescanTimer: (any DispatchSourceTimer)?
    private var isWatching = false

    // Injected per-adapter behavior, set in `start(...)`.
    private var onNewFile: (@Sendable (String) async -> Void)?
    private var onEvict: (@Sendable (String) async -> Void)?
    private var parse: (@Sendable (Data, String) async -> [TokenEvent])?
    private var onFlush: (@Sendable ([TokenEvent]) async -> Void)?

    /// Single-root convenience — Claude watches exactly one tree.
    public init(
        root: URL,
        component: LogComponent,
        debounceInterval: DispatchTimeInterval = .seconds(5),
        activeFileWindow: TimeInterval = 1800,
        maxFileSources: Int = 128,
        rescanInterval: TimeInterval = 45
    ) {
        self.init(roots: [root], component: component, debounceInterval: debounceInterval,
                  activeFileWindow: activeFileWindow, maxFileSources: maxFileSources,
                  rescanInterval: rescanInterval)
    }

    public init(
        roots: [URL],
        component: LogComponent,
        debounceInterval: DispatchTimeInterval = .seconds(5),
        activeFileWindow: TimeInterval = 1800,   // 30 min
        // Unchanged by STEP_117 — 128 was never the bound that failed, and retuning it against the
        // corrected ≈2,560 ceiling is explicitly out of that step's scope. Worst case on the
        // dogfood machine today is two watchers × 128 file sources + ~262 directory sources.
        maxFileSources: Int = 128,
        rescanInterval: TimeInterval = 45         // REV-20 blind-window bound
    ) {
        self.roots = roots
        self.component = component
        self.debounceInterval = debounceInterval
        self.activeFileWindow = activeFileWindow
        self.maxFileSources = maxFileSources
        self.rescanInterval = rescanInterval
        self.queue = DispatchQueue(label: "com.vladimirmarkovic.kvotar.jsonl-watcher.\(component.rawValue)")
    }

    // MARK: - Lifecycle

    /// Begins two-level watching. Idempotent — a second call while watching is a no-op.
    ///
    /// - Parameters:
    ///   - onNewFile: runs once per newly-discovered file path (Codex captures its originator here).
    ///   - onEvict: runs when a watched file is deleted/renamed, so the adapter can drop per-path caches.
    ///   - parse: converts appended, newline-complete bytes for a path into events.
    ///   - onFlush: receives the combined batch — the adapter yields to its stream and runs its delta.
    public func start(
        onNewFile: @escaping @Sendable (String) async -> Void,
        onEvict: @escaping @Sendable (String) async -> Void,
        parse: @escaping @Sendable (Data, String) async -> [TokenEvent],
        onFlush: @escaping @Sendable ([TokenEvent]) async -> Void
    ) async {
        guard !isWatching else { return }
        isWatching = true
        self.onNewFile = onNewFile
        self.onEvict = onEvict
        self.parse = parse
        self.onFlush = onFlush

        let now = Date()
        let (dirs, files) = discover()
        // Seed offsets to end-of-file so we only report events appended after launch; do this for
        // every existing file (not just watched ones) so a later promotion never re-reads history.
        // Everything *before* these seed points is covered by the STEP_95 launch backfill
        // (`JSONLBackfillReader`, driven by the composition root after both watchers start) —
        // the seed itself must stay EOF, or the live path would re-read history on every launch.
        await noteDiscovered(files, seedNewToEOF: true)
        for dir in dirs { addDirectorySource(dir.path) }
        syncFileSources(files: files, now: now)
        startRescanTimer()

        Logger.info("JSONL watching started", component: component,
                    metadata: ["roots": roots.map(\.path).joined(separator: ","),
                               "dirs": "\(dirSources.count)", "files": "\(fileSources.count)",
                               "known": "\(fileOffsets.count)"])
    }

    /// Periodic `flushNow()` so files that resume being written without any watched-source event
    /// (see `rescanInterval`) are discovered, promoted, and drained within one interval.
    private func startRescanTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + rescanInterval, repeating: rescanInterval)
        timer.setEventHandler { @Sendable [weak self] in
            Task { await self?.flushNow() }
        }
        rescanTimer = timer
        timer.resume()
    }

    /// Cancels all watchers and pending debounce work.
    public func stop() async {
        isWatching = false
        debounceItem?.cancel()
        debounceItem = nil
        rescanTimer?.cancel()
        rescanTimer = nil
        for source in dirSources.values { source.cancel() }
        for source in fileSources.values { source.cancel() }
        dirSources.removeAll()
        fileSources.removeAll()
        Logger.info("JSONL watching stopped", component: component)
    }

    /// Forces a synchronous flush. Adapters' public `flush()` forwards here; also the test seam.
    public func flushNow() async {
        guard isWatching else { return }
        let now = Date()
        let (dirs, files) = discover()

        // Pick up directories/files created since the last flush.
        for dir in dirs where dirSources[dir.path] == nil { addDirectorySource(dir.path) }
        await noteDiscovered(files, seedNewToEOF: false)
        syncFileSources(files: files, now: now)

        var batch: [TokenEvent] = []
        var sawData = false
        for path in Array(fileSources.keys) {
            guard let (data, newOffset) = readAppended(path, from: fileOffsets[path] ?? 0) else { continue }
            fileOffsets[path] = newOffset
            guard !data.isEmpty else { continue }
            sawData = true
            batch.append(contentsOf: await parse?(data, path) ?? [])
        }

        // Flush on any appended data, even with zero token events — a quota-429 error line
        // produces no `TokenEvent` but must still reach the adapter's delta hook (STEP_26).
        guard sawData else { return }
        await onFlush?(batch)
        Logger.info("JSONL flush", component: component, metadata: ["events": "\(batch.count)"])
    }

    /// Live per-file source count — the fd-bound invariant. Test-facing (`@testable`).
    var fileSourceCount: Int { fileSources.count }

    // MARK: - Discovery bookkeeping

    /// Records offsets and fires `onNewFile` for paths seen for the first time. Existing paths (still
    /// carrying an offset, even if demoted) are untouched so their read position survives.
    private func noteDiscovered(_ files: [URL], seedNewToEOF: Bool) async {
        for file in files {
            let path = file.path
            guard fileOffsets[path] == nil else { continue }
            fileOffsets[path] = seedNewToEOF ? fileSize(path) : 0
            await onNewFile?(path)
        }
    }

    // MARK: - Per-file source bound (mtime-window + LRU cap)

    /// Reconciles the live per-file source set to the *desired* set: files modified within
    /// `activeFileWindow`, most-recently-modified first, capped at `maxFileSources`. Files that aged
    /// out or fell past the cap are **demoted** (source cancelled, offset/residual kept so a later
    /// re-promotion resumes cleanly); freshly-active files are **promoted** (source added).
    private func syncFileSources(files: [URL], now: Date) {
        let cutoff = now.addingTimeInterval(-activeFileWindow)
        let desired = files
            .map { ($0.path, mtime($0.path)) }
            .filter { $0.1 >= cutoff }
            .sorted { $0.1 > $1.1 }
            .prefix(maxFileSources)
            .map { $0.0 }
        let desiredSet = Set(desired)

        for path in Array(fileSources.keys) where !desiredSet.contains(path) {
            demoteFileSource(path)
        }
        for path in desired where fileSources[path] == nil {
            addFileSource(path)
        }
    }

    /// Cancels a source but keeps `fileOffsets`/`residual` — the file still exists, it is just not
    /// currently watched. Contrast `evictFileSource`, for a file that is gone.
    private func demoteFileSource(_ path: String) {
        fileSources[path]?.cancel()
        fileSources[path] = nil
    }

    /// Cancels a source and drops all per-path state for a file that was deleted/renamed, then lets
    /// the adapter clear its own caches. A recreated path is treated as brand-new on next discovery.
    private func evictFileSource(_ path: String) async {
        fileSources[path]?.cancel()
        fileSources[path] = nil
        fileOffsets[path] = nil
        residual[path] = nil
        await onEvict?(path)
    }

    // MARK: - Source registration

    private func addDirectorySource(_ path: String) {
        guard dirSources[path] == nil else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            Logger.warning("open(O_EVTONLY) failed", component: component,
                           metadata: ["path": path, "errno": String(cString: strerror(errno))])
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler { @Sendable [weak self, weak source] in
            let removed = Self.isRemoval(source?.data ?? [])
            Task { await self?.handleDirEvent(path: path, removed: removed) }
        }
        source.setCancelHandler { close(fd) }
        dirSources[path] = source
        source.resume()
    }

    private func addFileSource(_ path: String) {
        guard fileSources[path] == nil else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            Logger.warning("open(O_EVTONLY) failed", component: component,
                           metadata: ["path": path, "errno": String(cString: strerror(errno))])
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: queue)
        source.setEventHandler { @Sendable [weak self, weak source] in
            let removed = Self.isRemoval(source?.data ?? [])
            Task { await self?.handleFileEvent(path: path, removed: removed) }
        }
        source.setCancelHandler { close(fd) }
        fileSources[path] = source
        source.resume()
    }

    // MARK: - Event handling

    /// Delete/rename fire this mask. Computed in the `@Sendable` handler so only a `Sendable` `Bool`
    /// crosses into the actor (`DispatchSource.FileSystemEvent` is not `Sendable`).
    private static func isRemoval(_ flags: DispatchSource.FileSystemEvent) -> Bool {
        flags.contains(.delete) || flags.contains(.rename)
    }

    /// A directory changed: on delete/rename of the directory itself, drop its source; then flush so
    /// discovery picks up new/removed child files.
    private func handleDirEvent(path: String, removed: Bool) async {
        if removed {
            dirSources[path]?.cancel()
            dirSources[path] = nil
        }
        scheduleFlush()
    }

    /// A watched file changed: delete/rename evicts it (re-registerable when the path reappears);
    /// write/extend just schedules a flush that drains the appended bytes.
    private func handleFileEvent(path: String, removed: Bool) async {
        if removed {
            await evictFileSource(path)
        }
        scheduleFlush()
    }

    // MARK: - Debounce (PATTERNS.md §JSONL watching — 5s cancel-and-reschedule)

    private func scheduleFlush() {
        debounceItem?.cancel()
        let item = DispatchWorkItem { @Sendable [weak self] in
            Task { await self?.flushNow() }
        }
        debounceItem = item
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    // MARK: - Filesystem helpers

    /// Single combined tree walk returning directories and `.jsonl` files — replaces the three
    /// separate `FileManager.enumerator` walks the old per-flush code ran.
    private func discover() -> (dirs: [URL], files: [URL]) {
        var dirs: [URL] = []
        var files: [URL] = []
        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else {
                noteRootUnusable(root, reachable: false)
                continue
            }
            dirs.append(root)
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else {
                noteRootUnusable(root, reachable: true)
                continue
            }
            clearRootReport(root)
            for case let url as URL in enumerator {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    dirs.append(url)
                } else if url.pathExtension == "jsonl" {
                    files.append(url)
                }
            }
        }
        return (dirs, files)
    }

    /// One line per root, not one per directory (REV-71 §3.2). The night the descriptor table ran
    /// dry, Claude's watcher emitted hundreds of identical per-directory warnings and not one line
    /// saying *the watcher is not running* — so this is the greppable fact, and it is deduplicated
    /// (`reportedRoots`) because `discover()` runs on every 45-second rescan.
    ///
    /// `reachable: false` — the root simply is not there, which is normal (a machine that has never
    /// archived a Codex session has no `~/.codex/archived_sessions`). `INFO`, and the root is
    /// re-checked on every rescan, so it is picked up if it later appears.
    /// `reachable: true` — the root exists and we still could not walk it. That is the descriptor
    /// exhaustion / permission case, and it is an `ERROR`.
    private func noteRootUnusable(_ root: URL, reachable: Bool) {
        guard !reportedRoots.contains(root.path) else { return }
        reportedRoots.insert(root.path)
        if reachable {
            Logger.error("JSONL watch root could not be read — this tree is not being watched",
                         component: component, metadata: ["root": root.path])
        } else {
            Logger.info("JSONL watch root absent", component: component,
                        metadata: ["root": root.path])
        }
    }

    /// Re-arms the report for a root that is readable again, so a recurrence is logged afresh.
    private func clearRootReport(_ root: URL) {
        reportedRoots.remove(root.path)
    }

    private func fileSize(_ path: String) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func mtime(_ path: String) -> Date {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.modificationDate] as? Date) ?? .distantPast
    }

    /// Reads bytes appended after `offset`, returning only **newline-complete** data plus the new
    /// offset; the un-terminated tail is retained in `residual[path]` for the next append (reuses the
    /// carry approach in `CodexProcessTransportLive.ingest`). Resets to reading from 0 — and clears
    /// the stale tail — if the file shrank (truncation/rotation).
    private func readAppended(_ path: String, from offset: UInt64) -> (Data, UInt64)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let shrank = end < offset
        if shrank { residual[path] = nil }
        let start = shrank ? 0 : offset
        do {
            try handle.seek(toOffset: start)
            let raw = try handle.readToEnd() ?? Data()
            var buffer = residual[path] ?? Data()
            buffer.append(raw)
            guard let lastNewline = buffer.lastIndex(of: 0x0A) else {
                // No complete line yet — carry everything, emit nothing (offset still advances).
                residual[path] = buffer.isEmpty ? nil : buffer
                return (Data(), end)
            }
            let complete = Data(buffer[buffer.startIndex...lastNewline])
            let tailStart = buffer.index(after: lastNewline)
            residual[path] = tailStart < buffer.endIndex ? Data(buffer[tailStart...]) : nil
            return (complete, end)
        } catch {
            return nil
        }
    }
}
