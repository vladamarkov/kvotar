import XCTest
import KvotarCore
@testable import KvotarUI

/// STEP_176 — the header built from the selection: same-limit identity across hero %, caption,
/// verdict family and explanation element; the Other Limits rows; the two scoped header facts.
final class DisplayFormatterOtherLimitsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(tool: Tool = .claude, used: Double? = 40, resetsInMin: Double? = 120,
                          windowSeconds: Int? = 18_000, weekly: Double? = 30,
                          models: [AdditionalRateLimit] = []) -> QuotaSnapshot {
        QuotaSnapshot(tool: tool, primaryUsedPct: used,
                      primaryResetsAt: resetsInMin.map { now.addingTimeInterval($0 * 60) },
                      primaryWindowSeconds: windowSeconds, secondaryUsedPct: weekly,
                      secondaryResetsAt: weekly == nil ? nil : now.addingTimeInterval(5 * 86_400),
                      rateLimitReached: false, extraUsage: tool == .claude ? .disabled : nil,
                      additionalRateLimits: models,
                      source: tool == .codex ? .appServerRPC : .oauth,
                      email: "user@example.com", planType: "max")
    }

    private func forecast(_ tool: Tool = .claude, runway: Double? = 300, burn: Double? = 0.2) -> Forecast {
        Forecast(tool: tool, tier: .fullRunway, runwayMinutes: runway, burnRatePerMin: burn,
                 isEstimate: false, pollCount: 10)
    }

    private func spark(primaryUsed: Double = 3, weeklyUsed: Double) -> AdditionalRateLimit {
        AdditionalRateLimit(id: "codex_bengalfox", name: "GPT-5.3-Codex-Spark", usedPercent: primaryUsed,
                            resetsAt: now.addingTimeInterval(3600), primaryWindowSeconds: 18_000,
                            secondary: .init(usedPercent: weeklyUsed,
                                             resetsAt: now.addingTimeInterval(6 * 86_400),
                                             windowSeconds: 604_800))
    }

    // MARK: Same-limit identity

    /// **REV-96 §2.4 (STEP_194) replaces the weekly promotion with a strip.** A nearly-spent
    /// weekly no longer takes the header: the five-hour number the reader is spending against
    /// keeps it, its verdict is scoped to say so, and the weekly speaks in one red line under it.
    func testNearlySpentWeeklyKeepsTheFiveHourHeroAndTakesAStrip() {
        let s = snapshot(used: 0, weekly: 91)
        let header = DisplayFormatter.header(tool: .claude, state: .limitNearlySpent, snapshot: s,
                                             forecast: forecast(), now: now)
        XCTAssertEqual(header.limit?.id, .primaryWindow)
        XCTAssertEqual(header.heroText, "100%", "the number is the five-hour's, whole")
        XCTAssertEqual(header.limitCaption, "5-hour quota left")
        XCTAssertEqual(header.heroExplanation, .heroPercent)
        XCTAssertEqual(header.verdict?.line1, "Safe at this pace — 5-hour reset comes first",
                       "scoped, so it cannot be read as *you are fine*")
        XCTAssertEqual(header.verdict?.colour, .green,
                       "a weekly rank must not paint a sentence about the five-hour window red")
        let strip = try! XCTUnwrap(header.longLimitStrip)
        XCTAssertEqual(strip.limitID, .secondaryWindow)
        XCTAssertEqual(strip.cue, .red)
        XCTAssertEqual(strip.text, "Weekly nearly spent — 9% left for 5 days, resets "
                       + Fmt.monthDay(now.addingTimeInterval(5 * 86_400)))
        // The weekly sits in Other Limits with its place in the week — and **without** the tier
        // word, because the strip four lines above it is about this row (REV-98 §2.5(c)).
        let state = DisplayFormatter.claude(state: .limitNearlySpent, snapshot: s,
                                            forecast: forecast(),
                                            localAttribution: nil, now: now)
        XCTAssertEqual(state.otherLimits?.rows.map(\.id), [.secondaryWindow])
        XCTAssertEqual(state.otherLimits?.rows[0].value, "9%")
        XCTAssertEqual(state.otherLimits?.rows[0].isHighlighted, true)
        XCTAssertEqual(state.otherLimits?.rows[0].cue, .red, "the row takes the strip's tier")
        XCTAssertEqual(state.otherLimits?.rows[0].reset,
                       "resets \(Fmt.monthDay(now.addingTimeInterval(5 * 86_400))) · day 3 of 7")
        XCTAssertEqual(state.otherLimits?.rows[0].explanation, .secondaryWindow)
    }

    func testPrimaryHeroIsUnchangedFromBeforeAndListsTheWeekly() {
        let s = snapshot()
        let header = DisplayFormatter.header(tool: .claude, state: .healthy, snapshot: s,
                                             forecast: forecast(), now: now)
        XCTAssertEqual(header.limit?.id, .primaryWindow)
        XCTAssertEqual(header.heroText, "60%")
        XCTAssertEqual(header.limitCaption, "5-hour quota left")
        XCTAssertEqual(header.heroExplanation, .heroPercent)
        XCTAssertEqual(header.verdict?.family, .resetsFirst)
        let state = DisplayFormatter.claude(state: .healthy, snapshot: s, forecast: forecast(),
                                            localAttribution: nil, now: now)
        XCTAssertEqual(state.otherLimits?.rows.map(\.label), ["Weekly"])
        // The tier and the week's position join the row (REV-96 §3.7 — STEP_194).
        XCTAssertEqual(state.otherLimits?.rows[0].value, "70% · on pace")
        XCTAssertEqual(state.otherLimits?.rows[0].reset,
                       "resets \(Fmt.monthDay(now.addingTimeInterval(5 * 86_400))) · day 3 of 7")
    }

    func testModelWarningStaysBelowTheAccountHeaderAndInOtherLimits() {
        let s = snapshot(tool: .codex, used: 4, resetsInMin: 6 * 1440, windowSeconds: 604_800,
                         weekly: nil, models: [spark(weeklyUsed: 92)])
        let header = DisplayFormatter.header(tool: .codex, state: .healthy, snapshot: s,
                                             forecast: forecast(.codex), now: now)
        XCTAssertEqual(header.limit?.id, .primaryWindow)
        XCTAssertEqual(header.heroText, "96%")
        XCTAssertEqual(header.limitCaption, "Weekly quota left")
        XCTAssertEqual(header.heroExplanation, .heroPercent)
        let warning = try! XCTUnwrap(header.modelWarnings.first)
        XCTAssertEqual(warning.id, .modelWindow(allowance: "codex_bengalfox", slot: .secondary))
        XCTAssertEqual(warning.headline, "⚠ GPT-5.3-Codex-Spark weekly · 8% left")
        XCTAssertEqual(warning.detail,
                       "Only this model’s allowance · resets \(Fmt.monthDay(now.addingTimeInterval(6 * 86_400)))")
        XCTAssertEqual(warning.cue, .amber)
        let state = DisplayFormatter.codex(state: .healthy, snapshot: s, forecast: forecast(.codex),
                                           localAttribution: nil, now: now)
        XCTAssertEqual(state.otherLimits?.rows.map(\.label), [])
        let group = try! XCTUnwrap(state.otherLimits?.modelGroups.first)
        XCTAssertEqual(group.name, "GPT-5.3-Codex-Spark")
        XCTAssertTrue(group.showsHeading)
        XCTAssertEqual(group.rows.map(\.label), ["5-hour", "Weekly"])
        XCTAssertEqual(group.rows[0].explanation, .scopedLimit)
        XCTAssertEqual(group.rows[0].value, "97%")
        XCTAssertEqual(group.rows[1].value, "8%")
    }

    func testFableWarningDoesNotReplaceTheFiveHourAccountSummary() {
        let fable = AdditionalRateLimit(
            id: "fable", name: "Fable", usedPercent: 97,
            resetsAt: now.addingTimeInterval(5 * 86_400),
            primaryWindowSeconds: 604_800)
        let s = snapshot(used: 45, weekly: 20, models: [fable])
        let state = DisplayFormatter.claude(state: .healthy, snapshot: s,
                                            forecast: forecast(), localAttribution: nil, now: now)
        XCTAssertEqual(state.header?.heroText, "55%")
        XCTAssertEqual(state.header?.limit?.id, .primaryWindow)
        XCTAssertEqual(state.header?.modelWarnings.map(\.headline),
                       ["⚠ Fable weekly · 3% left"])
        let group = try! XCTUnwrap(state.otherLimits?.modelGroups.first)
        XCTAssertFalse(group.showsHeading)
        XCTAssertEqual(group.rows.map(\.label), ["Fable weekly"])
        XCTAssertEqual(group.rows.map(\.value), ["3%"])
    }

    func testMainWeeklyAndBothSparkWindowsRemainVisible() {
        let s = snapshot(tool: .codex, used: 2, resetsInMin: 6 * 1440,
                         windowSeconds: 604_800, weekly: nil,
                         models: [spark(primaryUsed: 0, weeklyUsed: 97)])
        let state = DisplayFormatter.codex(state: .healthy, snapshot: s,
                                           forecast: forecast(.codex),
                                           localAttribution: nil, now: now)
        XCTAssertEqual(state.header?.heroText, "98%")
        XCTAssertEqual(state.header?.limitCaption, "Weekly quota left")
        XCTAssertEqual(state.header?.modelWarnings.map(\.headline),
                       ["⚠ GPT-5.3-Codex-Spark weekly · 3% left"])
        let group = try! XCTUnwrap(state.otherLimits?.modelGroups.first)
        XCTAssertTrue(group.showsHeading)
        XCTAssertEqual(group.rows.map(\.label), ["5-hour", "Weekly"])
        XCTAssertEqual(group.rows.map(\.value), ["100%", "3%"])
    }

    func testUnknownAccountHeaderCanCarryAFreshModelWarningButNotAStaleOne() {
        let fable = AdditionalRateLimit(id: "fable", name: "Fable", usedPercent: 97,
                                        resetsAt: now.addingTimeInterval(5 * 86_400),
                                        primaryWindowSeconds: 604_800)
        let s = snapshot(tool: .codex, used: nil, resetsInMin: nil,
                         windowSeconds: nil, weekly: nil, models: [fable])
        let fresh = DisplayFormatter.codex(state: .nullWindow, snapshot: s, forecast: nil,
                                           localAttribution: nil, now: now)
        XCTAssertEqual(fresh.header?.heroText, "——")
        XCTAssertEqual(fresh.header?.limit?.id, .primaryWindow)
        XCTAssertEqual(fresh.header?.modelWarnings.count, 1)

        let stale = DisplayFormatter.codex(state: .nullWindow, snapshot: s, forecast: nil,
                                           localAttribution: nil,
                                           staleAsOf: now.addingTimeInterval(-900), now: now)
        XCTAssertTrue(stale.header?.modelWarnings.isEmpty == true)
    }

    func testPrimaryWarningKeepsItsForecastBesideAModelWarning() {
        let fable = AdditionalRateLimit(id: "fable", name: "Fable", usedPercent: 97,
                                        resetsAt: now.addingTimeInterval(5 * 86_400),
                                        primaryWindowSeconds: 604_800)
        let state = DisplayFormatter.claude(
            state: .elevated, snapshot: snapshot(used: 80, weekly: 20, models: [fable]),
            forecast: forecast(runway: 30, burn: 0.6), localAttribution: nil, now: now)
        XCTAssertEqual(state.header?.limit?.id, .primaryWindow)
        XCTAssertEqual(state.header?.heroText, "20%")
        XCTAssertEqual(state.header?.modelWarnings.map(\.headline),
                       ["⚠ Fable weekly · 3% left"])
        XCTAssertTrue((state.header?.verdict?.line1 ?? "").contains("~30m"))
    }

    func testInlineResetCarriesFullTimestampAndUnknownIsExplicit() {
        let known = snapshot(tool: .codex, models: [spark(weeklyUsed: 20)])
        let knownState = DisplayFormatter.codex(state: .healthy, snapshot: known,
                                                forecast: forecast(.codex),
                                                localAttribution: nil, now: now)
        let knownRow = try! XCTUnwrap(knownState.otherLimits?.modelGroups.first?.rows.last)
        XCTAssertEqual(knownRow.resetAccessibilityText,
                       "Resets \(Fmt.fullResetDateTime(now.addingTimeInterval(6 * 86_400)))")

        let unknown = AdditionalRateLimit(id: "fable", name: "Fable", usedPercent: 20,
                                          resetsAt: nil, primaryWindowSeconds: nil)
        let unknownState = DisplayFormatter.codex(
            state: .healthy, snapshot: snapshot(tool: .codex, weekly: nil, models: [unknown]),
            forecast: forecast(.codex), localAttribution: nil, now: now)
        XCTAssertEqual(unknownState.otherLimits?.modelGroups.first?.rows.first?.reset,
                       "reset unknown")
    }

    func testOtherLimitsIsSuppressedWhenEmpty() {
        let state = DisplayFormatter.claude(state: .healthy, snapshot: snapshot(weekly: nil),
                                            forecast: forecast(), localAttribution: nil, now: now)
        XCTAssertNil(state.otherLimits)
    }

    func testUnanchoredModelWindowReadsNotStartedInOtherLimits() {
        let notStarted = AdditionalRateLimit(id: "codex_bengalfox", name: "GPT-5.3-Codex-Spark",
                                             usedPercent: 0, resetsAt: nil, primaryWindowSeconds: 18_000)
        let state = DisplayFormatter.codex(state: .healthy,
                                           snapshot: snapshot(tool: .codex, weekly: nil, models: [notStarted]),
                                           forecast: forecast(.codex), localAttribution: nil, now: now)
        let row = try! XCTUnwrap(state.otherLimits?.modelGroups.first?.rows.first)
        XCTAssertEqual(row.value, "100%")
        XCTAssertEqual(row.reset, "not started")
    }

    // MARK: Header facts — scope

    /// The scoped-interval labels survive STEP_194, but only where a hero that is not the
    /// primary window still occurs — a spent weekly, which is the one limit that takes the header
    /// now. The facts underneath it are still the five-hour's and still say so.
    func testHeaderFactsAreLabelledWithThePrimaryIntervalUnderABlockingWeeklyHero() {
        let s = snapshot(used: 0, weekly: 100)
        let off = WindowAttribution(offMachinePct: 12, localPct: 30, unattributedPct: 0, totalUsedPct: 42)
        let state = DisplayFormatter.claude(state: .overQuota, snapshot: s, forecast: forecast(),
                                            localAttribution: nil, offMachine: off, now: now)
        XCTAssertEqual(state.header?.limit?.id, .secondaryWindow, "the limit that stopped you")
        let burn = try! XCTUnwrap(state.header?.accountBurn)
        XCTAssertEqual(burn.limitID, .primaryWindow)
        XCTAssertEqual(burn.label, "Quota burn · 5-hour", "the interval is named when it is not the hero's")
        XCTAssertEqual(burn.intervalLabel, "5-hour")
        XCTAssertEqual(burn.value, "Low · 0.2% / min")
        let notSeen = try! XCTUnwrap(state.header?.notSeenLocally)
        XCTAssertEqual(notSeen.limitID, .primaryWindow)
        XCTAssertEqual(notSeen.label, "Not seen locally · 5-hour")
        XCTAssertEqual(notSeen.value, "≈12% (est.)")
    }

    func testHeaderFactsUnderThePrimaryHeroUseTheSpecLabels() {
        let state = DisplayFormatter.claude(state: .healthy, snapshot: snapshot(), forecast: forecast(),
                                            localAttribution: nil, offMachine: nil, now: now)
        XCTAssertEqual(state.header?.accountBurn?.label, "Quota burn")
        XCTAssertEqual(state.header?.notSeenLocally?.label, "Not seen locally")
        XCTAssertEqual(state.header?.notSeenLocally?.value, "—", "unknown, never zero")
        XCTAssertEqual(state.header?.notSeenLocally?.availability, .unknown)
    }

    func testUnknownBurnIsUnknownAndLowAllowanceIsInapplicable() {
        let measuring = DisplayFormatter.claude(state: .healthy, snapshot: snapshot(),
                                                forecast: forecast(runway: nil, burn: nil),
                                                localAttribution: nil, now: now)
        XCTAssertNil(measuring.header?.accountBurn)
        let go = QuotaSnapshot(tool: .codex, primaryUsedPct: 40,
                               primaryResetsAt: now.addingTimeInterval(20 * 86_400),
                               primaryWindowSeconds: 30 * 86_400, secondaryUsedPct: nil,
                               secondaryResetsAt: nil, rateLimitReached: false, extraUsage: .disabled,
                               source: .appServerRPC, email: nil, planType: "go")
        let low = DisplayFormatter.codex(state: .healthy, snapshot: go, forecast: nil,
                                         localAttribution: nil, now: now)
        if case .inapplicable? = low.header?.accountBurn?.availability {} else {
            XCTFail("low-allowance shape must mark the burn inapplicable")
        }
    }

    func testStaleFactsAreUnknownNotStale() {
        let state = DisplayFormatter.claude(state: .idleFallback, snapshot: snapshot(), forecast: nil,
                                            localAttribution: nil, staleAsOf: now.addingTimeInterval(-900),
                                            now: now)
        XCTAssertNil(state.header?.accountBurn)
        XCTAssertEqual(state.header?.notSeenLocally?.value, "—")
    }
}
