import XCTest
import KvotarCore
@testable import KvotarUI

@MainActor
final class AppViewModelTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(tool: Tool, used: Double?) -> QuotaSnapshot {
        QuotaSnapshot(tool: tool, primaryUsedPct: used,
                      primaryResetsAt: used == nil ? nil : now.addingTimeInterval(2 * 3600),
                      secondaryUsedPct: used == nil ? nil : 14, secondaryResetsAt: nil,
                      rateLimitReached: false, extraUsage: .disabled, planType: "Pro")
    }

    private func forecast(_ tool: Tool, burn: Double? = 0.4) -> Forecast {
        Forecast(tool: tool, tier: .fullRunway, runwayMinutes: nil,
                 burnRatePerMin: burn, isEstimate: false, pollCount: 5)
    }

    func testLiveInitStartsLoading() {
        let vm = AppViewModel()
        XCTAssertEqual(vm.claudeState.phase, .loading)
        XCTAssertEqual(vm.codexState.phase, .loading)
        // Both-stacked default: one loading text line per tool (CL / CX), grey dots.
        XCTAssertEqual(vm.menuBarDisplayMode, .bothStacked)
        XCTAssertEqual(vm.menuBarRender.lines.count, 2)
        XCTAssertEqual(vm.menuBarRender.lines.map(\.text), ["CL …", "CX …"])
        XCTAssertTrue(vm.menuBarRender.lines.allSatisfy { $0.dot == .grey })
        XCTAssertFalse(vm.hasSucceeded(.claude))
    }

    func testApplyPopulatesTool() {
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: snapshot(tool: .claude, used: 38),
                 forecast: forecast(.claude), state: .healthy, now: now)
        XCTAssertEqual(vm.claudeState.phase, .content)
        XCTAssertEqual(vm.claudeState.header?.heroText, "62%", "remaining (REV-77 / D-97)")
        // Stacked: Claude's §1.1 row carries what is left, with its status dot.
        XCTAssertEqual(vm.menuBarRender.lines.first?.text.hasPrefix("CL 62%"), true)
        XCTAssertEqual(vm.menuBarRender.lines.first?.dot, .green)
        // The tab carries a dot and a name only since STEP_178 — no percentage to agree with.
        XCTAssertTrue(vm.hasSucceeded(.claude))
        // Codex is untouched — tools populate independently.
        XCTAssertEqual(vm.codexState.phase, .loading)
    }

    // MARK: applyCached (STEP_32 — stale-keep)

    func testApplyCachedRendersContentWithoutRecordingSuccess() {
        let vm = AppViewModel()
        vm.applyCached(tool: .claude, state: .idleFallback,
                       snapshot: snapshot(tool: .claude, used: 43),
                       asOf: now.addingTimeInterval(-20 * 60), now: now)
        XCTAssertEqual(vm.claudeState.phase, .content,
                       "cached data renders content, never the idle card")
        XCTAssertEqual(vm.claudeState.dot, .grey)
        XCTAssertEqual(vm.claudeState.header?.heroText, "57%")
        XCTAssertTrue(vm.claudeState.header?.sourceTag?.base.contains("as of") == true)
        XCTAssertFalse(vm.hasSucceeded(.claude),
                       "a cached render must never count as a successful poll")
        // Menu bar: last-known percent, grey dot, no time slot.
        XCTAssertEqual(vm.menuBarRender.lines.first?.text, "CL 57%")
        XCTAssertEqual(vm.menuBarRender.lines.first?.dot, .grey)
    }

    /// REV-33 (STEP_39): `applyCached` applies the engine's classification instead of hardcoding
    /// `.idleFallback` — a restored hard block renders red with its verdict and banner, while
    /// still never counting as a successful poll.
    func testApplyCachedHardBlockRendersRedWithoutRecordingSuccess() {
        let vm = AppViewModel()
        let blocked = QuotaSnapshot(
            tool: .claude, primaryUsedPct: 100,
            primaryResetsAt: now.addingTimeInterval(26 * 60),
            secondaryUsedPct: 18, secondaryResetsAt: nil,
            rateLimitReached: true, extraUsage: .disabled, planType: "max")
        vm.applyCached(tool: .claude, state: .overQuota, snapshot: blocked,
                       asOf: now.addingTimeInterval(-66), now: now)
        XCTAssertEqual(vm.claudeState.dot, .red, "a restored hard block is critical, not calm")
        XCTAssertTrue(vm.claudeState.header?.verdict?.line1.hasPrefix("Stopped — quota returns") == true)
        XCTAssertNotNil(vm.claudeState.recommendation, "block banner survives the restore")
        XCTAssertTrue(vm.claudeState.header?.sourceTag?.base.contains("as of") == true)
        XCTAssertFalse(vm.hasSucceeded(.claude),
                       "a restored render must never count as a successful poll")
        // Menu bar (§1.2): a restored hard block keeps its red dot — not the grey a calm stale
        // render gets — and reads `CL 0%` (REV-77 / D-97).
        XCTAssertEqual(vm.menuBarRender.lines.first?.text, "CL 0%")
        XCTAssertEqual(vm.menuBarRender.lines.first?.dot, .red)
    }

    /// Freeze-reason plumbing (REV-37 — STEP_41): the `.rateLimited` health passed to `applyCached`
    /// must survive `applyCached → LastRender.cached → renderDisplay → DisplayFormatter` and fork the
    /// null verdict to "Reconnecting…". Today the value dead-ends in the engine; this asserts it
    /// reaches the formatter boundary. Both tabs.
    func testApplyCachedThreadsRateLimitedFreezeReasonToVerdict() {
        let vm = AppViewModel()
        let asOf = now.addingTimeInterval(-15 * 60)
        vm.applyCached(tool: .claude, state: .nullWindow,
                       snapshot: snapshot(tool: .claude, used: nil), asOf: asOf,
                       freezeReason: .rateLimited(retryAfter: 600), now: now)
        XCTAssertEqual(vm.claudeState.header?.verdict?.line1, "Reconnecting…")
        XCTAssertEqual(vm.claudeState.dot, .grey)

        vm.applyCached(tool: .codex, state: .nullWindow,
                       snapshot: snapshot(tool: .codex, used: nil), asOf: asOf,
                       freezeReason: .rateLimited(retryAfter: 600), now: now)
        XCTAssertEqual(vm.codexState.header?.verdict?.line1, "Reconnecting…")
    }

    /// Absent a freeze reason (the launch-restore / default path) the absent-object null verdict
    /// keeps "No active session" — the plumbing defaults cleanly and changes nothing.
    func testApplyCachedWithoutFreezeReasonKeepsNoActiveSession() {
        let vm = AppViewModel()
        vm.applyCached(tool: .claude, state: .nullWindow,
                       snapshot: snapshot(tool: .claude, used: nil),
                       asOf: now.addingTimeInterval(-15 * 60), now: now)
        XCTAssertEqual(vm.claudeState.header?.verdict?.line1, "No active session")
    }

    /// The REV-80 / D-101 not-started shape (0%, no reset, 18 000 s): 0%, no reset, width known.
    private func notStarted(_ tool: Tool) -> QuotaSnapshot {
        QuotaSnapshot(tool: tool, primaryUsedPct: 0, primaryResetsAt: nil,
                      primaryWindowSeconds: 18_000,
                      secondaryUsedPct: 14, secondaryResetsAt: nil,
                      rateLimitReached: false, extraUsage: tool == .claude ? .disabled : nil,
                      planType: "Pro")
    }

    private func attribution(lastActivity: Date) -> LocalAttribution {
        LocalAttribution(project: "/p", model: nil, surfaceBucket: nil, subagentCount: 0,
                         cacheHitRatio: 0.5,
                         estValue: EstimatedValueEngine.WindowValue(weekly: 2, thirtyDay: 3),
                         surfaceShares: [], tokensPerMinute: nil, lastActivityAt: lastActivity,
                         sessionCount: 1, windowValue: 1)
    }

    /// A restored not-started snapshot reads `5-hour · not started` on launch — the STEP_102
    /// ruling, both tools since REV-80 / D-101 — and the two tabs and menu slots agree.
    func testApplyCachedNotStartedRendersAsCodexDoes() {
        let vm = AppViewModel()
        let asOf = now.addingTimeInterval(-15 * 60)
        vm.applyCached(tool: .claude, state: .idleFallback, snapshot: notStarted(.claude),
                       asOf: asOf, now: now)
        vm.applyCached(tool: .codex, state: .idleFallback, snapshot: notStarted(.codex),
                       asOf: asOf, now: now)
        XCTAssertEqual(vm.claudeState.header?.heroText, "100%")
        XCTAssertEqual(vm.claudeState.header?.heroText, vm.codexState.header?.heroText)
        XCTAssertEqual(vm.claudeState.header?.heroDetails.map(\.text), ["not started"])
        XCTAssertEqual(vm.claudeState.header?.heroDetails.map(\.text),
                       vm.codexState.header?.heroDetails.map(\.text))
        XCTAssertEqual(vm.menuBarRender.lines.map(\.text), ["CL 100%", "CX 100%"])
        XCTAssertEqual(vm.menuBarRender.lines.map(\.dot), [.grey, .grey])
    }

    /// D-26 on both surfaces (REV-80 §3.2): local activity postdating a cached not-started
    /// snapshot withdraws the claim on the card **and** the bar — `——` on both, never `100%`.
    func testObsoleteNotStartedWithdrawsOnBothSurfaces() {
        let vm = AppViewModel()
        let asOf = now.addingTimeInterval(-15 * 60)
        vm.applyCached(tool: .claude, state: .idleFallback, snapshot: notStarted(.claude),
                       asOf: asOf, localAttribution: attribution(lastActivity: now.addingTimeInterval(-60)),
                       now: now)
        XCTAssertEqual(vm.claudeState.header?.heroText, "——")
        XCTAssertEqual(vm.claudeState.header?.verdict?.line1, "—")
        XCTAssertEqual(vm.menuBarRender.lines.first?.text, "CL —— est")
    }

    /// D-33 re-keyed: a rate-limited freeze over a cached not-started window reads
    /// "Reconnecting…" on the card and the non-asserting `——` on the bar (Baseline §19).
    func testApplyCachedNotStartedUnderRateLimitFreezeReconnects() {
        let vm = AppViewModel()
        vm.applyCached(tool: .claude, state: .idleFallback, snapshot: notStarted(.claude),
                       asOf: now.addingTimeInterval(-15 * 60),
                       freezeReason: .rateLimited(retryAfter: 600), now: now)
        XCTAssertEqual(vm.claudeState.header?.verdict?.line1, "Reconnecting…")
        XCTAssertEqual(vm.claudeState.header?.heroText, "——")
        XCTAssertEqual(vm.menuBarRender.lines.first?.text, "CL —— est")
    }

    func testDefaultTabOpensMoreUrgentTool() {
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: snapshot(tool: .claude, used: 38),
                 forecast: forecast(.claude), state: .healthy, now: now)         // rank 9
        vm.apply(tool: .codex, snapshot: snapshot(tool: .codex, used: 88),
                 forecast: forecast(.codex), state: .atRisk, now: now)           // rank 3
        vm.selectDefaultTab(now: now)
        XCTAssertEqual(vm.activeTab, .codex)
    }

    func testDefaultTabDefaultsToClaudeOnTie() {
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: snapshot(tool: .claude, used: 38),
                 forecast: forecast(.claude), state: .healthy, now: now)
        vm.apply(tool: .codex, snapshot: snapshot(tool: .codex, used: 42),
                 forecast: forecast(.codex), state: .healthy, now: now)
        vm.selectDefaultTab(now: now)
        XCTAssertEqual(vm.activeTab, .claude)
    }

    func testDefaultTabBothLoadingDefaultsToClaude() {
        let vm = AppViewModel()
        vm.activeTab = .codex
        vm.selectDefaultTab(now: now)
        XCTAssertEqual(vm.activeTab, .claude)
    }

    // §15.1 middle rule (STEP_26): on a rank tie, the tool with the most recent local JSONL
    // activity wins; rule 3 (Claude) only applies when neither has observed activity.

    private func attribution(lastActivity: Date?) -> LocalAttribution {
        LocalAttribution(project: "/p", model: nil, surfaceBucket: nil, subagentCount: 0,
                         cacheHitRatio: nil,
                         estValue: EstimatedValueEngine.WindowValue(weekly: 0, thirtyDay: 0),
                         surfaceShares: [], tokensPerMinute: nil, lastActivityAt: lastActivity)
    }

    func testDefaultTabTieBrokenByRecentActivity() {
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: snapshot(tool: .claude, used: 38),
                 forecast: forecast(.claude), state: .healthy,
                 localAttribution: attribution(lastActivity: now.addingTimeInterval(-600)), now: now)
        vm.apply(tool: .codex, snapshot: snapshot(tool: .codex, used: 42),
                 forecast: forecast(.codex), state: .healthy,
                 localAttribution: attribution(lastActivity: now.addingTimeInterval(-30)), now: now)
        vm.selectDefaultTab(now: now)
        XCTAssertEqual(vm.activeTab, .codex, "same rank → most recent JSONL activity wins")
    }

    func testDefaultTabTieOneSidedActivityWins() {
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: snapshot(tool: .claude, used: 38),
                 forecast: forecast(.claude), state: .healthy, now: now)     // no local activity
        vm.apply(tool: .codex, snapshot: snapshot(tool: .codex, used: 42),
                 forecast: forecast(.codex), state: .healthy,
                 localAttribution: attribution(lastActivity: now.addingTimeInterval(-30)), now: now)
        vm.selectDefaultTab(now: now)
        XCTAssertEqual(vm.activeTab, .codex, "only Codex has observed activity")
    }

    func testDefaultTabUrgencyStillBeatsActivity() {
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: snapshot(tool: .claude, used: 88),
                 forecast: forecast(.claude), state: .atRisk, now: now)      // more urgent
        vm.apply(tool: .codex, snapshot: snapshot(tool: .codex, used: 42),
                 forecast: forecast(.codex), state: .healthy,
                 localAttribution: attribution(lastActivity: now), now: now) // more recent
        vm.selectDefaultTab(now: now)
        XCTAssertEqual(vm.activeTab, .claude, "recency is a tie-break only, never beats urgency")
    }

    // A1 (remembered manual pick) + B1 (single-tool display-mode override).

    func testRememberedPickWinsOverUrgencyButNotDefaultMarker() {
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: snapshot(tool: .claude, used: 38),
                 forecast: forecast(.claude), state: .healthy, now: now)         // rank 10
        vm.apply(tool: .codex, snapshot: snapshot(tool: .codex, used: 88),
                 forecast: forecast(.codex), state: .atRisk, now: now)           // rank 3 — urgency winner
        vm.selectTab(.claude)                                                    // user overrides
        vm.selectDefaultTab(now: now)
        XCTAssertEqual(vm.activeTab, .claude, "remembered manual pick wins for the shown tab")
        XCTAssertEqual(vm.defaultTab, .codex, "the urgency winner is still computed (never labeled — D-49)")
    }

    func testDisplayModeOverridesRememberedPickAndUrgency() {
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: snapshot(tool: .claude, used: 38),
                 forecast: forecast(.claude), state: .healthy, now: now)
        vm.apply(tool: .codex, snapshot: snapshot(tool: .codex, used: 88),
                 forecast: forecast(.codex), state: .atRisk, now: now)           // Codex more urgent
        vm.selectTab(.codex)                                                     // and a Codex pick
        vm.setMenuBarDisplayMode(.claudeOnly)
        vm.selectDefaultTab(now: now)
        XCTAssertEqual(vm.activeTab, .claude, "Claude-only pins the Claude tab over pick + urgency")
        XCTAssertEqual(vm.defaultTab, .claude)

        vm.setMenuBarDisplayMode(.codexOnly)
        vm.selectDefaultTab(now: now)
        XCTAssertEqual(vm.activeTab, .codex, "Codex-only pins the Codex tab")
        XCTAssertEqual(vm.defaultTab, .codex)
    }

    func testDisplayModeChangeClearsRememberedPick() {
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: snapshot(tool: .claude, used: 38),
                 forecast: forecast(.claude), state: .healthy, now: now)         // urgency default
        vm.apply(tool: .codex, snapshot: snapshot(tool: .codex, used: 42),
                 forecast: forecast(.codex), state: .healthy, now: now)
        vm.selectTab(.codex)                                                     // remembered pick
        vm.setMenuBarDisplayMode(.bothStacked)                                   // clears the pick
        vm.selectDefaultTab(now: now)
        XCTAssertEqual(vm.activeTab, .claude, "cleared pick falls back to the urgency default")
    }

    // `testMenuBarShowsDominantEscalatedString` lived here until D-98 (REV-78): the single
    // dominant-agent text slot was Adaptive's alone, and both are gone.

    func testSetMenuBarDisplayModeRerenders() {
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: snapshot(tool: .claude, used: 38),
                 forecast: forecast(.claude), state: .healthy, now: now)
        vm.apply(tool: .codex, snapshot: snapshot(tool: .codex, used: 42),
                 forecast: forecast(.codex), state: .healthy, now: now)
        XCTAssertEqual(vm.menuBarRender.lines.count, 2, "stacked renders one row per tool")
        vm.setMenuBarDisplayMode(.claudeOnly)
        XCTAssertEqual(vm.menuBarRender.lines.count, 1, "a single-tool mode drops the other row")
        XCTAssertEqual(vm.menuBarRender.lines.first?.text.hasPrefix("CL "), true)
        vm.setMenuBarDisplayMode(.bothStacked)
        XCTAssertEqual(vm.menuBarRender.lines.count, 2)
    }

    func testApplyUndetectedRemovesToolFromMenuBar() {
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: snapshot(tool: .claude, used: 38),
                 forecast: forecast(.claude), state: .healthy, now: now)
        vm.applyUndetected(tool: .codex, now: now)
        // Undetected tool renders nothing — stacked collapses to Claude's row alone (D-32).
        XCTAssertEqual(vm.menuBarRender.lines.count, 1)
        XCTAssertEqual(vm.menuBarRender.lines.first?.text.hasPrefix("CL 62%"), true)
        // A later successful poll re-detects it.
        vm.apply(tool: .codex, snapshot: snapshot(tool: .codex, used: 42),
                 forecast: forecast(.codex), state: .healthy, now: now)
        XCTAssertEqual(vm.menuBarRender.lines.count, 2)
    }

    func testFreshnessStampAgesAndTurnsAmber() {
        // §2.2a: the account source stamp ticks with `refreshFreshness`, muted under two base
        // ticks (4 min at the 120 s base — D-112, STEP_169) and amber past it — the quota `asOf`
        // is the last successful poll time.
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: snapshot(tool: .claude, used: 38),
                 forecast: forecast(.claude), state: .healthy, now: now)
        vm.refreshFreshness(now: now.addingTimeInterval(90))
        XCTAssertEqual(vm.claudeState.header?.sourceTag?.age, "1m ago")
        XCTAssertEqual(vm.claudeState.header?.sourceTag?.ageIsAmber, false)
        vm.refreshFreshness(now: now.addingTimeInterval(3 * 60))
        XCTAssertEqual(vm.claudeState.header?.sourceTag?.age, "3m ago")
        XCTAssertEqual(vm.claudeState.header?.sourceTag?.ageIsAmber, false,
                       "one scheduled poll plus jitter is not a missed poll")
        vm.refreshFreshness(now: now.addingTimeInterval(PollBackoffPolicy.freshnessAmberAge))
        XCTAssertEqual(vm.claudeState.header?.sourceTag?.age, "4m ago")
        XCTAssertEqual(vm.claudeState.header?.sourceTag?.ageIsAmber, true)
    }

    func testApplyUnavailableDoesNotRecordSuccess() {
        let vm = AppViewModel()
        vm.applyUnavailable(tool: .claude, now: now)
        XCTAssertEqual(vm.claudeState.phase, .idle)
        XCTAssertFalse(vm.hasSucceeded(.claude))
        // No retained render → refreshFreshness is a no-op (still idle).
        vm.refreshFreshness(now: now.addingTimeInterval(10 * 60))
        XCTAssertEqual(vm.claudeState.phase, .idle)
    }

    // MARK: First-run / undetected (STEP_30)

    func testApplyUndetectedRendersFirstRunPerTool() {
        let vm = AppViewModel()
        vm.applyUndetected(tool: .claude)
        XCTAssertEqual(vm.claudeState.phase, .firstRun,
                       "an undetected tool shows the first-run card, not the idle card")
        XCTAssertFalse(vm.bothUndetected, "codex is still loading — not both undetected")
        XCTAssertEqual(vm.codexState.phase, .loading, "codex untouched")

        vm.applyUndetected(tool: .codex)
        XCTAssertEqual(vm.codexState.phase, .firstRun)
        XCTAssertTrue(vm.bothUndetected, "neither tool detected → combined welcome")
    }

    func testDetectionRevertsBothUndetected() {
        let vm = AppViewModel()
        vm.applyUndetected(tool: .claude)
        vm.applyUndetected(tool: .codex)
        XCTAssertTrue(vm.bothUndetected)
        // A successful poll on either tool reverts to the tabbed layout without a restart.
        vm.apply(tool: .claude, snapshot: snapshot(tool: .claude, used: 38),
                 forecast: forecast(.claude), state: .healthy, now: now)
        XCTAssertEqual(vm.claudeState.phase, .content)
        XCTAssertFalse(vm.bothUndetected)
    }

    func testApplyUnavailableIsIdleNotFirstRun() {
        let vm = AppViewModel()
        vm.applyUndetected(tool: .codex)
        vm.applyUnavailable(tool: .codex)
        XCTAssertEqual(vm.codexState.phase, .idle,
                       "detected-but-idle shows the idle card, never first-run")
        XCTAssertFalse(vm.bothUndetected)
    }

    func testRecheckInvokesInjectedSeam() {
        let vm = AppViewModel()
        var rechecked: [Tool] = []
        vm.onRecheck = { rechecked.append($0) }
        vm.recheck(.claude)
        XCTAssertEqual(rechecked, [.claude])
    }

    // MARK: Detected-tools tab bar (D-68 — STEP_105)

    func testDetectedToolsDefaultsToBothWhileUnclassified() {
        // Startup: neither tool classified yet → both count as detected, so a two-tool machine
        // keeps its two "Connecting…" tabs during the first poll.
        let vm = AppViewModel()
        XCTAssertEqual(vm.detectedTools, [.claude, .codex])
    }

    func testDetectedToolsPinsTodaysTwoTabShape() {
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: snapshot(tool: .claude, used: 38),
                 forecast: forecast(.claude), state: .healthy, now: now)
        vm.apply(tool: .codex, snapshot: snapshot(tool: .codex, used: 42),
                 forecast: forecast(.codex), state: .healthy, now: now)
        XCTAssertEqual(vm.detectedTools, [.claude, .codex], "both detected → two tabs, as today")
    }

    func testSingleToolMachineHasSingleDetectedTool() {
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: snapshot(tool: .claude, used: 38),
                 forecast: forecast(.claude), state: .healthy, now: now)
        vm.applyUndetected(tool: .codex, now: now)
        XCTAssertEqual(vm.detectedTools, [.claude], "Codex undetected → no Codex tab anywhere")

        let mirror = AppViewModel()
        mirror.apply(tool: .codex, snapshot: snapshot(tool: .codex, used: 42),
                     forecast: forecast(.codex), state: .healthy, now: now)
        mirror.applyUndetected(tool: .claude, now: now)
        XCTAssertEqual(mirror.detectedTools, [.codex])
    }

    func testDetectionAppearingRestoresTabWithoutRestart() {
        // D-68 return path: the tab reappears on the first poll after the second tool's
        // credentials/JSONL show up — nothing persisted, no restart.
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: snapshot(tool: .claude, used: 38),
                 forecast: forecast(.claude), state: .healthy, now: now)
        vm.applyUndetected(tool: .codex, now: now)
        XCTAssertEqual(vm.detectedTools, [.claude])
        vm.apply(tool: .codex, snapshot: snapshot(tool: .codex, used: 42),
                 forecast: forecast(.codex), state: .healthy, now: now)
        XCTAssertEqual(vm.detectedTools, [.claude, .codex])
    }

    func testActiveTabMovesWhenItsToolBecomesUndetected() {
        // The active tab must always be a rendered tab: when the detected set shrinks away
        // from under it, it moves to the surviving tool and the manual pick is dropped.
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: snapshot(tool: .claude, used: 38),
                 forecast: forecast(.claude), state: .healthy, now: now)
        vm.apply(tool: .codex, snapshot: snapshot(tool: .codex, used: 42),
                 forecast: forecast(.codex), state: .healthy, now: now)
        vm.selectTab(.codex)                       // manual pick on the tab about to vanish
        vm.applyUndetected(tool: .codex, now: now)
        XCTAssertEqual(vm.activeTab, .claude, "active tab never points at a ghost tab")
        vm.selectDefaultTab(now: now)
        XCTAssertEqual(vm.activeTab, .claude, "the dropped pick cannot resurrect the ghost")
    }

    func testSelectDefaultTabSingleCandidateWinsImmediately() {
        // Baseline §15.1: an undetected tool is never a candidate; with one candidate it wins
        // immediately — even over a single-tool display mode pinned to the missing tool.
        let vm = AppViewModel()
        vm.apply(tool: .codex, snapshot: snapshot(tool: .codex, used: 42),
                 forecast: forecast(.codex), state: .healthy, now: now)
        vm.applyUndetected(tool: .claude, now: now)
        vm.setMenuBarDisplayMode(.claudeOnly)
        vm.selectDefaultTab(now: now)
        XCTAssertEqual(vm.activeTab, .codex, "a pinned mode cannot select a tab that does not exist")
        XCTAssertEqual(vm.defaultTab, .codex)
    }

    func testTransientSetupToolClearedByOrdinaryOpen() {
        // The `Set up <tool>…` view is transient (D-68): the next ordinary open — which runs
        // `selectDefaultTab` — returns to the detected tool's view.
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: snapshot(tool: .claude, used: 38),
                 forecast: forecast(.claude), state: .healthy, now: now)
        vm.applyUndetected(tool: .codex, now: now)
        vm.openSetup(.codex)
        XCTAssertEqual(vm.transientSetupTool, .codex)
        vm.selectDefaultTab(now: now)
        XCTAssertNil(vm.transientSetupTool, "an ordinary open leaves the setup view")
        XCTAssertEqual(vm.activeTab, .claude)
    }

    func testBothUndetectedStillReportsWelcome() {
        // Neither detected → the combined welcome branch is untouched by D-68.
        let vm = AppViewModel()
        vm.applyUndetected(tool: .claude, now: now)
        vm.applyUndetected(tool: .codex, now: now)
        XCTAssertTrue(vm.bothUndetected)
        XCTAssertEqual(vm.detectedTools, [])
    }

    // MARK: Verdict anatomy expansion (STEP_110 — UI Spec Part 3 §5.3 lifecycle)

    /// 87% used, 100 min to reset, burn 0.32 → "Won't make it" (exhaustion family, anatomy present).
    private func exhaustionSnapshot() -> QuotaSnapshot {
        QuotaSnapshot(tool: .claude, primaryUsedPct: 87,
                      primaryResetsAt: now.addingTimeInterval(100 * 60),
                      secondaryUsedPct: 14, secondaryResetsAt: nil,
                      rateLimitReached: false, extraUsage: .disabled, planType: "Pro")
    }
    private func exhaustionForecast() -> Forecast {
        Forecast(tool: .claude, tier: .fullRunway, runwayMinutes: 13 / 0.32,
                 burnRatePerMin: 0.32, isEstimate: false, pollCount: 10, burnSpanMinutes: 9)
    }

    func testTogglePinsAndSecondClickReleases() {
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: exhaustionSnapshot(), forecast: exhaustionForecast(),
                 state: .elevated, now: now)
        XCTAssertNotNil(vm.claudeState.header?.verdict?.anatomy)
        XCTAssertNil(vm.pinnedAnatomy)
        vm.togglePinnedAnatomy(.claude)
        XCTAssertEqual(vm.pinnedAnatomy, .claude)
        vm.togglePinnedAnatomy(.claude)
        XCTAssertNil(vm.pinnedAnatomy)
    }

    func testToggleIsInertWithoutAnAnatomy() {
        let vm = AppViewModel()
        // Measuring… — a condition verdict; nothing to show.
        vm.apply(tool: .claude, snapshot: snapshot(tool: .claude, used: 38),
                 forecast: forecast(.claude, burn: nil), state: .healthy, now: now)
        XCTAssertNil(vm.claudeState.header?.verdict?.anatomy)
        vm.togglePinnedAnatomy(.claude)
        XCTAssertNil(vm.pinnedAnatomy)
    }

    func testEscapeConsumesOnlyWhenPinned() {
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: exhaustionSnapshot(), forecast: exhaustionForecast(),
                 state: .elevated, now: now)
        XCTAssertFalse(vm.handleEscape(), "nothing open — the popover keeps its own Esc")
        vm.togglePinnedAnatomy(.claude)
        XCTAssertTrue(vm.handleEscape())
        XCTAssertNil(vm.pinnedAnatomy)
        XCTAssertFalse(vm.handleEscape())
    }

    func testPinSurvivesPollsAndReleasesOnFamilyChange() {
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: exhaustionSnapshot(), forecast: exhaustionForecast(),
                 state: .elevated, now: now)
        vm.togglePinnedAnatomy(.claude)
        // Same family, new numbers (a later poll): values live-update, block stays open.
        let later = now.addingTimeInterval(60)
        vm.apply(tool: .claude, snapshot: exhaustionSnapshot(), forecast: exhaustionForecast(),
                 state: .elevated, now: later)
        XCTAssertEqual(vm.pinnedAnatomy, .claude)
        // The freshness tick re-renders without a poll — also not a family change.
        vm.refreshFreshness(now: later.addingTimeInterval(30))
        XCTAssertEqual(vm.pinnedAnatomy, .claude)
        // Danger passes → the held row (a different family) → the block collapses.
        let calm = Forecast(tool: .claude, tier: .fullRunway, runwayMinutes: 200,
                            burnRatePerMin: 0.06, isEstimate: false, pollCount: 10)
        vm.apply(tool: .claude, snapshot: exhaustionSnapshot(), forecast: calm,
                 state: .elevated, now: later)
        XCTAssertEqual(vm.claudeState.header?.verdict?.family, .held)
        XCTAssertNil(vm.pinnedAnatomy)
    }

    func testPinReleasesWhenTheToolGoesUnavailable() {
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: exhaustionSnapshot(), forecast: exhaustionForecast(),
                 state: .elevated, now: now)
        vm.togglePinnedAnatomy(.claude)
        vm.applyUnavailable(tool: .claude, now: now)
        XCTAssertNil(vm.pinnedAnatomy)
    }

    func testReleaseIsTheCloseHookAndTabSwitchReleases() {
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: exhaustionSnapshot(), forecast: exhaustionForecast(),
                 state: .elevated, now: now)
        vm.togglePinnedAnatomy(.claude)
        vm.releasePinnedAnatomy()
        XCTAssertNil(vm.pinnedAnatomy)
        // Only Claude's family changing releases Claude's pin — Codex renders don't touch it.
        vm.togglePinnedAnatomy(.claude)
        vm.applyUnavailable(tool: .codex, now: now)
        XCTAssertEqual(vm.pinnedAnatomy, .claude)
        // A tab switch is a new look: it releases the pin.
        vm.selectTab(.codex)
        XCTAssertNil(vm.pinnedAnatomy)
    }
}

// MARK: - Explanation layer — hover cards (STEP_111 — UI Spec Part 3 §5.1/§5.2 lifecycle)

@MainActor
final class AppViewModelHoverCardTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let quotaRow = ExplanationTarget(.primaryWindow, site: "5-hour left")
    private let burnRow = ExplanationTarget(.localSource, site: "Local source")

    /// A model with a Claude anatomy available and the settle guard already elapsed, timings
    /// shrunk so a test takes milliseconds.
    private let clock = ManualClock()

    private func makeVM() -> AppViewModel {
        let vm = AppViewModel()
        vm.hoverPeekDelay = .milliseconds(20)
        vm.hoverGraceLeave = .milliseconds(20)
        vm.hoverClock = clock
        vm.hoverSettle = 0
        vm.apply(tool: .claude,
                 snapshot: QuotaSnapshot(tool: .claude, primaryUsedPct: 87,
                                         primaryResetsAt: now.addingTimeInterval(100 * 60),
                                         secondaryUsedPct: 14, secondaryResetsAt: nil,
                                         rateLimitReached: false, extraUsage: .disabled, planType: "Pro"),
                 forecast: Forecast(tool: .claude, tier: .fullRunway, runwayMinutes: 13 / 0.32,
                                    burnRatePerMin: 0.32, isEstimate: false, pollCount: 10,
                                    burnSpanMinutes: 9),
                 state: .elevated, now: now)
        return vm
    }

    /// Moves the injected clock; nothing here sleeps on the wall clock (STEP_277).
    private func settle(_ ms: Int) async {
        await clock.advance(ms)
    }

    func testHoverPeeksAfterTheDelayNotBefore() async {
        let vm = makeVM()
        vm.explanationHover(quotaRow, hovering: true)
        XCTAssertEqual(vm.hoveredExplanation, quotaRow, "the tell is immediate")
        XCTAssertNil(vm.peekedCard, "the card waits for the delay")
        await settle(60)
        XCTAssertEqual(vm.peekedCard, quotaRow)
        XCTAssertEqual(vm.activeCard, quotaRow)
    }

    func testLeavingBeforeTheDelayNeverPeeks() async {
        let vm = makeVM()
        vm.explanationHover(quotaRow, hovering: true)
        vm.explanationHover(quotaRow, hovering: false)
        await settle(60)
        XCTAssertNil(vm.peekedCard)
        XCTAssertNil(vm.hoveredExplanation)
    }

    func testPeekEndsAfterGraceUnlessThePointerIsOnTheCard() async {
        let vm = makeVM()
        vm.explanationHover(quotaRow, hovering: true)
        await settle(60)
        XCTAssertEqual(vm.peekedCard, quotaRow)
        // Pointer crosses the gap into the card: the peek survives.
        vm.explanationHover(quotaRow, hovering: false)
        vm.explanationCardHover(true)
        await settle(60)
        XCTAssertEqual(vm.peekedCard, quotaRow)
        // Pointer leaves the card: the peek ends after the grace.
        vm.explanationCardHover(false)
        await settle(60)
        XCTAssertNil(vm.peekedCard)
    }

    /// STEP_132 (REV-75/D-91) — this used to assert the opposite. The instant swap is what made a
    /// pointer sweep down the popover deal out one card per row, so every element now re-arms the
    /// full delay and the card already showing ends on its own grace. The two are independent: a
    /// grace shorter than the delay is the whole point, and a single shared timer could not run
    /// both.
    func testSlidingOntoAnotherElementReArmsTheDelay() async {
        let vm = makeVM()
        vm.hoverGraceLeave = .milliseconds(20)
        vm.hoverPeekDelay = .milliseconds(120)
        vm.explanationHover(quotaRow, hovering: true)
        await settle(160)
        XCTAssertEqual(vm.peekedCard, quotaRow)

        vm.explanationHover(quotaRow, hovering: false)
        vm.explanationHover(burnRow, hovering: true)
        XCTAssertEqual(vm.peekedCard, quotaRow, "the new element does not swap in at once")

        await settle(60)
        XCTAssertNil(vm.peekedCard, "the first card ended on its own grace")

        await settle(120)
        XCTAssertEqual(vm.peekedCard, burnRow, "the second opened only after the full delay")
    }

    /// The sweep, as the dogfood complaint described it: the pointer crosses three rows without
    /// resting on any of them, and nothing opens.
    func testSweepingPastElementsOpensNothing() async {
        let vm = makeVM()
        vm.hoverPeekDelay = .milliseconds(120)
        for row in [quotaRow, burnRow, quotaRow] {
            vm.explanationHover(row, hovering: true)
            await settle(20)
            vm.explanationHover(row, hovering: false)
        }
        await settle(160)
        XCTAssertNil(vm.peekedCard, "no row was rested on long enough to earn a card")
    }

    func testPinReleasesAnatomyAndAnatomyReleasesPin() {
        let vm = makeVM()
        vm.togglePinnedAnatomy(.claude)
        XCTAssertEqual(vm.pinnedAnatomy, .claude)
        vm.togglePinnedCard(quotaRow)
        XCTAssertEqual(vm.pinnedCard, quotaRow)
        XCTAssertNil(vm.pinnedAnatomy, "one pinned thing at a time")
        vm.togglePinnedAnatomy(.claude)
        XCTAssertEqual(vm.pinnedAnatomy, .claude)
        XCTAssertNil(vm.pinnedCard)
    }

    func testSecondClickReleasesAndAnotherElementReplaces() {
        let vm = makeVM()
        vm.togglePinnedCard(quotaRow)
        vm.togglePinnedCard(quotaRow)
        XCTAssertNil(vm.pinnedCard)
        vm.togglePinnedCard(quotaRow)
        vm.togglePinnedCard(burnRow)
        XCTAssertEqual(vm.pinnedCard, burnRow)
    }

    func testNoPeekOpensUnderAPin() async {
        let vm = makeVM()
        vm.togglePinnedCard(quotaRow)
        vm.explanationHover(burnRow, hovering: true)
        await settle(60)
        XCTAssertEqual(vm.hoveredExplanation, burnRow, "the tell still shows")
        XCTAssertNil(vm.peekedCard)
        XCTAssertEqual(vm.activeCard, quotaRow, "the pin owns the overlay")
    }

    func testEscapeReleasesTheCardFirstThenTheAnatomy() {
        let vm = makeVM()
        XCTAssertFalse(vm.handleEscape())
        vm.togglePinnedAnatomy(.claude)
        vm.togglePinnedCard(quotaRow)   // releases the anatomy; re-pin it is impossible with a card up
        XCTAssertTrue(vm.handleEscape())
        XCTAssertNil(vm.pinnedCard)
        XCTAssertFalse(vm.handleEscape(), "nothing else was pinned")
        vm.togglePinnedAnatomy(.claude)
        XCTAssertTrue(vm.handleEscape())
        XCTAssertNil(vm.pinnedAnatomy)
    }

    func testTabSwitchAndTheShowCloseHookReleaseEverything() async {
        let vm = makeVM()
        vm.togglePinnedCard(quotaRow)
        vm.selectTab(.codex)
        XCTAssertNil(vm.pinnedCard)
        vm.selectTab(.claude)
        vm.hoverSettle = 0
        vm.togglePinnedCard(quotaRow)
        vm.togglePinnedAnatomy(.claude)
        vm.togglePinnedCard(burnRow)
        vm.releaseExplanationLayer()
        XCTAssertNil(vm.pinnedCard)
        XCTAssertNil(vm.pinnedAnatomy)
        XCTAssertNil(vm.peekedCard)
        XCTAssertNil(vm.hoveredExplanation)
    }

    func testSettleGuardSwallowsThePhantomEnter() async {
        let vm = makeVM()
        vm.hoverSettle = 0.5
        vm.releaseExplanationLayer()   // stamps the settle clock, as a popover open does
        vm.explanationHover(quotaRow, hovering: true)
        XCTAssertNil(vm.hoveredExplanation, "an enter inside the settle window is not a hover")
        await settle(60)
        XCTAssertNil(vm.peekedCard)
    }
}
