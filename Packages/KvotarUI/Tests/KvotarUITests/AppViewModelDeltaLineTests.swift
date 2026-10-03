import XCTest
import KvotarCore
@testable import KvotarUI

/// The "Since you last looked" lifecycle on the view model (UI Spec Part 1 §2.8, D-75 — STEP_112):
/// displaying a tab takes and persists the snapshot, the line renders once per qualifying display,
/// `✕` and close clear it, staleness silences it (Baseline §19 *delta-stale*), and the boundary
/// form waits for the injected `quota_series` read.
@MainActor
final class AppViewModelDeltaLineTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var later: Date { now.addingTimeInterval(600) }

    private func snapshot(used: Double?, resetsIn: TimeInterval = 2 * 3600) -> QuotaSnapshot {
        QuotaSnapshot(tool: .claude, primaryUsedPct: used,
                      primaryResetsAt: used == nil ? nil : now.addingTimeInterval(resetsIn),
                      primaryWindowSeconds: 18_000,
                      secondaryUsedPct: used == nil ? nil : 14, secondaryResetsAt: nil,
                      rateLimitReached: false, extraUsage: .disabled, planType: "Pro")
    }

    private func forecast(burn: Double? = 0.4) -> Forecast {
        Forecast(tool: .claude, tier: .fullRunway, runwayMinutes: nil,
                 burnRatePerMin: burn, isEstimate: false, pollCount: 5)
    }

    private func attribution(subagents: Int) -> LocalAttribution {
        LocalAttribution(project: "/p", model: nil, surfaceBucket: nil, subagentCount: subagents,
                         cacheHitRatio: nil,
                         estValue: EstimatedValueEngine.WindowValue(weekly: 0, thirtyDay: 0),
                         surfaceShares: [], tokensPerMinute: nil, lastActivityAt: nil)
    }

    func testFirstDisplayWritesSnapshotAndShowsNoLine() {
        var persisted: [(Tool, String)] = []
        let vm = AppViewModel()
        vm.onPersistLastOpenSnapshot = { persisted.append(($0, $1)) }
        vm.apply(tool: .claude, snapshot: snapshot(used: 40), forecast: forecast(),
                 state: .healthy, localAttribution: attribution(subagents: 0), now: now)
        vm.selectDefaultTab(now: now)
        XCTAssertEqual(vm.activeTab, .claude)
        XCTAssertNil(vm.deltaLines[.claude], "absent snapshot → no line")
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.0, .claude)
        let written = try? XCTUnwrap(LastOpenSnapshot(json: persisted.first?.1 ?? ""))
        XCTAssertEqual(written?.usedPct, 40)
        XCTAssertEqual(written?.agentCount, 0)
        XCTAssertEqual(written?.verdictFamily, vm.claudeState.header?.verdict?.family.rawValue)
        XCTAssertEqual(written?.pctVisibleInMenuBar, true, "both_stacked shows the percentage")
    }

    func testSecondDisplayWithASubagentSpawnedRendersTheLine() {
        var persisted: [(Tool, String)] = []
        let vm = AppViewModel()
        vm.onPersistLastOpenSnapshot = { persisted.append(($0, $1)) }
        vm.apply(tool: .claude, snapshot: snapshot(used: 40), forecast: forecast(),
                 state: .healthy, localAttribution: attribution(subagents: 0), now: now)
        vm.selectDefaultTab(now: now)
        vm.popoverDidClose()
        // Between the looks: one subagent spawned, +3% (context only — the menu bar showed it).
        vm.apply(tool: .claude, snapshot: snapshot(used: 43), forecast: forecast(),
                 state: .healthy, localAttribution: attribution(subagents: 1), now: later)
        vm.selectDefaultTab(now: later)
        XCTAssertEqual(vm.deltaLines[.claude],
                       "Since \(Fmt.clock(now)): 1 subagent spawned · 3% burned")
        XCTAssertEqual(persisted.count, 2, "every display persists")
        // A third look with nothing new: silent, and the earlier line is not repeated.
        vm.popoverDidClose()
        vm.selectDefaultTab(now: later.addingTimeInterval(60))
        XCTAssertNil(vm.deltaLines[.claude], "the line never repeats")
    }

    /// Baseline §19 *delta-stale*: a stale render never carries the line — but it still writes the
    /// snapshot, so the next live look compares against what was actually shown.
    func testStaleRenderIsSilentButStillSnapshots() {
        var persisted: [(Tool, String)] = []
        let vm = AppViewModel()
        vm.onPersistLastOpenSnapshot = { persisted.append(($0, $1)) }
        vm.apply(tool: .claude, snapshot: snapshot(used: 40), forecast: forecast(),
                 state: .healthy, localAttribution: attribution(subagents: 0), now: now)
        vm.selectDefaultTab(now: now)
        vm.popoverDidClose()
        vm.applyCached(tool: .claude, state: .idleFallback, snapshot: snapshot(used: 40),
                       asOf: now.addingTimeInterval(-20 * 60),
                       localAttribution: attribution(subagents: 2), now: later)
        vm.selectDefaultTab(now: later)
        XCTAssertNil(vm.deltaLines[.claude], "stale render → never")
        XCTAssertEqual(persisted.count, 2)
    }

    func testNoRenderMeansNoSnapshotAndNoLine() {
        var persisted: [(Tool, String)] = []
        let vm = AppViewModel()
        vm.onPersistLastOpenSnapshot = { persisted.append(($0, $1)) }
        vm.selectDefaultTab(now: now)          // both tools still loading
        XCTAssertTrue(persisted.isEmpty, "the loading card shows nothing worth remembering")
        XCTAssertTrue(vm.deltaLines.isEmpty)
    }

    func testDismissAndCloseClearTheLine() {
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: snapshot(used: 40), forecast: forecast(),
                 state: .healthy, localAttribution: attribution(subagents: 0), now: now)
        vm.selectDefaultTab(now: now)
        vm.popoverDidClose()
        vm.apply(tool: .claude, snapshot: snapshot(used: 40), forecast: forecast(),
                 state: .healthy, localAttribution: attribution(subagents: 1), now: later)
        vm.selectDefaultTab(now: later)
        XCTAssertNotNil(vm.deltaLines[.claude])
        vm.dismissDeltaLine(.claude)
        XCTAssertNil(vm.deltaLines[.claude], "✕ hides it for this open")

        vm.apply(tool: .claude, snapshot: snapshot(used: 40), forecast: forecast(),
                 state: .healthy, localAttribution: attribution(subagents: 2), now: later)
        vm.selectDefaultTab(now: later.addingTimeInterval(60))
        XCTAssertNotNil(vm.deltaLines[.claude])
        vm.popoverDidClose()
        XCTAssertTrue(vm.deltaLines.isEmpty, "gone with the popover")
    }

    func testSeedFillsOnlyAnEmptySlot() {
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: snapshot(used: 40), forecast: forecast(),
                 state: .healthy, localAttribution: attribution(subagents: 1), now: now)
        // "Last launch" looked at the same render with no subagent, a minute earlier.
        let seeded = LastOpenSnapshot(takenAt: Int(now.timeIntervalSince1970) - 60,
                                      windowResetsAt: Int(now.timeIntervalSince1970) + 7_200,
                                      usedPct: 40,
                                      verdictFamily: vm.claudeState.header!.verdict!.family.rawValue,
                                      burnTier: vm.claudeState.header!.accountBurn!.tier!,
                                      agentCount: 0, pctVisibleInMenuBar: true)
        vm.seedLastOpenSnapshot(tool: .claude, json: seeded.encoded())
        // The seed is what the next display compares against: +1 subagent → line.
        vm.selectDefaultTab(now: now)
        XCTAssertEqual(vm.deltaLines[.claude],
                       "Since \(Fmt.clock(now.addingTimeInterval(-60))): 1 subagent spawned")
        // A late seed must not clobber the snapshot the open just took.
        vm.seedLastOpenSnapshot(tool: .claude, json: seeded.encoded())
        vm.popoverDidClose()
        vm.selectDefaultTab(now: later)
        XCTAssertNil(vm.deltaLines[.claude], "compared against the open's own snapshot, not the seed")
        // Garbage never seeds.
        let fresh = AppViewModel()
        fresh.seedLastOpenSnapshot(tool: .codex, json: "nope")
        XCTAssertNil(fresh.lastOpenSnapshot[.codex])
    }

    func testTapOnTheActiveTabIsNotANewLook() {
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: snapshot(used: 40), forecast: forecast(),
                 state: .healthy, localAttribution: attribution(subagents: 0), now: now)
        vm.selectDefaultTab(now: now)
        vm.popoverDidClose()
        vm.apply(tool: .claude, snapshot: snapshot(used: 40), forecast: forecast(),
                 state: .healthy, localAttribution: attribution(subagents: 1), now: later)
        vm.selectDefaultTab(now: later)
        XCTAssertNotNil(vm.deltaLines[.claude])
        vm.selectTab(.claude, now: later)
        XCTAssertNotNil(vm.deltaLines[.claude], "same tab — the line stays")
    }

    /// Window boundary: the line waits for the injected `quota_series` read and renders the
    /// previous window's outcome; a close in the meantime discards the result.
    func testBoundaryLineAwaitsTheWindowOutcomeRead() async {
        let vm = AppViewModel()
        let prevReset = now.addingTimeInterval(2 * 3600)
        var asked: [(Tool, Date?)] = []
        vm.loadWindowOutcome = { tool, before in
            asked.append((tool, before))
            return WindowOutcome(resetsAt: prevReset, highWaterPct: 94, hitLimitAt: nil)
        }
        vm.apply(tool: .claude, snapshot: snapshot(used: 40), forecast: forecast(),
                 state: .healthy, localAttribution: attribution(subagents: 0), now: now)
        vm.selectDefaultTab(now: now)
        vm.popoverDidClose()
        // Next look, three hours later: a new window (reset moved on by 5h), 3% used.
        let next = now.addingTimeInterval(3 * 3600)
        vm.apply(tool: .claude, snapshot: snapshot(used: 3, resetsIn: 7 * 3600),
                 forecast: forecast(), state: .healthy,
                 localAttribution: attribution(subagents: 5), now: next)
        vm.selectDefaultTab(now: next)
        // Let the MainActor task run.
        for _ in 0..<10 where vm.deltaLines[.claude] == nil { await Task.yield() }
        // `[t]` = the current window's start: reset at now + 7 h, 5-hour window ⇒ now + 2 h.
        XCTAssertEqual(vm.deltaLines[.claude],
                       "New window since \(Fmt.clock(now.addingTimeInterval(2 * 3600))) — last one ended at 94%")
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.1, now.addingTimeInterval(7 * 3600), "before = current reset")

        // Close before the read lands → nothing published.
        vm.popoverDidClose()
        vm.loadWindowOutcome = { _, _ in
            await Task.yield()
            return WindowOutcome(resetsAt: prevReset, highWaterPct: 94, hitLimitAt: nil)
        }
        vm.apply(tool: .claude, snapshot: snapshot(used: 3, resetsIn: 12 * 3600),
                 forecast: forecast(), state: .healthy,
                 localAttribution: attribution(subagents: 5), now: next)
        vm.selectDefaultTab(now: next.addingTimeInterval(60))
        vm.popoverDidClose()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(vm.deltaLines[.claude], "a read that lands after close is discarded")
    }

    /// **The rollover frame draws no verdict (D-123 — STEP_207), and the line must not go quiet
    /// with it.** This is the boundary form's own moment: the window that ended is the one thing
    /// the popover can say that the menu bar could not. It survives because the render names its
    /// family (`notStarted`) even with the row removed — read the absent row instead and the
    /// family is `unknown`, which is in the silent set, and the line disappears.
    func testRolloverIntoANotStartedWindowStillRendersTheBoundaryLine() async {
        let vm = AppViewModel()
        let prevReset = now.addingTimeInterval(2 * 3600)
        vm.loadWindowOutcome = { _, _ in
            WindowOutcome(resetsAt: prevReset, highWaterPct: 69, hitLimitAt: nil)
        }
        vm.apply(tool: .claude, snapshot: snapshot(used: 40), forecast: forecast(),
                 state: .healthy, localAttribution: attribution(subagents: 0), now: now)
        vm.selectDefaultTab(now: now)
        vm.popoverDidClose()
        // The window resets and no new one has started: `utilization: 0`, `resets_at: null`.
        let after = prevReset.addingTimeInterval(180)
        let rolled = QuotaSnapshot(tool: .claude, primaryUsedPct: 0, primaryResetsAt: nil,
                                   primaryWindowSeconds: 18_000,
                                   secondaryUsedPct: 14, secondaryResetsAt: nil,
                                   rateLimitReached: false, extraUsage: .disabled, planType: "Pro")
        vm.apply(tool: .claude, snapshot: rolled, forecast: forecast(burn: nil),
                 state: .healthy, localAttribution: attribution(subagents: 0), now: after)
        XCTAssertNil(vm.claudeState.header?.verdict, "the row is removed on this shape")
        XCTAssertEqual(vm.claudeState.header?.verdictFamily, .notStarted)
        vm.selectDefaultTab(now: after)
        for _ in 0..<10 where vm.deltaLines[.claude] == nil { await Task.yield() }
        XCTAssertEqual(vm.deltaLines[.claude],
                       "Last window ended at 69% — reset \(Fmt.clock(prevReset))")
    }

    /// Trigger 6 (STEP_146): with a facts loader wired, the line waits for the read, asks for the
    /// facts since the last look, and carries them — folded — even on an otherwise silent look.
    func testWindowFactsSinceTheLastLookRenderTheLine() async {
        let vm = AppViewModel()
        var asked: [(Tool, Date)] = []
        vm.loadWindowFacts = { tool, since in
            asked.append((tool, since))
            return [
                HistoryReport.AccountChange(at: since.addingTimeInterval(30), kind: .windowAdded,
                                            windowType: "weekly", newValue: "604800"),
                HistoryReport.AccountChange(at: since.addingTimeInterval(30),
                                            kind: .windowWidthChanged, windowType: "five_hour",
                                            oldValue: "604800", newValue: "18000"),
            ]
        }
        vm.apply(tool: .claude, snapshot: snapshot(used: 40), forecast: forecast(),
                 state: .healthy, localAttribution: attribution(subagents: 0), now: now)
        vm.selectDefaultTab(now: now)
        vm.popoverDidClose()
        // Same window, nothing else moved — silent without the facts.
        vm.apply(tool: .claude, snapshot: snapshot(used: 40), forecast: forecast(),
                 state: .healthy, localAttribution: attribution(subagents: 0), now: later)
        vm.selectDefaultTab(now: later)
        for _ in 0..<10 where vm.deltaLines[.claude] == nil { await Task.yield() }
        XCTAssertEqual(vm.deltaLines[.claude],
                       "Since \(Fmt.clock(now)): windows now 5-hour + weekly (was weekly)")
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.1, now, "since = the previous look")
    }
}
