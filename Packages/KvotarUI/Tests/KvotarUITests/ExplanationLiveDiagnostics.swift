import XCTest
import KvotarCore
@testable import KvotarUI

/// Read-only live diagnostic for the explanation layer (STEP_130 — REV-75/D-88 + D-90). The
/// popover only renders on a real user click, so this is where the shipped cards are checkable
/// against a real account: build both tabs' display states from a database through the same
/// `DisplayFormatter` entry points the popover calls, then print **every tagged element** as it
/// would be explained — site, label, value, concept card, and the live line **or the reason it
/// was dropped**.
///
/// The drop reasons are the point. A live line that falls back is supposed to leave no trace on
/// screen (rule 4); this is the one surface where it says why, and it is the same information
/// `explanation-snapshot.json` will carry to a tester's bundle (D-93, STEP_133).
///
///     KVOTAR_LIVE=1 swift test --filter ExplanationLiveDiagnostics
///     KVOTAR_LIVE=1 KVOTAR_LIVE_DB=/path/to/copy.db swift test --filter ExplanationLiveDiagnostics
///
/// **Point it at a copy, never at a bundle's own file** (REV-75 §8a): `SQLiteStore(path:)`
/// migrates the database it opens, in place, and `openReadOnly` refuses a July schema — so the
/// test copies whatever it is given (with `-wal` / `-shm` if present) into the temporary
/// directory and opens the copy. Running it against `~/Downloads/AgentPilot-diagnostics-…`
/// therefore rewrites nothing.
final class ExplanationLiveDiagnostics: XCTestCase {

    /// The report, collected rather than printed straight out: a run of this size overruns the
    /// test runner's stdout buffering and loses its earlier blocks. Written to `KVOTAR_LIVE_OUT`
    /// (default: a file in the temporary directory, whose path is the last thing printed) so the
    /// whole thing survives to be pasted into the step notes.
    private var report: [String] = []
    private func emit(_ line: String) { report.append(line) }

    // MARK: The copy rule (REV-75 §8a)

    /// Copy `path` and its WAL siblings into a fresh temporary directory and return the copy.
    private func copiedDatabase(_ path: String) throws -> String {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("kvotar-live-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: path)
        let destination = dir.appendingPathComponent(source.lastPathComponent)
        try fm.copyItem(at: source, to: destination)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: path + suffix)
            if fm.fileExists(atPath: sidecar.path) {
                try fm.copyItem(at: sidecar,
                                to: dir.appendingPathComponent(sidecar.lastPathComponent))
            }
        }
        return destination.path
    }

    // MARK: Printing

    private func describe(_ live: ExplanationLive?) -> String {
        switch live {
        case nil:                    return "(no live line — inert)"
        case .shown(let text)?:      return "live: \(text)"
        case .dropped(let reason)?:  return "dropped: \(reason.rawValue)"
        }
    }

    private func show(_ site: String, _ element: ExplanationElement?, label: String, value: String,
                      live: ExplanationLive?, bridge: ExplanationLive? = nil,
                      tool: Tool, grain: String?) {
        guard let element else { return }   // untagged rows are inert by rule 1
        let card = ExplanationRegistry.card(element, tool: tool, grain: grain)
        emit("  \(element.specID)  \(site) · \(label) = \(value)")
        // §5.2 rule 8 (REV-77): a percentage element's card opens with the bridge line.
        if let bridge { emit("        bridge: \(bridge.text ?? "(dropped)")") }
        emit("        card: \(card ?? "(none — E-08 carries its whole card in the live slot)")")
        emit("        \(describe(live))")
    }

    private func showRows(_ site: String, _ rows: [LabeledRow]?, tool: Tool, grain: String?) {
        for row in rows ?? [] {
            show(site, row.explanation, label: row.label, value: row.value,
                 live: row.explanationLive, bridge: row.explanationBridge, tool: tool, grain: grain)
        }
    }

    private func showHeaderAndVerdict(_ header: HeaderSection?, tool: Tool, grain: String?) {
        guard let header else { return }
        show("header hero", header.heroExplanation, label: "hero", value: header.heroText,
             live: header.heroLive, bridge: header.heroBridge, tool: tool, grain: grain)
        if let caption = header.limitCaption, header.limit?.id == .primaryWindow {
            show("caption", .primaryWindow, label: "caption", value: caption,
                 live: header.windowScopeLive, tool: tool, grain: grain)
        }
        for detail in header.heroDetails {
            guard let element = detail.explanation else { continue }
            show("hero detail", element, label: "detail", value: detail.text, live: nil,
                 tool: tool, grain: grain)
        }
        for fact in [header.accountBurn, header.notSeenLocally].compactMap({ $0 })
        where fact.isApplicable {
            show("header fact", fact.explanation, label: fact.label, value: fact.value,
                 live: nil, tool: tool, grain: grain)
        }
        guard let verdict = header.verdict else {
            emit("  (verdict row removed on this shape — D-60)"); return
        }
        emit("  ——  verdict [\(verdict.family.rawValue)] \(verdict.line1)")
        show("verdict line 2", .verdictDetail, label: "line 2", value: verdict.line2 ?? "(removed)",
             live: verdict.detailLive, tool: tool, grain: grain)
    }

    private func showOtherLimits(_ section: OtherLimitsSection?, tool: Tool, grain: String?) {
        guard let section else { return }
        for row in section.rows + section.modelGroups.flatMap(\.rows) {
            show("other limits", row.explanation, label: row.label, value: row.value,
                 live: row.explanationLive, bridge: row.explanationBridge,
                 tool: tool, grain: grain)
            if let element = row.resetExplanation, let reset = row.reset {
                show("other limits", element, label: "\(row.label) reset", value: reset,
                     live: nil, tool: tool, grain: grain)
            }
            if let meta = row.meta, let element = meta.explanation {
                show("other limits", element, label: "\(row.label) pace", value: meta.text,
                     live: nil, tool: tool, grain: grain)
            }
        }
    }

    private func showLocalActivity(_ section: LocalActivitySection?, tool: Tool, grain: String?) {
        guard let section else { return }
        if let summary = section.summary {
            show("local activity", .localActivity, label: summary.label, value: summary.value, live: nil,
                 tool: tool, grain: grain)
        }
        show("local activity", .cacheHit, label: LocalActivitySection.cacheHitLabel,
             value: section.cacheHit, live: nil, tool: tool, grain: grain)
        for (index, row) in section.valueRows.enumerated() {
            show("estimated value", index == 0 ? .estTokenValue : .rollingHorizons,
                 label: row.label, value: row.value, live: nil, tool: tool, grain: grain)
        }
    }

    // MARK: The run

    func testLiveExplanationLayer() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["KVOTAR_LIVE"] == "1", "set KVOTAR_LIVE=1 to run live diagnostics")
        let given = try env["KVOTAR_LIVE_DB"] ?? SQLiteStore.defaultPath()
        let path = try copiedDatabase(given)
        let store = try SQLiteStore(path: path)
        let now = Date()
        emit("\n════════ Explanation layer · \(given)")
        emit("         (opened on a copy at \(path) — §8a: the migrating initializer rewrites it)")

        let offMachine = OffMachineEstimator(store: store)
        let monthlyAttr = MonthlyAttributionEstimator(store: store)

        for tool in Tool.allCases {
            emit("\n──────── \(tool.rawValue) ────────")
            guard let latest = try await store.readLatestPollSnapshot(tool: tool) else {
                emit("  no poll_snapshots rows"); continue
            }
            let snapshot = latest.snapshot
            let grain = DisplayFormatter.windowGrain(seconds: snapshot.primaryWindowSeconds)
            emit("  plan=\(snapshot.planType ?? "—")"
                + "  used=\(snapshot.primaryUsedPct.map { "\($0)%" } ?? "—")"
                + "  weekly=\(snapshot.secondaryUsedPct.map { "\($0)%" } ?? "—")"
                + "  width=\(snapshot.primaryWindowSeconds.map(String.init) ?? "unstated")"
                + "  monthly=\(snapshot.monthlyLimit == nil ? "no" : "yes")"
                + "  polled \(latest.polledAt)")

            // The live forecast, rebuilt the way the app has it: every point of the current
            // window through a real engine (the `BurnCardLiveDiagnostics` shape, STEP_123).
            var forecast: Forecast?
            if let anchor = try await store.latestQuotaSeriesPoint(tool: tool) {
                let rows = try await store.quotaSeries(tool: tool, resetsAtNear: anchor.resetsAt)
                let engine = ForecastEngine()
                for row in rows {
                    forecast = await engine.record(
                        snapshot: QuotaSnapshot(tool: tool, primaryUsedPct: row.usedPct,
                                                primaryResetsAt: row.resetsAt,
                                                primaryWindowSeconds: snapshot.primaryWindowSeconds,
                                                secondaryUsedPct: nil, secondaryResetsAt: nil,
                                                rateLimitReached: false),
                        at: row.polledAt)
                }
                emit("  forecast: \(rows.count) polls replayed → "
                    + "burn \(forecast?.burnRatePerMin.map { String(format: "%.4f", $0) } ?? "—") %/min"
                    + ", runway \(forecast?.runwayMinutes.map { String(format: "%.0f", $0) } ?? "—") min")
            } else {
                emit("  forecast: no quota_series for a current window "
                    + "(E-04·runway and the runway E-08 rows will drop — the drop path working)")
            }

            // E-07 and E-18…E-20 replayed from the copy's own rows, read-only.
            let window = await offMachine.current(for: tool, now: now)
            let monthly = await monthlyAttr.current(for: tool)
            let windowText = window.map { w in
                "total \(w.totalUsedPct)% = local \(w.localPct)% + off \(w.offMachinePct)%"
                    + " + unattributed \(w.unattributedPct)%"
            } ?? "(none)"
            let monthlyText = monthly.map { m in
                "local \(m.localAmount) · elsewhere \(m.offMachineAmount)"
                    + " · unattributed \(m.unattributedAmount)"
            } ?? "(none)"
            emit("  window split: \(windowText)")
            emit("  monthly split: \(monthlyText)")

            switch tool {
            case .claude:
                let state = DisplayFormatter.claude(
                    state: .healthy, snapshot: snapshot, forecast: forecast,
                    offMachine: window, pollAsOf: latest.polledAt,
                    monthlyAttribution: monthly, now: now)
                showHeaderAndVerdict(state.header, tool: tool, grain: grain)
                showOtherLimits(state.otherLimits, tool: tool, grain: grain)
                showLocalActivity(state.localActivity, tool: tool, grain: grain)
                if let credits = state.creditsCard {
                    show("credits card", credits.status.explanation, label: credits.status.label,
                         value: credits.status.value, live: credits.status.explanationLive,
                         tool: tool, grain: grain)
                    showRows("credits card", credits.rows, tool: tool, grain: grain)
                }
            case .codex:
                let state = DisplayFormatter.codex(
                    state: .healthy, snapshot: snapshot, forecast: forecast,
                    offMachine: window, pollAsOf: latest.polledAt,
                    monthlyAttribution: monthly, now: now)
                showHeaderAndVerdict(state.header, tool: tool, grain: grain)
                showOtherLimits(state.otherLimits, tool: tool, grain: grain)
                showLocalActivity(state.localActivity, tool: tool, grain: grain)
                showRows("credits / spend", state.creditsSpend?.rows, tool: tool, grain: grain)
            }
        }
        emit("\n════════════════════════════════════════════════════════\n")

        let text = report.joined(separator: "\n")
        let out = env["KVOTAR_LIVE_OUT"] ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("explanation-live.txt").path
        try text.write(toFile: out, atomically: true, encoding: .utf8)
        print(text)
        print("── full report written to \(out)")
    }
}
