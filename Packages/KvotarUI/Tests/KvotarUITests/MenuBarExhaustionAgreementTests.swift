import XCTest
import KvotarCore
@testable import KvotarUI

/// D-113 (STEP_172) — **the menu bar and the popover verdict make one exhaustion decision.**
///
/// The screenshot considered for the launch post on 2026-09-08 showed Claude at 5% left, the
/// popover reading `Won't make it — you'll be blocked in ~11m` with a reset about 64 minutes
/// away, and the menu bar reading `CL 5% ↻1h04m`. The bar carried a fourth condition the
/// verdict never had — recent local tokens (§1.3 condition 1, STEP_27) — and
/// `AppViewModel.apply` derived it from a two-minute token window, so zero or missing
/// attribution fell back to the reset countdown at the one minute the estimate mattered.
///
/// The fixtures below are the screenshot's *inputs*, not evidence about what the machine was
/// doing that afternoon: nothing here claims the account was idle, only that idleness must no
/// longer decide what the bar shows.
@MainActor
final class MenuBarExhaustionAgreementTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// The screenshot's numbers: 95% used of a 300-minute window whose reset is 64 minutes out
    /// (so 78.7% of the window has elapsed — the pace clock fires), and an 11-minute runway.
    private func screenshotSnapshot(_ tool: Tool) -> QuotaSnapshot {
        QuotaSnapshot(tool: tool,
                      primaryUsedPct: 95,
                      primaryResetsAt: now.addingTimeInterval(64 * 60),
                      primaryWindowSeconds: tool == .codex ? 18_000 : nil,
                      secondaryUsedPct: tool == .claude ? 40 : nil,
                      secondaryResetsAt: nil,
                      rateLimitReached: false,
                      extraUsage: tool == .claude ? .disabled : nil,
                      source: tool == .codex ? .appServerRPC : nil,
                      email: "user@example.com",
                      planType: tool == .claude ? "Max" : "Plus")
    }

    private func forecast(_ tool: Tool, runway: Double?) -> Forecast {
        Forecast(tool: tool, tier: .fullRunway, runwayMinutes: runway,
                 burnRatePerMin: 8, isEstimate: false, pollCount: 10)
    }

    /// Positive, zero and missing local token rates — the three shapes the retired condition
    /// forked on.
    private func attribution(tokensPerMinute: Double?) -> LocalAttribution {
        LocalAttribution(project: "/p", model: nil, surfaceBucket: nil, subagentCount: 0,
                         cacheHitRatio: nil,
                         estValue: EstimatedValueEngine.WindowValue(weekly: 0, thirtyDay: 0),
                         surfaceShares: [], tokensPerMinute: tokensPerMinute,
                         lastActivityAt: now.addingTimeInterval(-30 * 60),
                         sessionCount: 1, windowValue: 0)
    }

    // MARK: STEP_176 — the bar keeps the primary while the popover names another limit

    /// Documented divergence (Baseline §15.2 / STEP_176): the menu bar's percentage is the
    /// primary window's, unchanged; the popover's hero can be the weekly. Under the state-first
    /// rule a promotion happens only when the primary is calm, so the bar shows the reset slot
    /// — never a five-hour runway under a weekly hero — and the invariant below still holds.
    func testLongLimitRankLeavesTheBarOnThePrimaryPercentWithNoRunway() {
        let s = QuotaSnapshot(tool: .claude, primaryUsedPct: 0,
                              primaryResetsAt: now.addingTimeInterval(64 * 60),
                              primaryWindowSeconds: 18_000, secondaryUsedPct: 91,
                              secondaryResetsAt: now.addingTimeInterval(5 * 86_400),
                              rateLimitReached: false, extraUsage: .disabled,
                              email: "user@example.com", planType: "Max")
        let bar = DisplayFormatter.toolMenuBar(tool: .claude, state: .limitAheadOfPace, snapshot: s,
                                               forecast: forecast(.claude, runway: 11), glyph: .none,
                                               now: now)
        XCTAssertEqual(bar.percentText, "100%", "the bar's percent stays the primary's")
        // STEP_195: amber is a dot-only change, so the slot is the ordinary reset countdown —
        // the ⚠ slot belongs to the red tier and to nothing else (REV-96 §2.5).
        XCTAssertEqual(bar.timeSlot, "↻1h04m")
        XCTAssertEqual(bar.dot, .amber)
        // Since STEP_194 the popover keeps the five-hour hero and says the rest in the strip —
        // the bar was already doing that, and the two now agree by construction.
        let header = DisplayFormatter.header(tool: .claude, state: .limitAheadOfPace, snapshot: s,
                                             forecast: forecast(.claude, runway: 11), now: now)
        XCTAssertEqual(header.heroText, "100%")
        XCTAssertEqual(header.longLimitStrip?.limitID, .secondaryWindow)
        XCTAssertNil(DisplayFormatter.exhaustionRunwayMinutes(state: .limitAheadOfPace, snapshot: s,
                                                              forecast: forecast(.claude, runway: 11),
                                                              now: now))
    }

    // MARK: The screenshot case

    /// Both tools, both warning colours: the bar carries the popover's own estimate.
    func testScreenshotCaseShowsTheSameEstimateOnBothSurfaces() {
        for tool in [Tool.claude, .codex] {
            for state in [AppState.elevated, .atRisk, .badTiming] {
                let snapshot = screenshotSnapshot(tool)
                let f = forecast(tool, runway: 11)
                let bar = DisplayFormatter.toolMenuBar(tool: tool, state: state,
                                                       snapshot: snapshot, forecast: f, now: now)
                let verdict = DisplayFormatter.headerVerdict(tool: tool, state: state,
                                                             snapshot: snapshot, forecast: f,
                                                             now: now)
                XCTAssertEqual(bar.timeSlot, "◔~11m", "\(tool) / \(state)")
                XCTAssertEqual(verdict?.family, .exhaustion, "\(tool) / \(state)")
                XCTAssertTrue(verdict?.line1.contains("~11m") == true,
                              "the two surfaces quote one runway — \(tool) / \(state)")
            }
        }
    }

    /// Through the live path, with the three attribution shapes. The default argument matters
    /// as much as the explicit ones: `apply` is called without attribution on plenty of cycles,
    /// and that is exactly where the old fallback used to reappear.
    func testScreenshotCaseThroughTheViewModelIgnoresLocalTokenRate() {
        for tool in [Tool.claude, .codex] {
            let cases: [(String, LocalAttribution?)] = [
                ("tokens flowing", attribution(tokensPerMinute: 4_200)),
                ("rate zero", attribution(tokensPerMinute: 0)),
                ("rate unknown", attribution(tokensPerMinute: nil)),
                ("no attribution at all", nil)
            ]
            for (label, attribution) in cases {
                let vm = AppViewModel()
                vm.apply(tool: tool, snapshot: screenshotSnapshot(tool),
                         forecast: forecast(tool, runway: 11), state: .atRisk,
                         localAttribution: attribution, now: now)
                XCTAssertEqual(vm.toolMenuBar(tool)?.timeSlot, "◔~11m", "\(tool) — \(label)")
            }
        }
    }

    // MARK: Transitions

    /// Active → idle keeps the estimate while the same forecast holds; a forecast that no
    /// longer predicts exhaustion hands the slot back to the reset countdown. The estimate is
    /// withdrawn by the forecast, never by local silence (the accepted trade-off: it may stand
    /// through a pause, exactly as it does in the card).
    func testEstimateSurvivesGoingIdleAndIsWithdrawnByTheForecast() {
        let vm = AppViewModel()
        vm.apply(tool: .claude, snapshot: screenshotSnapshot(.claude),
                 forecast: forecast(.claude, runway: 11), state: .atRisk,
                 localAttribution: attribution(tokensPerMinute: 4_200), now: now)
        XCTAssertEqual(vm.toolMenuBar(.claude)?.timeSlot, "◔~11m")

        vm.apply(tool: .claude, snapshot: screenshotSnapshot(.claude),
                 forecast: forecast(.claude, runway: 11), state: .atRisk,
                 localAttribution: attribution(tokensPerMinute: 0), now: now)
        XCTAssertEqual(vm.toolMenuBar(.claude)?.timeSlot, "◔~11m",
                       "going quiet locally is not the forecast changing")

        vm.apply(tool: .claude, snapshot: screenshotSnapshot(.claude),
                 forecast: forecast(.claude, runway: 240), state: .healthy,
                 localAttribution: attribution(tokensPerMinute: 0), now: now)
        XCTAssertEqual(vm.toolMenuBar(.claude)?.timeSlot, "↻1h04m",
                       "no exhaustion forecast → the reset countdown returns")
    }

    // MARK: The invariant

    /// **The list of pre-empting states in `exhaustionRunwayMinutes` is a transcription of the
    /// ladder above the exhaustion arm in `headerVerdict`, and this is what keeps the two
    /// level.** Over every state, with inputs that would otherwise produce an urgent estimate:
    /// if the bar shows `◔`, the popover is showing the exhaustion row. A red dot on its own
    /// never implies a runway estimate.
    func testMenuBarRunwayImpliesExhaustionVerdict() {
        var slotsSeen = 0
        for tool in [Tool.claude, .codex] {
            for state in AppState.allCases {
                let snapshot = screenshotSnapshot(tool)
                let f = forecast(tool, runway: 11)
                let bar = DisplayFormatter.toolMenuBar(tool: tool, state: state,
                                                       snapshot: snapshot, forecast: f, now: now)
                guard bar.timeSlot?.hasPrefix("◔") == true else { continue }
                slotsSeen += 1
                let verdict = DisplayFormatter.headerVerdict(tool: tool, state: state,
                                                             snapshot: snapshot, forecast: f,
                                                             now: now)
                XCTAssertEqual(verdict?.family, .exhaustion,
                               "\(tool) / \(state): the bar claimed an urgent runway the "
                               + "popover does not")
            }
        }
        XCTAssertGreaterThan(slotsSeen, 0,
                             "the sweep must actually reach the ◔ branch, or it proves nothing")
    }

    /// The other direction of the same rule at the boundary the bar owns alone: a genuine
    /// exhaustion verdict with a runway of an hour or more is not urgent, so the bar keeps the
    /// reset countdown while the card keeps its warning. This is §1.3's own threshold, not a
    /// disagreement about what is happening.
    func testLongRunwayKeepsTheResetSlotUnderAnExhaustionVerdict() {
        let snapshot = screenshotSnapshot(.claude)
        let f = forecast(.claude, runway: 61)
        let bar = DisplayFormatter.toolMenuBar(tool: .claude, state: .elevated,
                                               snapshot: snapshot, forecast: f, now: now)
        let verdict = DisplayFormatter.headerVerdict(tool: .claude, state: .elevated,
                                                     snapshot: snapshot, forecast: f, now: now)
        XCTAssertEqual(verdict?.family, .exhaustion)
        XCTAssertEqual(bar.timeSlot, "↻1h04m")
    }
}
