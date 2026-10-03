import XCTest
@testable import KvotarCore

/// Read-only live diagnostics for `EstimatedValueEngine` — run manually against the real
/// machine to validate Step 13 against real accumulated data before engines/UI wire it up.
///
/// Not part of the normal suite: gated on `KVOTAR_LIVE=1`, same convention as the adapter
/// packages' `LiveDiagnostics.swift`. Nothing here writes or mutates anything — it points the
/// engine at the real on-disk database and the real `Resources/pricing.json`. Invoke with:
///
///     KVOTAR_LIVE=1 swift test --filter LiveDiagnostics
final class LiveDiagnostics: XCTestCase {

    private func requireLive() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KVOTAR_LIVE"] == "1",
                          "set KVOTAR_LIVE=1 to run live diagnostics")
    }

    /// Bundle over the repo-root `Resources/` directory — the real `pricing.json` is bundled
    /// into the app target (not the `KvotarCore` package), so it's addressed directly here.
    private func repoResourcesBundle() throws -> Bundle {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() } // .../KvotarCoreTests/Tests/KvotarCore/Packages/<repo root>
        let resourcesDir = url.appendingPathComponent("Resources", isDirectory: true)
        return try XCTUnwrap(Bundle(url: resourcesDir))
    }

    func testLiveEstimatedValueAgainstRealDatabase() async throws {
        try requireLive()

        let store = try SQLiteStore(path: SQLiteStore.defaultPath())
        let engine = EstimatedValueEngine(store: store, bundle: try repoResourcesBundle())
        await engine.loadPricingTable()

        print("\n──────── Est. token value (live SQLite + real pricing.json) ────────")
        for tool in Tool.allCases {
            let value = try await engine.estimatedValue(for: tool)
            print("\(tool.rawValue): weekly=\(fmt(value.weekly)) "
                + "30-day=\(fmt(value.thirtyDay)) today=\(fmt(value.today))")
        }
        print("(Any model strings absent from pricing.json should have logged a WARNING above "
            + "via EstimatedValueEngine — check Console.app or ~/Library/Logs/Kvotar/kvotar.log.)")
        print("───────────────────────────────────────────────────────────────────\n")
    }

    /// STEP_91: the three numbers the Codex card shows, produced by the **real** engines over the
    /// **real** database and the **real** `pricing.json` — the displayed token count (§4, per tool),
    /// the cache-hit ratio (§8.4), and the window / 7-day / 30-day dollars (§12). Read-only.
    func testLiveLocalCardFiguresForBothTools() async throws {
        try requireLive()

        let store = try SQLiteStore(path: SQLiteStore.defaultPath())
        let engine = AttributionEngine(store: store, claude: NoopLocalAdapter(),
                                       codex: NoopLocalAdapter(), bundle: try repoResourcesBundle())
        // `start()` is what loads the table in production; the no-op adapters make it safe here
        // (no watchers over the user's real JSONL tree).
        await engine.start()
        defer { Task { await engine.stop() } }
        let stamp = await engine.pricingTableStamp()
        print("\npricing table: \(stamp.map { "\($0.version) (updated \($0.updated))" } ?? "unavailable")")
        let now = Date()

        print("\n──────── Local card figures (live SQLite + shipped pricing.json) ────────")
        for tool in Tool.allCases {
            // The card's own window: the newest persisted quota anchor, at the width the provider
            // reported (REV-60 — STEP_90). Falls back to the engine's own §3.3 resolution.
            // Width read from the environment, same convention as the STEP_90 probe above, so
            // this stays a diagnostic rather than a second source of truth for the window rule.
            let key = "KVOTAR_LIVE_WIDTH_\(tool.rawValue.uppercased())"
            let width = ProcessInfo.processInfo.environment[key].flatMap(TimeInterval.init)
                ?? OffMachineEstimator.fallbackWindowSeconds
            let anchor = try? await store.latestQuotaSeriesPoint(tool: tool)
            let windowStart = anchor?.resetsAt.addingTimeInterval(-width)
            guard let attr = await engine.attribution(for: tool, windowStart: windowStart, now: now) else {
                print("\(tool.rawValue): no local attribution")
                continue
            }
            let displayed = attr.modelTotals.reduce(0) { sum, t in
                switch tool {
                case .claude: return sum + t.inputTokens + t.outputTokens
                                       + t.cacheCreationTokens + t.cacheReadTokens
                case .codex:  return sum + t.inputTokens + t.outputTokens
                }
            }
            print("\(tool.rawValue): window_start=\(windowStart.map { ISO8601DateFormatter().string(from: $0) } ?? "—")")
            print("  displayed tokens (§4)   \(displayed)")
            print("  cache hit (§8.4)        \(attr.cacheHitRatio.map { String(format: "%.2f%%", $0 * 100) } ?? "—")")
            print("  this window             \(fmt(attr.windowValue))")
            print("  7-day / 30-day          \(fmt(attr.estValue.weekly)) / \(fmt(attr.estValue.thirtyDay))")
            for t in attr.modelTotals.sorted(by: { $0.inputTokens > $1.inputTokens }) {
                print("    \(t.model ?? "unknown"): in=\(t.inputTokens) out=\(t.outputTokens) "
                    + "cc=\(t.cacheCreationTokens) cr=\(t.cacheReadTokens) "
                    + "cached=\(t.codexCachedInputTokens)")
            }
        }
        print("──────────────────────────────────────────────────────────────────────\n")
    }

    /// A `LocalAdapter` that watches nothing — the live probe reads persisted rows only and must
    /// not start file watchers against the user's real JSONL tree.
    private struct NoopLocalAdapter: LocalAdapter {
        let tokenEvents: AsyncStream<[TokenEvent]>
        let deltaSignals: AsyncStream<LocalDeltaSignal>
        let localWrites: AsyncStream<Date>
        init() {
            (tokenEvents, _) = AsyncStream.makeStream(of: [TokenEvent].self)
            (deltaSignals, _) = AsyncStream.makeStream(of: LocalDeltaSignal.self)
            (localWrites, _) = AsyncStream.makeStream(of: Date.self)
        }
        func startWatching() async {}
        func stopWatching() async {}
    }

    private func fmt(_ value: Double) -> String {
        String(format: "$%.4f", value)
    }

    /// Read-only live check for REV-60 / STEP_90: run the real `OffMachineEstimator` over the real
    /// database, for each tool's newest persisted window, at both the **reported** width and the
    /// five-hour constant the app used before. On a 300-minute or Claude window the two must be
    /// identical; on the `go` account's 43,200-minute window they must differ, and the reported
    /// width is the one that finds the local turns.
    /// STEP_177: today's daily local report over the **real** database, reconciled against the
    /// existing per-model read for the same `[startOfDay, now)` span. Read-only; prints the
    /// grouped rows the popover will show, never a session file.
    func testLiveDailyLocalReportReconciles() async throws {
        try requireLive()

        let store = try SQLiteStore(path: SQLiteStore.defaultPath())
        let engine = AttributionEngine(store: store, claude: NoopLocalAdapter(),
                                       codex: NoopLocalAdapter(), bundle: try repoResourcesBundle())
        await engine.start()
        defer { Task { await engine.stop() } }
        let now = Date()
        print("\n──────── Daily local report (live SQLite) ────────")
        for tool in Tool.allCases {
            let report = try await engine.dailyReport(for: tool, now: now, calendar: .current)
            let byModel = try await store.tokenTotalsByModel(tool: tool, since: report.dayStart,
                                                             until: now)
            XCTAssertEqual(report.totalTokens, DisplayedTokens.total(byModel, tool: tool),
                           "\(tool.rawValue): report total must equal the per-model read")
            XCTAssertEqual(report.projects.reduce(0) { $0 + $1.tokens }, report.totalTokens)
            let sel = report.selection()
            print("\(tool.rawValue): tokens=\(report.totalTokens) sessions=\(report.sessionCount) "
                + "cache=\(report.cacheHitRatio.map { String(format: "%.0f%%", $0 * 100) } ?? "—") "
                + "value=\(fmt(report.value)) projects=\(report.projects.count) more=\(sel.moreCount)")
            for (i, p) in sel.rows.enumerated() {
                let recent = sel.mostRecentIndex == i ? " ◷" : ""
                print("  \(p.name.map { ($0 as NSString).lastPathComponent } ?? "(no project)")\(recent) "
                    + "\(p.tokens) · " + p.models.map { "\($0.model ?? "unknown")=\($0.tokens)" }
                        .joined(separator: " "))
            }
        }
        print("──────────────────────────────────────────────────\n")
    }

    func testLiveWindowAttributionAtTheReportedWidth() async throws {
        try requireLive()

        let store = try SQLiteStore(path: SQLiteStore.defaultPath())
        let now = Date()
        print("\n──────── Window attribution by width (live SQLite, read-only) ────────")
        for tool in Tool.allCases {
            guard let latest = try await store.latestQuotaSeriesPoint(tool: tool) else {
                print("\(tool.rawValue): no quota_series rows")
                continue
            }
            // The width the app is actually running on, read from the environment so this stays
            // a diagnostic rather than a second source of truth.
            let key = "KVOTAR_LIVE_WIDTH_\(tool.rawValue.uppercased())"
            let reported = ProcessInfo.processInfo.environment[key].flatMap(TimeInterval.init)
                ?? OffMachineEstimator.fallbackWindowSeconds
            for (label, width) in [("reported", reported),
                                   ("five-hour (pre-REV-60)", OffMachineEstimator.fallbackWindowSeconds)] {
                let e = OffMachineEstimator(store: store)
                let r = await e.record(tool: tool, resetsAt: latest.resetsAt, windowSeconds: width,
                                       currentUsedPct: latest.usedPct, now: now)
                print("\(tool.rawValue) [\(label), \(Int(width))s] "
                    + "window=\(latest.resetsAt.addingTimeInterval(-width)) "
                    + "local=\(fmtPct(r?.localPct)) off=\(fmtPct(r?.offMachinePct)) "
                    + "notObserved=\(fmtPct(r?.unattributedPct)) total=\(fmtPct(r?.totalUsedPct))")
            }
        }
        print("─────────────────────────────────────────────────────────────────────\n")
    }

    private func fmtPct(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0) } ?? "—"
    }

    /// STEP_114 — the REV-69 A1 check: over the stored history, do the per-model "work per 1 %"
    /// rates agree within a cycle when nothing changed? Prints every point of both slots for both
    /// tools with its per-model rates, coverage, unexplained share and cross-window ratio, over
    /// `watchingSince…now` (not just the 30-day window). Read-only. `KVOTAR_LIVE_DB` points it
    /// at a **copy** of the live database (memory: test against real data — never the live file
    /// while the app is writing it):
    ///
    ///     KVOTAR_LIVE=1 KVOTAR_LIVE_DB=/path/copy.db swift test --filter LiveDiagnostics/testLiveWorkPerPercentSeriesA1
    func testLiveWorkPerPercentSeriesA1() async throws {
        try requireLive()
        let path = try ProcessInfo.processInfo.environment["KVOTAR_LIVE_DB"] ?? SQLiteStore.defaultPath()
        let store = try SQLiteStore(path: path)
        let engine = EstimatedValueEngine(store: store, bundle: try repoResourcesBundle())
        await engine.loadPricingTable()
        let reader = HistoryReportReader(store: store, valueEngine: engine)
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone(identifier: "UTC")

        print("\n──────── Work per 1 % of window — A1 (\(path)) ────────")
        for tool in Tool.allCases {
            let since = (try? await store.watchingSince(tool: tool)) ?? nil
            guard let since else { print("\(tool.rawValue): no rollups"); continue }
            let series = await reader.workPerPercentSeries(tool: tool, from: since, until: now)
            print("\n\(tool.rawValue) — since \(iso.string(from: since))")
            for slot in series.slots {
                print("  slot \(slot.isPrimary ? "primary" : "secondary") width=\(slot.windowSeconds.map(String.init) ?? "?") byDay=\(slot.byDay) points=\(slot.points.count)")
                for p in slot.points {
                    let rate = p.dollarsPerPct.map { String(format: "%.2f", $0) } ?? "—"
                    let tok = p.tokensPerPct.map { String(format: "%.0f", $0) } ?? "—"
                    let cov = p.coverage.map { String(format: "%.2f", $0) } ?? "—"
                    let unx = p.unexplainedShare.map { String(format: "%.2f", $0) } ?? "—"
                    let ratio = p.crossWindowRatio.map { String(format: "%.3f", $0) } ?? "—"
                    let models = p.perModel.map {
                        "\($0.model ?? "?")=\(String(format: "%.2f", $0.dollarsPerPct))/\(String(format: "%.0f", $0.deltaPct))pt"
                    }.joined(separator: " ")
                    print("    \(iso.string(from: p.start))…\(iso.string(from: p.end))\(p.isComplete ? "" : " (so far)")"
                        + " Δ=\(String(format: "%.0f", p.deltaPct))% $=\(String(format: "%.2f", p.dollars))"
                        + " $/1%=\(rate) tok/1%=\(tok) cov=\(cov) unexpl=\(unx) ratio=\(ratio) | \(models)")
                }
            }
            for m in series.markers {
                print("  marker \(iso.string(from: m.at)) \(m.eventType) \(m.windowType ?? "") \(m.oldValue ?? "∅")→\(m.newValue ?? "∅")")
            }
        }
        print("─────────────────────────────────────────────────────────\n")
    }

    /// STEP_122 (REV-74/D-84): replay the **real** `quota_series` for a tool through a fresh
    /// `ForecastEngine` and print what the buffer held at every poll — under the window's own
    /// policy and under the five-hour one, side by side. This is the only way to see the change:
    /// `forecast_log` records no sample count and no span (deliberately — `ForecastLogRecorder`'s
    /// "deliberately absent" note), and the engine's one INFO line fires once per process.
    ///
    /// Read-only, and it takes the width from `poll_snapshots` rather than restating it. Point it
    /// at a **copy** of the live database:
    ///
    ///     KVOTAR_LIVE=1 KVOTAR_LIVE_DB=/tmp/copy.db \
    ///       swift test --filter LiveDiagnostics/testLiveBurnBufferReplay
    func testLiveBurnBufferReplay() async throws {
        try requireLive()
        let env = ProcessInfo.processInfo.environment
        let store = try SQLiteStore(path: env["KVOTAR_LIVE_DB"] ?? SQLiteStore.defaultPath())
        let iso = DateFormatter()
        iso.dateFormat = "MM-dd HH:mm"

        for tool in Tool.allCases {
            guard let anchor = try await store.latestQuotaSeriesPoint(tool: tool) else {
                print("\n\(tool.rawValue): no quota_series rows"); continue
            }
            let rows = try await store.quotaSeries(tool: tool, resetsAtNear: anchor.resetsAt)
            let width = try await store.readLatestPollSnapshot(tool: tool)?.snapshot.primaryWindowSeconds
            let policy = ForecastEngine.bufferPolicy(
                windowLength: TimeInterval(width ?? 18_000))
            let isLong = policy.countCap == ForecastEngine.longWindowBuffer.countCap

            print("\n──────── Burn buffer replay · \(tool.rawValue) ────────")
            print("window width: \(width.map { "\($0)s" } ?? "unstated → 18000s") "
                + "→ \(isLong ? "LONG" : "SHORT") policy "
                + "(cap \(policy.countCap), proof \(Int(policy.zeroProofSpan))s, "
                + "floor \(Int(policy.retentionSpan))s)")
            print("\(rows.count) polls in the current window, from \(iso.string(from: anchor.resetsAt))'s window")
            print("     time    used%    now: n / span / rate      five-hour: n / span / rate")

            let live = ForecastEngine()
            let short = ForecastEngine()
            for (i, row) in rows.enumerated() {
                let snap = { (w: Int?) in
                    QuotaSnapshot(tool: tool, primaryUsedPct: row.usedPct,
                                  primaryResetsAt: row.resetsAt, primaryWindowSeconds: w,
                                  secondaryUsedPct: nil, secondaryResetsAt: nil,
                                  rateLimitReached: false)
                }
                let a = await live.record(snapshot: snap(width), at: row.polledAt)
                let b = await short.record(snapshot: snap(nil), at: row.polledAt)
                // Every row is noise on a busy window; print the last 40 and every 10th before.
                guard i >= rows.count - 40 || i % 10 == 0 else { continue }
                func cell(_ f: Forecast) -> String {
                    let span = f.burnSpanMinutes.map { String(format: "%4.0fm", $0) } ?? "   —"
                    let rate = f.burnRatePerMin.map { String(format: "%7.4f", $0) } ?? "      —"
                    return String(format: "%3d /%@ /%@", f.pollCount, span, rate)
                }
                print("  \(iso.string(from: row.polledAt))  \(String(format: "%5.1f", row.usedPct))"
                    + "    \(cell(a))      \(cell(b))")
            }
        }
        print("──────────────────────────────────────────────────────\n")
    }

    // MARK: - Quota-window outcomes (STEP_181 — REV-93 §4)

    /// The thirty-day quota-window fold over a real corpus, which is the only place its honesty
    /// can be judged: fixtures cannot show how often a window is genuinely unwatched at its close.
    ///
    /// Points at **`KVOTAR_LIVE_DB`**, not `defaultPath()`, and the value must be a *copy* —
    /// opening a store runs migrations, and a diagnostic must never be the thing that migrates the
    /// machine's own database. Run with:
    ///
    ///     KVOTAR_LIVE=1 KVOTAR_LIVE_DB=/path/to/copy.db swift test --filter testLiveQuotaWindowOutcomes
    func testLiveQuotaWindowOutcomes() async throws {
        try requireLive()
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["KVOTAR_LIVE_DB"],
                                 "set KVOTAR_LIVE_DB to a copy of the database")
        XCTAssertNotEqual(path, try SQLiteStore.defaultPath(),
                          "never run this against the live file")

        let store = try SQLiteStore(path: path)
        let now = Date()
        let since = now.addingTimeInterval(-TimeInterval(HistoryReport.periodDays) * 86_400)
        let iso = ISO8601DateFormatter()

        print("\n──────── quota-window outcomes, \(HistoryReport.periodDays)d ────────")
        for tool in Tool.allCases {
            let points = try await store.quotaSeriesRange(tool: tool, since: since, until: now)
            let facts = try await store.discontinuityEvents(
                tool: tool, since: since, until: now,
                types: QuotaWindowOutcomes.evidenceEventTypes)
            let windows = QuotaWindowOutcomes.compute(tool: tool, points: points,
                                                      discontinuities: facts, now: now)
            let full = windows.filter { $0.completion == .completedFull }
            let partial = windows.filter { $0.completion == .completedPartial }
            let current = windows.filter { $0.completion == .current }
            let widths = Set(windows.compactMap(\.windowSeconds)).sorted()
            print("\n\(tool.rawValue): \(points.count) rows → \(windows.count) windows"
                + "  full=\(full.count) partial=\(partial.count) current=\(current.count)")
            print("  widths recorded: \(widths.isEmpty ? "none (all pre-v23)" : "\(widths)")"
                + "  unknown-width windows: \(windows.filter { $0.windowSeconds == nil }.count)")
            let evidence = Dictionary(grouping: windows, by: \.widthEvidence)
                .map { "\($0.key.rawValue)=\($0.value.count)" }.sorted().joined(separator: " ")
            print("  width evidence: \(evidence)")
            print("  hit the limit: \(windows.filter { $0.hitLimitAt != nil }.count)"
                + "  early reset: \(windows.filter { $0.ending == .earlyReset }.count)"
                + "  withdrawn: \(windows.filter { $0.ending == .withdrawn }.count)")
            for w in windows.suffix(6) {
                let width = w.windowSeconds.map { "\($0 / 3600)h" } ?? "—"
                print("  \(iso.string(from: w.resetsAt))  \(String(format: "%5.1f%%", w.highWaterPct))"
                    + "  \(w.completion.rawValue)  width=\(width)  n=\(w.observationCount)")
            }
        }
        print("────────────────────────────────────────────────────\n")
    }
}
