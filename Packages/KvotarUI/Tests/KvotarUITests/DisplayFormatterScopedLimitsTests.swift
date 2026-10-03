import XCTest
import KvotarCore
@testable import KvotarUI

/// STEP_134 (UI Spec §2.3 / D-94) — **the model-scoped weekly limit gets a row of its own.**
///
/// The defect these pin: claude.ai's Usage page draws three bars — session, weekly all-models and
/// weekly Fable — and Kvotar drew the first two. On the live account at the time of writing the
/// missing bar read **10%** against all-models **8%**, i.e. the limit this user would hit *first*
/// was the one the app could not show. The data was already in the poll response
/// (`limits[]`, `kind: "weekly_scoped"`); nothing was fetched to fix it.
final class DisplayFormatterScopedLimitsTests: XCTestCase {

    // MARK: Fixtures — the live 2026-08-22 capture

    /// `2026-08-28T12:59:59.577098+00:00` — the all-models weekly reset.
    private static let weeklyResetsAt = Date(timeIntervalSince1970: 1_787_921_999.577098)
    /// `2026-08-28T12:59:59.577548+00:00` — the scoped reset. **450 microseconds later**, which is
    /// why the display cannot test these for equality.
    private static let scopedResetsAt = Date(timeIntervalSince1970: 1_787_921_999.577548)
    private static let primaryResetsAt = Date(timeIntervalSince1970: 1_787_452_199)

    private var now: Date { Self.primaryResetsAt.addingTimeInterval(-90 * 60) }

    private func fable(pct: Double? = 10, resetsAt: Date? = scopedResetsAt) -> AdditionalRateLimit {
        AdditionalRateLimit(id: nil, name: "Fable", usedPercent: pct, resetsAt: resetsAt)
    }

    /// Claude Max — the shape the live account has. Scoped limits ride in
    /// `additionalRateLimits`, the field Codex already used for its own sub-buckets.
    private func claudeSnapshot(scoped: [AdditionalRateLimit] = []) -> QuotaSnapshot {
        QuotaSnapshot(tool: .claude, primaryUsedPct: 38, primaryResetsAt: Self.primaryResetsAt,
                      secondaryUsedPct: 8, secondaryResetsAt: Self.weeklyResetsAt,
                      rateLimitReached: false, extraUsage: .disabled,
                      additionalRateLimits: scoped,
                      source: .oauth, email: "user@example.com", planType: "max")
    }

    private func labels(_ rows: [LabeledRow]) -> [String] { rows.map(\.label) }
    private func row(_ rows: [LabeledRow], _ label: String) -> LabeledRow? {
        rows.first { $0.label == label }
    }

    // MARK: The row

    /// The headline. `Fable used` sits directly under `Weekly used` — the grouping claude.ai
    /// itself uses — so the two weekly percentages can be compared without moving the eye.
    func testScopedLimitRendersUnderWeeklyUsed() {
        let rows = DisplayFormatter.quotaRows(
            state: .healthy, snapshot: claudeSnapshot(scoped: [fable()]), now: now,
            scopedLimits: [fable()])
        XCTAssertEqual(labels(rows),
                       ["5-hour left", "Resets at", "Weekly left", "Fable left", "Weekly resets"])
        XCTAssertEqual(row(rows, "Fable left")?.value, "90%")
        XCTAssertEqual(row(rows, "Fable left")?.explanationBridge?.text, "*90% left · 10% used*",
                       "the D-94 row opens its card with the rule 8 bridge line")
    }

    /// D-58 clause 3 — *render the windows you were sent*. An account with no scoped limit gets
    /// no row, never a `—`: a dash reads as a fetch failure where the truth is "no such limit".
    func testNoScopedLimitDrawsNoRow() {
        let rows = DisplayFormatter.quotaRows(state: .healthy, snapshot: claudeSnapshot(), now: now)
        XCTAssertEqual(labels(rows), ["5-hour left", "Resets at", "Weekly left", "Weekly resets"],
                       "the four always-show rows are untouched by this step")
    }

    /// A scoped limit is a weekly limit, so it colours by the weekly rule. Two weekly rows
    /// coloured by different thresholds would be a puzzle, not a feature.
    func testScopedRowUsesTheWeeklyThresholds() {
        func dot(_ pct: Double) -> StatusDot? {
            let limit = fable(pct: pct)
            return row(DisplayFormatter.quotaRows(state: .healthy,
                                                  snapshot: claudeSnapshot(scoped: [limit]),
                                                  now: now, scopedLimits: [limit]),
                       "Fable left")?.dot
        }
        XCTAssertEqual(dot(10), .green)
        XCTAssertEqual(dot(60), .amber)
        XCTAssertEqual(dot(86), .red)
    }

    /// An unnamed sub-bucket is skipped rather than drawn under a placeholder label — a row
    /// reading `Model limit 4%` states a fact about a limit we cannot name. The adapter drops
    /// these before they arrive; this pins the display's own guard.
    func testUnnamedScopedLimitDrawsNoRow() {
        let unnamed = AdditionalRateLimit(id: nil, name: nil, usedPercent: 4, resetsAt: nil)
        let rows = DisplayFormatter.quotaRows(
            state: .healthy, snapshot: claudeSnapshot(scoped: [unnamed]), now: now,
            scopedLimits: [unnamed])
        XCTAssertEqual(labels(rows), ["5-hour left", "Resets at", "Weekly left", "Weekly resets"])
    }

    // MARK: The reset row — one element, one fact

    /// Live, the scoped and all-models resets are 450 microseconds apart. `Weekly resets` speaks
    /// for both, so no second reset row is drawn. A bare equality test would print a duplicate.
    func testScopedResetWithinToleranceDrawsNoSecondResetRow() {
        let rows = DisplayFormatter.quotaRows(
            state: .healthy, snapshot: claudeSnapshot(scoped: [fable()]), now: now,
            scopedLimits: [fable()])
        XCTAssertFalse(labels(rows).contains("Fable resets"),
                       "the two weekly resets are the same boundary")
    }

    /// …but a genuinely separate deadline is its own fact and gets its own row. Nothing observed
    /// has this shape yet; the rule is written so that one renders itself when it appears.
    func testScopedResetOnADifferentDayDrawsItsOwnRow() {
        let separate = fable(resetsAt: Self.weeklyResetsAt.addingTimeInterval(86_400))
        let rows = DisplayFormatter.quotaRows(
            state: .healthy, snapshot: claudeSnapshot(scoped: [separate]), now: now,
            scopedLimits: [separate])
        XCTAssertEqual(labels(rows).last, "Fable resets",
                       "a different deadline sits after the weekly pair, not inside it")
        XCTAssertNotEqual(row(rows, "Fable resets")?.value, row(rows, "Weekly resets")?.value)
    }

    // MARK: Blast radius

    /// Codex renders its sub-buckets in the collapsed §2.7 section (D-10). It passes no scoped
    /// limits to this builder, so a Codex snapshot carrying them draws no extra rows — the same
    /// limit is never drawn twice, and the gate lives at the call site where the shape is known.
    func testCodexRowsUnchangedEvenWithSubBuckets() {
        let codex = QuotaSnapshot(
            tool: .codex, primaryUsedPct: 1, primaryResetsAt: Self.primaryResetsAt,
            primaryWindowSeconds: 300 * 60,
            secondaryUsedPct: 0, secondaryResetsAt: Self.weeklyResetsAt,
            rateLimitReached: false, extraUsage: .disabled,
            additionalRateLimits: [AdditionalRateLimit(id: "codex_spark", name: "Spark",
                                                       usedPercent: 3, resetsAt: nil)],
            source: .appServerRPC, planType: "enterprise")
        let rows = DisplayFormatter.quotaRows(state: .healthy, snapshot: codex, now: now)
        XCTAssertEqual(labels(rows), ["5-hour left", "Resets at", "Weekly left", "Weekly resets"])
    }

    /// End to end through `claude()`: the tab's `OTHER LIMITS` carries the row under its model's
    /// own group (STEP_178 — it was an Account-quota row until the cutover), which is what proves
    /// the call site passes the snapshot's limits at all.
    func testClaudeTabCarriesTheScopedRow() throws {
        let state = DisplayFormatter.claude(state: .healthy,
                                            snapshot: claudeSnapshot(scoped: [fable()]),
                                            forecast: nil, now: now)
        let group = try XCTUnwrap(state.otherLimits?.modelGroups.first { $0.name == "Fable" })
        XCTAssertEqual(group.rows.map(\.value), ["90%"])
        XCTAssertEqual(group.rows.map(\.explanation), [.scopedLimit])
    }

    // MARK: Expiry (Core rule, asserted here because this is the surface that shows it)

    /// R33-7 at sub-bucket grain: a scoped limit whose reset has passed describes spend already
    /// forgiven, so it degrades out before anything renders it — and it does not take its
    /// siblings with it.
    func testExpiredScopedLimitIsDroppedIndependently() {
        let live = AdditionalRateLimit(id: nil, name: "Fable", usedPercent: 10,
                                       resetsAt: Self.weeklyResetsAt)
        let expired = AdditionalRateLimit(id: nil, name: "Ghost", usedPercent: 99,
                                          resetsAt: Self.weeklyResetsAt.addingTimeInterval(-86_400))
        let degraded = claudeSnapshot(scoped: [live, expired])
            .degradingExpiredWindows(now: Self.weeklyResetsAt.addingTimeInterval(-60))
        XCTAssertEqual(degraded.additionalRateLimits.map(\.name), ["Fable"])
    }
}
