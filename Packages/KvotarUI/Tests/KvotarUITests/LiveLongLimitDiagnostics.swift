import XCTest
import KvotarCore
@testable import KvotarUI

/// The owner's own account, put through the shipped formatter (STEP_195). Amber and red cannot be
/// reached here — the weekly has never crossed the floor — so the **live** half of this step's
/// validation is the calm frame: the tier word, the day-of-week meta, no strip, and a menu string
/// identical to the one build 13 rendered. Env-gated like every other live diagnostic; the values
/// are pasted from `poll_snapshots`, never read from the database by a test.
final class LiveLongLimitDiagnostics: XCTestCase {

    func testLiveClaudeWeeklyRow() throws {
        guard ProcessInfo.processInfo.environment["KVOTAR_LIVE_DIAGNOSTICS"] != nil else {
            throw XCTSkip("set KVOTAR_LIVE_DIAGNOSTICS to print the live long-limit render")
        }
        // 2026-09-14 16:06:56 local, the poll behind the screenshot in the step log.
        let now = Date(timeIntervalSince1970: 1_789_394_816)
        let snapshot = QuotaSnapshot(
            tool: .claude, primaryUsedPct: 21,
            primaryResetsAt: Date(timeIntervalSince1970: 1_789_405_200),
            primaryWindowSeconds: 18_000, secondaryUsedPct: 48,
            secondaryResetsAt: Date(timeIntervalSince1970: 1_789_736_400),
            rateLimitReached: false, extraUsage: .disabled,
            source: .oauth, email: "owner@example.com", planType: "max")
        let forecast = Forecast(tool: .claude, tier: .fullRunway, runwayMinutes: 300,
                                burnRatePerMin: 0.26, isEstimate: false, pollCount: 10)
        let state = DisplayFormatter.claude(state: .healthy, snapshot: snapshot,
                                            forecast: forecast, pollAsOf: now, now: now)
        let bar = DisplayFormatter.toolMenuBar(tool: .claude, state: .healthy, snapshot: snapshot,
                                               forecast: forecast, now: now)
        print("[live] bar     : \(bar.fullString) dot=\(bar.dot)")
        print("[live] reminder: \(bar.reminders.isEmpty ? "(none)" : bar.reminders.joined(separator: " / "))")
        print("[live] hero    : \(state.header?.heroText ?? "-") \(state.header?.limitCaption ?? "-")")
        print("[live] strip   : \(state.header?.longLimitStrip?.text ?? "(none)")")
        for row in state.otherLimits?.rows ?? [] {
            print("[live] row     : \(row.label) | \(row.value) | \(row.reset ?? "-") "
                + "| hot=\(row.isHighlighted)")
            print("[live]   card  : \(row.explanationLive?.text ?? "-")")
        }
        XCTAssertNil(state.header?.longLimitStrip, "the owner's weekly is under the amber floor")
        XCTAssertNil(bar.timeSlot.flatMap { $0.hasPrefix("⚠") ? $0 : nil })
        // STEP_198: a calm account owes no reminder, so the bar is byte-identical to build 13's.
        XCTAssertTrue(bar.reminders.isEmpty, "a calm account should not cycle")
        XCTAssertEqual(bar.fullString, "CL 79% ↻2h53m")
    }

    /// **The first time the amber tier has ever been reachable on this account** (2026-09-14
    /// 17:46 local, `poll_snapshots`). STEP_195 recorded that it could not be exercised here —
    /// the weekly had never crossed the floor — and eleven fixture frames were the only way to
    /// look at it. That is no longer true: the weekly is at 50 % used with about 42 % of its week
    /// gone, which is rank 10, and `state_transitions` records the crossing.
    ///
    /// What this pins is the claim STEP_198 rests on: **the steady string under a warning tier is
    /// the calm string**. The live menu bar read `CL 57% ↻1h13m` beside an amber dot, and the
    /// reminder carries the weekly and its own reset — which the STEP_195 slot had no room for.
    func testLiveClaudeWeeklyAheadOfPace() throws {
        guard ProcessInfo.processInfo.environment["KVOTAR_LIVE_DIAGNOSTICS"] != nil else {
            throw XCTSkip("set KVOTAR_LIVE_DIAGNOSTICS to print the live long-limit render")
        }
        let now = Date(timeIntervalSince1970: 1_789_400_764)
        let snapshot = QuotaSnapshot(
            tool: .claude, primaryUsedPct: 43,
            primaryResetsAt: Date(timeIntervalSince1970: 1_789_405_200),
            primaryWindowSeconds: 18_000, secondaryUsedPct: 50,
            secondaryResetsAt: Date(timeIntervalSince1970: 1_789_736_400),
            rateLimitReached: false, extraUsage: .disabled,
            source: .oauth, email: "owner@example.com", planType: "max")
        let forecast = Forecast(tool: .claude, tier: .fullRunway, runwayMinutes: 300,
                                burnRatePerMin: 0.19, isEstimate: false, pollCount: 10)
        let bar = DisplayFormatter.toolMenuBar(tool: .claude, state: .limitAheadOfPace,
                                               snapshot: snapshot, forecast: forecast, now: now)
        print("[live] steady  : \(bar.fullString) dot=\(bar.dot)")
        print("[live] reminder: \(bar.reminders.joined(separator: " / "))")

        XCTAssertEqual(bar.fullString, "CL 57% ↻1h13m", "the live menu bar, as screenshotted")
        XCTAssertEqual(bar.dot, .amber)
        XCTAssertEqual(bar.reminders, ["CL ⚠wk 50%"])
        // The steady phase is byte-identical to what the same reading renders when calm — the
        // whole point of §2.1, and the reason this step changes nothing a reader sees until the
        // clock arrives in STEP_199.
        XCTAssertEqual(bar.fullString,
                       DisplayFormatter.toolMenuBar(tool: .claude, state: .healthy,
                                                    snapshot: snapshot, forecast: forecast,
                                                    now: now).fullString)
    }
}
