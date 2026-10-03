import XCTest
import KvotarCore
@testable import KvotarUI

/// STEP_177 — the `LOCAL ACTIVITY · TODAY` payload: three distinct empty-ish states, retained
/// numbers under a dated qualifier, a recent rate that ages out, and value rows on every plan.
final class DisplayFormatterLocalActivityTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_789_048_800)   // 2026-09-10 14:00 UTC
    private var dayStart: Date { now.addingTimeInterval(-14 * 3600) }

    private func snapshot(plan: String = "pro", tool: Tool = .claude) -> QuotaSnapshot {
        QuotaSnapshot(tool: tool, primaryUsedPct: 38,
                      primaryResetsAt: now.addingTimeInterval(2 * 3600),
                      secondaryUsedPct: 14, secondaryResetsAt: nil,
                      rateLimitReached: false, extraUsage: .disabled, planType: plan)
    }

    private func attribution(rate: Double? = 350, computedAt: Date?) -> LocalAttribution {
        LocalAttribution(project: "/u/kvotar", model: "claude-fable-5-1", surfaceBucket: "Claude Code",
                         subagentCount: 0, cacheHitRatio: 0.5,
                         estValue: .init(weekly: 8.20, thirtyDay: 33.97, today: 1.5),
                         surfaceShares: [], tokensPerMinute: rate, lastActivityAt: now,
                         computedAt: computedAt)
    }

    private func project(_ name: String?, tokens: Int, at: TimeInterval,
                         models: [(String?, Int)]) -> DailyLocalReport.Project {
        DailyLocalReport.Project(
            name: name, tokens: tokens,
            models: models.map { .init(model: $0.0, tokens: $0.1, value: 0.1) },
            latestEventAt: dayStart.addingTimeInterval(at), value: 0.5)
    }

    private func report(_ projects: [DailyLocalReport.Project], tool: Tool = .claude,
                        sessions: Int = 3, cache: Double? = 0.71,
                        surfaces: [DailyLocalReport.Surface] = []) -> DailyLocalReport {
        DailyLocalReport(tool: tool, dayStart: dayStart, readUntil: now,
                         totalTokens: projects.reduce(0) { $0 + $1.tokens },
                         sessionCount: sessions, cacheHitRatio: cache, projects: projects,
                         lastEventAt: projects.map(\.latestEventAt).max(),
                         value: projects.reduce(0) { $0 + $1.value },
                         surfaces: surfaces)
    }

    /// STEP_197 fixtures: one app's day-share, `at` seconds after local midnight.
    private func surface(_ bucket: String, tokens: Int, at: TimeInterval)
        -> DailyLocalReport.Surface {
        DailyLocalReport.Surface(bucket: bucket, tokens: tokens,
                                 latestEventAt: dayStart.addingTimeInterval(at))
    }

    private func codexSection(_ surfaces: [DailyLocalReport.Surface]) -> LocalActivitySection {
        let r = report([project("/Users/u/kvotar", tokens: 14_400_000, at: 22 * 3600,
                                models: [("gpt-6-astra", 14_400_000)])],
                       tool: .codex, surfaces: surfaces)
        return DisplayFormatter.localActivitySection(tool: .codex, report: .available(r),
                                                     attribution: attribution(computedAt: now),
                                                     snapshot: snapshot(), now: now)
    }

    private var populated: DailyLocalReport {
        report([
            project("/Users/u/big", tokens: 1_200_000, at: 10 * 3600,
                    models: [("claude-fable-5-1", 1_000_000), ("claude-sonnet-5", 200_000)]),
            project("/Users/u/mid", tokens: 300_000, at: 9 * 3600, models: [("claude-fable-5-1", 300_000)]),
            project(nil, tokens: 50_000, at: 13 * 3600, models: [(nil, 50_000)]),
            project("/Users/u/tiny", tokens: 1_000, at: 8 * 3600, models: [("claude-sonnet-5", 1_000)]),
        ])
    }

    // MARK: - Availability

    func testNoReportYetIsLoading() {
        let c = DisplayFormatter.claude(state: .healthy, snapshot: snapshot(), forecast: nil,
                                        localAttribution: attribution(computedAt: now), now: now)
        let s = try! XCTUnwrap(c.localActivity)
        XCTAssertEqual(s.availability, .loading)
        XCTAssertEqual(s.statusCopy, "Loading local activity…")
        XCTAssertNil(s.summary)
        XCTAssertTrue(s.projects.isEmpty)
        XCTAssertEqual(s.cacheHit, "—")
        XCTAssertEqual(s.valueRows.map(\.label), ["Today", "7-day", "30-day"])
        XCTAssertEqual(s.valueRows.map(\.value), ["—", "$8.20", "$33.97"],
                       "Today unknown until read; rolling horizons come from the attribution")
    }

    func testFreshEmptyReadSaysNothingObservedNotZeroSessions() {
        let s = DisplayFormatter.localActivitySection(
            tool: .claude, report: .available(report([], sessions: 0, cache: nil)),
            attribution: nil, snapshot: snapshot(), now: now)
        XCTAssertEqual(s.availability, .empty)
        XCTAssertEqual(s.statusCopy, "No local activity observed today")
        XCTAssertNil(s.summary, "never `0 tokens · 0 sessions` as an observation")
        XCTAssertEqual(s.cacheHit, "—")
        XCTAssertEqual(s.valueRows.map(\.value), ["$0.00", "—", "—"])
    }

    func testUnavailableWithNothingRetained() {
        let s = DisplayFormatter.localActivitySection(
            tool: .claude, report: .unavailable(retained: nil, failedAt: now),
            attribution: nil, snapshot: snapshot(), now: now)
        XCTAssertEqual(s.availability, .unavailable)
        XCTAssertEqual(s.statusCopy, "Local activity unavailable")
        XCTAssertEqual(s.valueRows[0].value, "—", "a failed read is never $0.00")
    }

    func testFailedRefreshKeepsRetainedNumbersUnderADatedQualifier() {
        let earlier = report([project("/u/a", tokens: 900, at: 3600, models: [("claude-sonnet-5", 900)])])
        let s = DisplayFormatter.localActivitySection(
            tool: .claude, report: .unavailable(retained: earlier, failedAt: now),
            attribution: nil, snapshot: snapshot(), now: now)
        XCTAssertEqual(s.availability, .staleRetained(asOf: now))
        XCTAssertEqual(s.statusCopy, "As of \(Fmt.clock(now)) · couldn’t refresh")
        XCTAssertEqual(s.summary?.value, "900 tokens · 3 sessions")
        XCTAssertEqual(s.projects.map(\.name), ["a"])
    }

    // MARK: - Populated

    func testPopulatedSummaryRowsMarkerAndOverflow() {
        let s = DisplayFormatter.localActivitySection(
            tool: .claude, report: .available(populated),
            attribution: attribution(computedAt: now), snapshot: snapshot(), now: now)
        XCTAssertEqual(s.availability, .available)
        XCTAssertNil(s.statusCopy)
        XCTAssertEqual(s.summary?.label, "Claude Code")
        XCTAssertEqual(s.summary?.value, "1.6M tokens · 3 sessions")
        XCTAssertEqual(s.summary?.explanation, .localActivity)
        XCTAssertEqual(s.cacheHit, "71%")
        XCTAssertEqual(s.recentRate, "~350 tokens/min")
        // Top two by tokens, then the most recent — the (no project) row, kept and named.
        XCTAssertEqual(s.projects.map(\.name), ["big", "mid", "(no project)"])
        XCTAssertEqual(s.projects.map(\.fullName), ["/Users/u/big", "/Users/u/mid", nil])
        XCTAssertEqual(s.projects.map(\.isMostRecent), [false, false, true])
        XCTAssertEqual(s.projects[0].models.map(\.name), ["fable-5-1", "sonnet-5"])
        XCTAssertEqual(s.projects[0].models.map(\.tokens), ["1.0M", "200k"])
        XCTAssertEqual(s.projects[2].models.map(\.name), ["Unknown model"])
        XCTAssertEqual(s.moreCount, 1)
        XCTAssertEqual(s.valueRows.map(\.value), ["$2.00", "$8.20", "$33.97"])
        XCTAssertEqual(s.lastEventAt, dayStart.addingTimeInterval(13 * 3600))
        XCTAssertEqual(s.readAt, now)
    }

    func testCodexUsesThreadsAndSingularForms() {
        let one = report([project("/u/x", tokens: 10, at: 1, models: [("gpt-5.5", 10)])],
                         tool: .codex, sessions: 1)
        let s = DisplayFormatter.localActivitySection(
            tool: .codex, report: .available(one), attribution: nil,
            snapshot: snapshot(plan: "plus", tool: .codex), now: now)
        XCTAssertEqual(s.summary?.label, "Codex")
        XCTAssertEqual(s.summary?.value, "10 tokens · 1 thread")
        XCTAssertEqual(s.projects[0].models[0].name, "gpt-5.5")
    }

    // MARK: - Recent rate freshness

    func testRecentRateIsCurrentOnlyWithinTheTwoMinuteHorizon() {
        XCTAssertEqual(DisplayFormatter.recentRateValue(attribution(computedAt: now.addingTimeInterval(-60)),
                                                        now: now), "~350 tokens/min")
        XCTAssertEqual(DisplayFormatter.recentRateValue(attribution(computedAt: now.addingTimeInterval(-121)),
                                                        now: now), "—", "older than the horizon")
        XCTAssertEqual(DisplayFormatter.recentRateValue(attribution(computedAt: nil), now: now), "—",
                       "unstamped attribution is age-unknown, never fresh")
        XCTAssertEqual(DisplayFormatter.recentRateValue(attribution(rate: nil, computedAt: now), now: now), "—")
        XCTAssertEqual(DisplayFormatter.recentRateValue(nil, now: now), "—")
    }

    // MARK: - Value note and plan independence

    func testValueNoteNamesTheOrganizationOnSeatPlans() {
        for plan in ["team", "enterprise", "business", "enterprise_cbp_usage_based"] {
            let s = DisplayFormatter.localActivitySection(
                tool: .claude, report: .available(populated), attribution: nil,
                snapshot: snapshot(plan: plan), now: now)
            XCTAssertEqual(s.valueNote, LocalActivitySection.organizationValueNote, plan)
        }
        for plan in ["pro", "max", "plus", "go", "free"] {
            let s = DisplayFormatter.localActivitySection(
                tool: .claude, report: .available(populated), attribution: nil,
                snapshot: snapshot(plan: plan), now: now)
            XCTAssertEqual(s.valueNote, LocalActivitySection.valueNote, plan)
        }
    }

    func testValueRowsRenderOnEveryPlanIncludingEnterprise() {
        // REV-92 supersedes the REV-47 Claude-monthly suppression for this payload: the section
        // is built without looking at the layout, so an Enterprise seat gets its rows too.
        let s = DisplayFormatter.localActivitySection(
            tool: .claude, report: .available(populated),
            attribution: attribution(computedAt: now), snapshot: snapshot(plan: "enterprise"), now: now)
        XCTAssertEqual(s.valueRows.map(\.value), ["$2.00", "$8.20", "$33.97"])
    }
    // MARK: The section's own chrome (STEP_178)

    private func built(_ report: DailyLocalReport) -> LocalActivitySection {
        DisplayFormatter.localActivitySection(tool: .claude, report: .available(report),
                                              attribution: attribution(computedAt: now),
                                              snapshot: snapshot(), now: now)
    }

    /// The overflow label is composed by the formatter, never pluralised in a view, and absent
    /// when nothing is hidden.
    func testOverflowLabelIsComposedAndAbsentWhenNothingIsHidden() {
        let many = built(populated)
        XCTAssertEqual(many.moreCount, 1)
        XCTAssertEqual(many.overflowLabel, "1 more project")

        let two = built(report([
            project("/Users/u/big", tokens: 400, at: 10 * 3600, models: [("m", 400)]),
            project("/Users/u/mid", tokens: 300, at: 9 * 3600, models: [("m", 300)]),
        ]))
        XCTAssertEqual(two.moreCount, 0)
        XCTAssertNil(two.overflowLabel)
    }

    /// The collector's freshness tag stamps the **newest observed event of the day**, not the
    /// poll and not the read: an old last event dates the evidence, never the reader.
    func testSourceTagStampsTheNewestObservedEvent() {
        let s = built(report([
            project("/Users/u/big", tokens: 400, at: 14 * 3600 - 240, models: [("m", 400)]),
        ]))
        XCTAssertEqual(s.sourceTag?.base, "Source: Claude Code JSONL")
        XCTAssertEqual(s.sourceTag?.age, "4m ago")
    }


    // MARK: STEP_197 — the day's local apps (UI Spec §REV92 / D-118)

    /// A two-app day names both, tokens descending, with the marker on the app observed most
    /// recently — and `Unknown` renamed, because it is a bucket, not an app.
    func testTwoAppDayNamesBothAndMarksTheMostRecent() {
        let s = codexSection([
            surface("Desktop", tokens: 9_900_000, at: 16 * 3600),
            surface("CLI", tokens: 4_500_000, at: 22 * 3600),
        ])
        XCTAssertEqual(s.surfaces.map(\.name), ["Desktop", "CLI"])
        XCTAssertEqual(s.surfaces.map(\.tokens), ["9.9M", "4.5M"])
        XCTAssertEqual(s.surfaces.map(\.isMostRecent), [false, true])
    }

    /// Tonight's real shape: the CLI's pre-STEP_192 rows are stored as `Unknown` and stay
    /// visible under a name that says what they are, so the rows still sum to the line above.
    func testUnknownBucketRendersAsUnknownApp() {
        let s = codexSection([
            surface("Desktop", tokens: 9_900_000, at: 16 * 3600),
            surface("Unknown", tokens: 4_300_000, at: 22 * 3600 + 53 * 60),
            surface("CLI", tokens: 209_600, at: 22 * 3600 + 56 * 60),
        ])
        XCTAssertEqual(s.surfaces.map(\.name), ["Desktop", "Unknown app", "CLI"])
        XCTAssertEqual(s.surfaces.last?.isMostRecent, true)
        XCTAssertFalse(s.surfaces.contains { $0.name == "Unknown" })
    }

    /// The one-app user is the design target: a single row would restate the summary, so there
    /// are no rows at all. The report still carries the split.
    func testOneAppDayShowsNoRows() {
        XCTAssertTrue(codexSection([surface("Desktop", tokens: 14_400_000, at: 16 * 3600)])
            .surfaces.isEmpty)
        XCTAssertTrue(codexSection([]).surfaces.isEmpty)
    }

    /// Claude observes one surface by construction (REV-81) — even handed a split, its tab
    /// renders none.
    func testClaudeRendersNoSurfaceRows() {
        let r = report([project("/Users/u/big", tokens: 1_200_000, at: 10 * 3600,
                                models: [("claude-fable-5-1", 1_200_000)])],
                       surfaces: [surface("Claude Code", tokens: 1_000_000, at: 10 * 3600),
                                  surface("Unknown", tokens: 200_000, at: 11 * 3600)])
        XCTAssertTrue(built(r).surfaces.isEmpty)
    }

    /// Two apps sharing a last event pick deterministically — the earlier rank wins, the same
    /// rule the project selection applies.
    func testEqualRecencyBreaksByRank() {
        let s = codexSection([
            surface("Desktop", tokens: 9_000_000, at: 20 * 3600),
            surface("CLI", tokens: 1_000_000, at: 20 * 3600),
        ])
        XCTAssertEqual(s.surfaces.map(\.isMostRecent), [true, false])
    }
}
