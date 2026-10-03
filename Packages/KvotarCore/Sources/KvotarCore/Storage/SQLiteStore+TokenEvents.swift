import Foundation
import GRDB

// Typed local-attribution persistence for local adapters (§17, task line 13).
//
// A flushed JSONL batch updates both `local_sessions` (session metadata, upsert) and
// `local_usage_events` (per-request token deltas, INSERT OR IGNORE on the composite PK) in
// one transaction so no reader sees usage rows without their parent session (ARCHITECTURE.md
// §SQLite access). Called by a consumer of `LocalAdapter.tokenEvents`; adapters never call it.
//
// Timestamps are written as `Int` unix seconds (PATTERNS.md §SQLite rule).
extension SQLiteStore {

    /// Persists one flushed batch of `TokenEvent`s. Empty batches are a no-op.
    ///
    /// `local_sessions` is upserted per event: `last_seen_at` advances to the latest event,
    /// `started_at` keeps the earliest known value, and metadata columns adopt the newest
    /// non-null value. `local_usage_events` uses INSERT OR IGNORE so replays of already-seen
    /// `(session_id, tool, dedup_key)` rows are dropped (Baseline §7.2 deduplication) — and,
    /// since STEP_94, an event whose key already exists under **any** session id is skipped
    /// entirely (the `duplicateExists` guard below): a resumed/forked Claude session rewrites
    /// copied lines under the new session id, so the composite PK alone stored every copied
    /// message again (REV-62 §4.1 (c)). A skipped event also skips the session upsert, exactly
    /// as the backfill does — the fork's own fresh turns create its session row.
    public func writeTokenEvents(_ events: [TokenEvent]) throws {
        guard !events.isEmpty else { return }
        do {
            try withPool { pool in
                try pool.write { db in
                    for event in events {
                        let tool = event.tool.rawValue
                        let recordedAt = Int(event.recordedAt.timeIntervalSince1970)
                        let startedAt = event.startedAt.map { Int($0.timeIntervalSince1970) }
                        if try Self.duplicateExists(db, event: event) { continue }

                        // local_sessions — upsert; keep earliest started_at, advance last_seen_at,
                        // adopt newest non-null metadata. A zero-usage event's model is withheld
                        // (STEP_93 task 3): `<synthetic>` — Claude Code's zero-token placeholder
                        // for a turn that died before the API — must never rename the session it
                        // happens to land last in (REV-62 §4.3: one such line relabelled 196
                        // genuine turns).
                        try db.execute(sql: """
                            INSERT INTO local_sessions (
                                session_id, tool, project, model, originator, surface_bucket,
                                started_at, last_seen_at
                            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            ON CONFLICT(session_id, tool) DO UPDATE SET
                                project = COALESCE(excluded.project, local_sessions.project),
                                model = COALESCE(excluded.model, local_sessions.model),
                                originator = COALESCE(excluded.originator, local_sessions.originator),
                                surface_bucket = COALESCE(excluded.surface_bucket, local_sessions.surface_bucket),
                                started_at = MIN(
                                    COALESCE(excluded.started_at, local_sessions.started_at),
                                    COALESCE(local_sessions.started_at, excluded.started_at)
                                ),
                                last_seen_at = MAX(excluded.last_seen_at, local_sessions.last_seen_at)
                            """, arguments: [
                                event.sessionId, tool, event.project, event.attributableModel,
                                event.originator, event.surfaceBucket, startedAt, recordedAt,
                            ])

                        // local_usage_events — dedup at PK level; replays are ignored. `model` and
                        // `surface_bucket` are per-event (STEP_93): pricing and the surface split
                        // group by the event's own values, falling back to the session's where
                        // NULL. The same zero-usage rule applies, so a placeholder line can never
                        // reach a per-model grouping or the pricing table.
                        // `cache_creation_1h_tokens` is a SUBSET of `cache_creation_tokens`
                        // (STEP_96) — the total is unchanged, so no count or ratio moves; only
                        // the est-value math reads the split. NULL where the source did not
                        // break the write down (always, for Codex).
                        try db.execute(sql: """
                            INSERT OR IGNORE INTO local_usage_events (
                                session_id, tool, dedup_key, recorded_at,
                                input_tokens, output_tokens,
                                cache_creation_tokens, cache_creation_1h_tokens,
                                cache_read_tokens,
                                model, surface_bucket
                            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """, arguments: [
                                event.sessionId, tool, event.dedupKey, recordedAt,
                                event.inputTokens, event.outputTokens,
                                event.cacheCreationTokens, event.cacheCreation1hTokens,
                                event.cacheReadTokens,
                                event.attributableModel, event.surfaceBucket,
                            ])
                    }
                }
            }
        } catch {
            Logger.error("Token-event write failed", component: .sqliteStore,
                         metadata: ["count": "\(events.count)", "error": "\(error)"])
            throw error
        }
    }

    /// Bare `recorded_at` timestamps of every local usage event in `[since, until)`, oldest
    /// first — the token-presence input the off-machine recompute buckets per poll interval
    /// (REV-53 §3). Timestamps only, no token counts: the recompute classifies intervals by
    /// presence, and the caller buckets against irregular series boundaries in Swift.
    public func tokenEventTimestamps(tool: Tool, since: Date, until: Date) throws -> [Date] {
        try withPool { pool in
            try pool.read { db in
                try Int.fetchAll(db, sql: """
                    SELECT recorded_at FROM local_usage_events
                    WHERE tool = ? AND recorded_at >= ? AND recorded_at < ?
                    ORDER BY recorded_at ASC
                    """, arguments: [
                        tool.rawValue,
                        Int(since.timeIntervalSince1970),
                        Int(until.timeIntervalSince1970),
                    ])
                .map { Date(timeIntervalSince1970: TimeInterval($0)) }
            }
        }
    }

    /// Persists one **backfill** batch (STEP_95), returning what was actually inserted.
    ///
    /// Guards with the same any-session `duplicateExists` check as `writeTokenEvents` (shared
    /// since STEP_94; it originated here in STEP_95): an event is skipped when its
    /// `(tool, dedup_key)` already exists under **any** `session_id` — not just under the
    /// composite PK. The Codex session-id convention changed around 2026-07-13 (bare ULID
    /// before, rollout-file basename after; REV-62 §2.5 / STEP_94 (b)) while the dedup key —
    /// which embeds the rollout basename — stayed stable across both eras. A backfill through
    /// the PK alone would therefore re-insert ~2,800 pre-boundary corpus events under the new
    /// convention as "different" rows, double-counting hundreds of millions of tokens. The
    /// key-only check is strictly more conservative and loses nothing real: Claude keys are
    /// globally unique request/message ids, Codex keys embed the file basename.
    ///
    /// What differs from `writeTokenEvents`: this path returns insert counts for the
    /// coordinator's log.
    ///
    /// Skipped events also skip the `local_sessions` upsert — a new-convention session row with
    /// zero usage rows behind it would be clutter, and session-identity reconciliation is
    /// STEP_93/94's job, not the backfill's.
    ///
    /// Returns the inserted row count and their displayed-count token total (Baseline §4 per-tool
    /// fork: Claude's four columns are disjoint and sum; Codex's cached slice is a subset of
    /// input, so its displayed count is input + output) — the coordinator logs both so the
    /// one-off jump in the 30-day figures is explainable (STEP_95 task 4).
    public func backfillTokenEvents(
        _ events: [TokenEvent]
    ) throws -> JSONLBackfillReader.WriteCounts {
        guard !events.isEmpty else { return .init(inserted: 0, insertedTokens: 0) }
        do {
            return try withPool { pool in
                try pool.write { db in
                    var inserted = 0
                    var insertedTokens = 0
                    for event in events {
                        let tool = event.tool.rawValue
                        if try Self.duplicateExists(db, event: event) { continue }

                        let recordedAt = Int(event.recordedAt.timeIntervalSince1970)
                        let startedAt = event.startedAt.map { Int($0.timeIntervalSince1970) }
                        try db.execute(sql: """
                            INSERT INTO local_sessions (
                                session_id, tool, project, model, originator, surface_bucket,
                                started_at, last_seen_at
                            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            ON CONFLICT(session_id, tool) DO UPDATE SET
                                project = COALESCE(excluded.project, local_sessions.project),
                                model = COALESCE(excluded.model, local_sessions.model),
                                originator = COALESCE(excluded.originator, local_sessions.originator),
                                surface_bucket = COALESCE(excluded.surface_bucket, local_sessions.surface_bucket),
                                started_at = MIN(
                                    COALESCE(excluded.started_at, local_sessions.started_at),
                                    COALESCE(local_sessions.started_at, excluded.started_at)
                                ),
                                last_seen_at = MAX(excluded.last_seen_at, local_sessions.last_seen_at)
                            """, arguments: [
                                event.sessionId, tool, event.project, event.attributableModel,
                                event.originator, event.surfaceBucket, startedAt, recordedAt,
                            ])
                        try db.execute(sql: """
                            INSERT OR IGNORE INTO local_usage_events (
                                session_id, tool, dedup_key, recorded_at,
                                input_tokens, output_tokens,
                                cache_creation_tokens, cache_creation_1h_tokens,
                                cache_read_tokens,
                                model, surface_bucket
                            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """, arguments: [
                                event.sessionId, tool, event.dedupKey, recordedAt,
                                event.inputTokens, event.outputTokens,
                                event.cacheCreationTokens, event.cacheCreation1hTokens,
                                event.cacheReadTokens,
                                event.attributableModel, event.surfaceBucket,
                            ])
                        guard db.changesCount > 0 else { continue }
                        inserted += 1
                        insertedTokens += event.inputTokens + event.outputTokens
                        if event.tool == .claude {
                            insertedTokens += event.cacheCreationTokens + event.cacheReadTokens
                        }
                    }
                    return JSONLBackfillReader.WriteCounts(
                        inserted: inserted, insertedTokens: insertedTokens)
                }
            }
        } catch {
            Logger.error("Backfill token-event write failed", component: .sqliteStore,
                         metadata: ["count": "\(events.count)", "error": "\(error)"])
            throw error
        }
    }

    /// Deletes the historical residue of Codex re-emitted turns (STEP_94 (a)): rows whose file,
    /// re-parsed under the cumulative-total drop rule, no longer produces their dedup key. The
    /// parser now drops re-emissions at ingest, but 92 of the corpus's 192 were ingested before
    /// the rule existed and no SQL can identify them — the cumulative totals that expose a
    /// re-emission live only in the JSONL. Same REV-43 argument as migration v16: each deleted
    /// row is the app's second record of one provider observation still on disk.
    ///
    /// `keptKeys` maps each swept session id (rollout-file basename) to every dedup key a clean
    /// parse of its file yielded. Keys are matched by their basename prefix so rows stored under
    /// the pre-2026-07-13 bare-UUID session convention are covered too (their keys embed the
    /// basename all the same). Two safety bounds, both load-bearing:
    /// - `olderThan` skips rows whose event time is near the sweep — a line that completed and
    ///   was live-ingested *after* the sweep read its file must not look like a re-emission.
    /// - A session where more than 20% of rows (min 5) would go is skipped with a WARNING — a
    ///   mid-file read error hands the sweep a truncated kept-set, and mass deletion from the
    ///   permanent corpus is never the right response to a bad read.
    ///
    /// Returns the number of rows deleted.
    public func reconcileCodexReEmissions(
        keptKeys: [String: Set<String>], olderThan cutoff: Date
    ) throws -> Int {
        guard !keptKeys.isEmpty else { return 0 }
        let cutoffInt = Int(cutoff.timeIntervalSince1970)
        do {
            return try withPool { pool in
                try pool.write { db in
                    var deleted = 0
                    for (sessionId, kept) in keptKeys {
                        let prefix = sessionId + "_"
                        let candidates = try String.fetchAll(db, sql: """
                            SELECT dedup_key FROM local_usage_events
                            WHERE tool = 'codex' AND recorded_at < ?
                              AND substr(dedup_key, 1, ?) = ?
                            """, arguments: [cutoffInt, prefix.count, prefix])
                        let doomed = candidates.filter { !kept.contains($0) }
                        guard !doomed.isEmpty else { continue }
                        if doomed.count > max(5, candidates.count / 5) {
                            Logger.warning("Re-emission cleanup skipped a session",
                                           component: .sqliteStore,
                                           metadata: ["session": sessionId,
                                                      "candidates": "\(candidates.count)",
                                                      "would_delete": "\(doomed.count)"])
                            continue
                        }
                        for key in doomed {
                            try db.execute(sql: """
                                DELETE FROM local_usage_events
                                WHERE tool = 'codex' AND dedup_key = ? AND recorded_at < ?
                                """, arguments: [key, cutoffInt])
                            deleted += db.changesCount
                        }
                    }
                    return deleted
                }
            }
        } catch {
            Logger.error("Re-emission cleanup failed", component: .sqliteStore,
                         metadata: ["sessions": "\(keptKeys.count)", "error": "\(error)"])
            throw error
        }
    }

    /// Deletes the stored residue of inherited forked-thread history (STEP_103): rows in
    /// **fork-marked files only** whose dedup key a clean parse under the `forkedHistoryWindow`
    /// rule no longer yields. Same REV-43 convergence argument as `reconcileCodexReEmissions`
    /// above — an inherited row is the app's second record of a turn already stored under the
    /// parent thread — and the same basename-prefix key matching, spanning both session-id
    /// conventions.
    ///
    /// Two deliberate differences from the STEP_94 sweep:
    /// - **No 20%-mass-deletion guard.** That guard exists to catch a truncated read, and here
    ///   a 100% deletion is *correct* — the 2026-07-03 fork is a phantom whose every row is a
    ///   copy of its (since-deleted) parent's. Reusing the guard would silently skip the worse
    ///   of the two observed cases. The blast radius is bounded upstream instead: `keptKeys`
    ///   contains only fork-marked sessions (3 files of 166 on the dogfood corpus).
    /// - **A `local_sessions` row is deleted when the sweep empties it.** A session with no
    ///   events left recorded no observation of its own, and keeping the shell would leave the
    ///   §2.6 surface bar a named bucket with nothing in it. Sessions are matched from the
    ///   deleted rows' own stored `session_id` values (not re-derived), so the session-id
    ///   convention change cannot misname them.
    ///
    /// The `olderThan` exemption carries over unchanged: a row live-ingested while the sweep
    /// was reading its file must not look stale.
    ///
    /// Returns the number of event rows and session rows deleted.
    public func reconcileForkedThreadHistory(
        keptKeys: [String: Set<String>], olderThan cutoff: Date
    ) throws -> (events: Int, sessions: Int) {
        guard !keptKeys.isEmpty else { return (0, 0) }
        let cutoffInt = Int(cutoff.timeIntervalSince1970)
        do {
            return try withPool { pool in
                try pool.write { db in
                    var deletedEvents = 0
                    var touchedSessions: Set<String> = []
                    for (sessionId, kept) in keptKeys {
                        let prefix = sessionId + "_"
                        let candidates = try Row.fetchAll(db, sql: """
                            SELECT dedup_key, session_id FROM local_usage_events
                            WHERE tool = 'codex' AND recorded_at < ?
                              AND substr(dedup_key, 1, ?) = ?
                            """, arguments: [cutoffInt, prefix.count, prefix])
                        for row in candidates {
                            let key: String = row["dedup_key"]
                            guard !kept.contains(key) else { continue }
                            try db.execute(sql: """
                                DELETE FROM local_usage_events
                                WHERE tool = 'codex' AND dedup_key = ? AND recorded_at < ?
                                """, arguments: [key, cutoffInt])
                            deletedEvents += db.changesCount
                            touchedSessions.insert(row["session_id"])
                        }
                    }
                    var deletedSessions = 0
                    for sessionId in touchedSessions {
                        let remaining = try Int.fetchOne(db, sql: """
                            SELECT COUNT(*) FROM local_usage_events
                            WHERE session_id = ? AND tool = 'codex'
                            """, arguments: [sessionId]) ?? 0
                        guard remaining == 0 else { continue }
                        try db.execute(sql: """
                            DELETE FROM local_sessions
                            WHERE session_id = ? AND tool = 'codex'
                            """, arguments: [sessionId])
                        deletedSessions += db.changesCount
                    }
                    return (deletedEvents, deletedSessions)
                }
            }
        } catch {
            Logger.error("Forked-history cleanup failed", component: .sqliteStore,
                         metadata: ["sessions": "\(keptKeys.count)", "error": "\(error)"])
            throw error
        }
    }

    /// Fills the per-event `model`/`surface_bucket` columns on **existing** rows from re-parsed
    /// JSONL (STEP_93's one-shot enrichment sweep, user ruling 2026-08-12). Rows are matched the
    /// same way `backfillTokenEvents` guards inserts — `(tool, dedup_key)` under **any** session
    /// id, spanning the Codex session-id convention change — and each column is filled only
    /// where NULL, so a value the live path already wrote is never overwritten and re-running
    /// the sweep is free.
    ///
    /// This is the only path that UPDATEs `local_usage_events`, and it deliberately cannot
    /// touch a token quantity: the REV-43 permanent-corpus ruling protects the recorded
    /// numbers; attribution columns added by v15 are enrichment from the same raw source
    /// (still on disk), not a rewrite. Zero-usage events contribute NULL via
    /// `attributableModel` — a `<synthetic>` placeholder cannot be written back in.
    ///
    /// Returns the number of rows actually changed.
    public func enrichTokenEventAttribution(_ events: [TokenEvent]) throws -> Int {
        guard !events.isEmpty else { return 0 }
        do {
            return try withPool { pool in
                try pool.write { db in
                    var updated = 0
                    for event in events {
                        try db.execute(sql: """
                            UPDATE local_usage_events
                            SET model = COALESCE(model, ?),
                                surface_bucket = COALESCE(surface_bucket, ?)
                            WHERE tool = ? AND dedup_key IN (?, ?)
                              AND (model IS NULL OR surface_bucket IS NULL)
                            """, arguments: [
                                event.attributableModel, event.surfaceBucket,
                                event.tool.rawValue, event.dedupKey,
                                event.legacyDedupKey ?? event.dedupKey,
                            ])
                        updated += db.changesCount
                    }
                    return updated
                }
            }
        } catch {
            Logger.error("Attribution enrichment write failed", component: .sqliteStore,
                         metadata: ["count": "\(events.count)", "error": "\(error)"])
            throw error
        }
    }

    /// STEP_100's one-shot surface-attribution repair, and the one place that **overwrites** an
    /// already-attributed `surface_bucket` rather than filling a NULL one.
    ///
    /// `enrichTokenEventAttribution` above cannot do this job: it `COALESCE`s, so it is a no-op on
    /// a row that already carries a value. The rows this repairs carry a value — the *wrong* one.
    /// The pre-STEP_100 parser labelled every `("Codex Desktop", "vscode")` session `IDE extension`
    /// and every subagent-spawned thread `Unknown`, and since STEP_93 that verdict is frozen into
    /// each event row, so the corrected rule would otherwise only reach events ingested from now
    /// on while the whole stored corpus kept the old answer.
    ///
    /// Events are matched on `(tool, dedup_key)` like the enrichment, both key forms accepted.
    /// The per-session column is then reconciled from the rows themselves (see
    /// `reconcileSessionSurface`) rather than per event, because the §2.5b bar reads
    /// `COALESCE(local_usage_events.surface_bucket, local_sessions.surface_bucket)` and the two
    /// must not be left disagreeing. **No token quantity is touched** (REV-43) — this rewrites one
    /// derived label, nothing measured.
    public func repairSurfaceAttribution(_ events: [TokenEvent]) throws -> Int {
        guard !events.isEmpty else { return 0 }
        do {
            return try withPool { pool in
                try pool.write { db in
                    var updated = 0
                    for event in events {
                        try db.execute(sql: """
                            UPDATE local_usage_events
                            SET surface_bucket = ?
                            WHERE tool = ? AND dedup_key IN (?, ?)
                              AND (surface_bucket IS NULL OR surface_bucket <> ?)
                            """, arguments: [
                                event.surfaceBucket, event.tool.rawValue, event.dedupKey,
                                event.legacyDedupKey ?? event.dedupKey, event.surfaceBucket,
                            ])
                        updated += db.changesCount
                    }
                    for tool in Set(events.map(\.tool)) {
                        try Self.reconcileSessionSurface(db, tool: tool)
                    }
                    return updated
                }
            }
        } catch {
            Logger.error("Surface attribution repair write failed", component: .sqliteStore,
                         metadata: ["count": "\(events.count)", "error": "\(error)"])
            throw error
        }
    }

    /// Makes each session's `surface_bucket` agree with its own events' — one statement, no key
    /// matching, and idempotent, so it can run after every repair batch.
    ///
    /// This is deliberately *not* done per event. The Codex session-id convention changed around
    /// 2026-07-13 while the dedup key stayed stable, so a re-parse names a session differently
    /// from the row that stores it, and reaching the session row through the key was both a
    /// subquery per event and — on the pre-convention rows — unreliable. Reading the answer back
    /// off the rows that were just corrected needs neither. Sessions whose events carry no bucket
    /// at all (pre-`v15`) are left alone: their session value *is* the answer there.
    static func reconcileSessionSurface(_ db: Database, tool: Tool) throws {
        try db.execute(sql: """
            UPDATE local_sessions
            SET surface_bucket = (
                SELECT e.surface_bucket FROM local_usage_events e
                WHERE e.tool = local_sessions.tool AND e.session_id = local_sessions.session_id
                  AND e.surface_bucket IS NOT NULL
                ORDER BY e.recorded_at DESC LIMIT 1)
            WHERE tool = ? AND EXISTS (
                SELECT 1 FROM local_usage_events e
                WHERE e.tool = local_sessions.tool AND e.session_id = local_sessions.session_id
                  AND e.surface_bucket IS NOT NULL
                  AND (local_sessions.surface_bucket IS NULL
                       OR e.surface_bucket <> local_sessions.surface_bucket))
            """, arguments: [tool.rawValue])
    }

    /// True when this event's key already exists under **any** session id — the duplicate
    /// guard shared by the live write path and the backfill (STEP_94/95). Session id is no part
    /// of the identity: Claude fork/resume copies lines into a new session's file, and the Codex
    /// session-id convention changed ~2026-07-13 while the key stayed stable. Both key forms are
    /// checked because rows written before STEP_94 changed the Claude format keep their bare
    /// `requestId` keys forever (`TokenEvent.legacyDedupKey`) — a file appended to after any
    /// horizon-bounded sweep ran gets fully re-read by the backfill, and its old lines must
    /// still match their old-format rows.
    static func duplicateExists(_ db: Database, event: TokenEvent) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(
                SELECT 1 FROM local_usage_events
                WHERE tool = ? AND dedup_key IN (?, ?)
            )
            """, arguments: [event.tool.rawValue, event.dedupKey,
                             event.legacyDedupKey ?? event.dedupKey]) ?? false
    }

    /// Repairs `local_sessions.model` where a zero-token placeholder set it (STEP_93, user
    /// ruling 2026-08-12): a session whose model reads `<synthetic>` — Claude Code's marker for
    /// a turn that died before the API, carried by zero-usage lines only — takes the model of
    /// its last event that actually carried usage, or NULL when no event can say (honest
    /// unknown; the display treats NULL as no model claim). Runs after enrichment so the
    /// per-event models it selects from exist. Narrow by design: only the placeholder string,
    /// nothing else, is repaired.
    ///
    /// Returns the number of session rows changed.
    public func repairPlaceholderSessionModels() throws -> Int {
        try withPool { pool in
            try pool.write { db in
                try db.execute(sql: """
                    UPDATE local_sessions
                    SET model = (
                        SELECT e.model FROM local_usage_events e
                        WHERE e.session_id = local_sessions.session_id
                          AND e.tool = local_sessions.tool
                          AND e.model IS NOT NULL
                          AND (e.input_tokens + e.output_tokens
                               + e.cache_creation_tokens + e.cache_read_tokens) > 0
                        ORDER BY e.recorded_at DESC LIMIT 1
                    )
                    WHERE model = '<synthetic>'
                    """)
                return db.changesCount
            }
        }
    }

}
