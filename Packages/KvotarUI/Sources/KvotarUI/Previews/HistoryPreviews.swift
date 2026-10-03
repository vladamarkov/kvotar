import SwiftUI
import KvotarCore

// The History window's states (STEP_115). PATTERNS.md names previews as the way SwiftUI views are
// checked, and four of these states are awkward to force against a live database: a machine that
// installed today, a tool watched but never used, and the 248-plan-flip corpus in particular.
// Figures are the dogfood machine's real shape (2026-08-17) so the layout is exercised at the
// widths real numbers actually need.

private enum HistoryStub {

    static let now = Date(timeIntervalSince1970: 1_786_968_000)     // 2026-08-17 12:00 UTC

    static func week(_ daysBack: Int, _ tokens: Int, _ value: Double,
                     partial: Bool = false) -> HistoryReport.Week {
        let end = now.addingTimeInterval(-Double(daysBack) * 86_400)
        return HistoryReport.Week(start: end.addingTimeInterval(-7 * 86_400), end: end,
                                  isPartial: partial, tokens: tokens, value: value)
    }

    static func totals(_ model: String, _ input: Int) -> SQLiteStore.ModelTokenTotals {
        SQLiteStore.ModelTokenTotals(model: model, inputTokens: input, outputTokens: 0,
                                     cacheCreationTokens: 0, cacheReadTokens: 0)
    }

    static func session(_ daysBack: Double, _ project: String?, _ tokens: Int,
                        _ value: Double) -> HistoryReport.Session {
        HistoryReport.Session(sessionId: UUID().uuidString, project: project, model: nil,
                              lastSeenAt: now.addingTimeInterval(-daysBack * 86_400),
                              tokens: tokens, value: value)
    }

    static let claude = HistoryReport.ToolReport(
        tool: .claude, sessions: 148, totalTokens: 1_700_000_000,
        modelTotals: [totals("claude-opus-5", 844_000_000), totals("claude-opus-4-8", 448_000_000),
                      totals("claude-fable-5", 405_000_000)],
        cacheHitRatio: 0.98, value: 1_759.33,
        projects: [HistoryReport.Project(name: "/Users/v/kvotar", sessions: 137, tokens: 1_780_000_000),
                   HistoryReport.Project(name: "/Users/v/.buzz", sessions: 8, tokens: 1_500_000),
                   HistoryReport.Project(name: nil, sessions: 3, tokens: 900_000)],
        topSessions: [session(5, "/Users/v/kvotar", 88_800_000, 55.47),
                      session(27, "/Users/v/kvotar", 73_700_000, 49.47),
                      session(3, "/Users/v/kvotar", 61_200_000, 40.90)],
        weeks: [week(0, 895_300_000, 946.66), week(7, 188_400_000, 123.21),
                week(14, 39_800_000, 34.19), week(21, 577_900_000, 525.05),
                week(28, 3_100_000, 2.90, partial: true)],
        evidenceFrom: now.addingTimeInterval(-48 * 86_400),
        // A plan change and a window restructuring — the two shapes *What changed* draws
        // (STEP_121; the fold of a same-instant width change + window added is STEP_141, the
        // 2026-08-25 Codex shape: weekly only → 5-hour + weekly).
        accountChanges: [
            HistoryReport.AccountChange(at: now.addingTimeInterval(-9 * 86_400),
                                        kind: .windowWidthChanged, windowType: "five_hour",
                                        oldValue: "604800", newValue: "18000"),
            HistoryReport.AccountChange(at: now.addingTimeInterval(-9 * 86_400),
                                        kind: .windowAdded, windowType: "weekly",
                                        newValue: "604800"),
            HistoryReport.AccountChange(at: now.addingTimeInterval(-3 * 86_400),
                                        kind: .planChanged, oldValue: "max", newValue: "max_20x"),
        ],
        // Three five-hour blocks, the dogfood shape: two that cost hours and one that fired on the
        // doorstep of its own reset. The third has no recoverable reset — the row survives, the
        // duration does not (STEP_120).
        limitBlocks: [block(18, hour: 15, minute: 12, lockout: nil, width: nil),
                      block(6, hour: 11, minute: 50, lockout: 10_143),
                      block(4, hour: 19, minute: 3, lockout: 405)],
        watchingSince: now.addingTimeInterval(-30 * 86_400),
        workPerPercent: WorkPerPercentSeries(slots: [
            // Four qualifying weekly cycles — the shape the STEP_119 summary speaks for. Fewer
            // than three would preview the `Not enough history yet` form, which `codex` covers.
            .init(isPrimary: false, windowSeconds: 604_800, byDay: false, points: [
                cycle(-24, 60, 545, 170_000_000),
                cycle(-17, 45, 470, 150_000_000, unexplained: 0.11),
                cycle(-10, 20, 248, 78_000_000, models: [("claude-opus-5", 12, 158),
                                                         ("claude-fable-5", 6, 51)]),
                cycle(-3, 26, 294, 97_000_000, complete: false, unexplained: 0.04),
            ]),
            .init(isPrimary: true, windowSeconds: 18_000, byDay: true, points: (0..<9).map {
                cycle(Double(-$0 - 1), 148, 1.6, 180_000, days: 1)
            })], markers: []),
        days: days(claudeShape, scale: 90_000_000, hitLimitOn: [12, 24, 26]),
        workByHour: hours(claudeHourShape, scale: 210_000_000))

    static let codex = HistoryReport.ToolReport(
        tool: .codex, sessions: 45, totalTokens: 28_700_000,
        modelTotals: [totals("gpt-5.5", 20_700_000), totals("gpt-5.6-sol", 8_000_000)],
        cacheHitRatio: 0.87, value: 34.43,
        projects: [HistoryReport.Project(name: "/Users/v/kvotar", sessions: 13, tokens: 28_100_000)],
        topSessions: [session(4, "/Users/v/kvotar", 10_700_000, 8.16)],
        weeks: [week(0, 17_200_000, 13.35), week(7, 0, 0), week(14, 1_700_000, 4.09),
                week(21, 1_100_000, 2.14)],
        evidenceFrom: now.addingTimeInterval(-48 * 86_400),
        // What the window actually draws for this corpus: the flood below, put through the same
        // collapse the reader applies, which leaves the one real change in it (STEP_121).
        accountChanges: PlanChangeStability.settled(floodChanges).map {
            HistoryReport.AccountChange(at: $0.at, kind: .planChanged,
                                        oldValue: $0.from, newValue: $0.to)
        },
        // A weekly primary window: the rows carry a lockout, and the chart is withheld — the hour
        // you were cut off hardly matters when the consequence runs to next Tuesday (D-80).
        limitBlocks: [block(22, hour: 2, lockout: nil, width: nil),
                      block(10, hour: 21, minute: 45, lockout: 605_053, width: 604_800)],
        watchingSince: now.addingTimeInterval(-30 * 86_400),
        workPerPercent: WorkPerPercentSeries(slots: [
            .init(isPrimary: true, windowSeconds: 604_800, byDay: false, points: [
                cycle(-9, 10, 6.2, 4_100_000)])], markers: []),
        days: days(codexShape, scale: 3_100_000, hitLimitOn: [8, 20]),
        workByHour: hours(codexHourShape, scale: 4_400_000))

    /// The dogfood corpus's 248 `enterprise ↔ business` flips — two Codex sources disagreeing
    /// about the plan name, recorded faithfully as history (STEP_109). Kept as a fixture because
    /// it is what `PlanChangeStability.settled` is *for*: the preview above renders it collapsed,
    /// which is one row, and that is the thing that must not regress.
    static var floodChanges: [PlanTransition] {
        var changes: [PlanTransition] = []
        let base: TimeInterval = -29 * 86_400
        for i in 0..<243 {
            let at: Date = now.addingTimeInterval(base + Double(i) * 300)
            let flip: Bool = i % 2 == 0
            changes.append(PlanTransition(at: at,
                                          from: flip ? "enterprise" : "business",
                                          to: flip ? "business" : "enterprise"))
        }
        changes.append(PlanTransition(at: now.addingTimeInterval(-6 * 86_400),
                                      from: "go", to: "plus"))
        return changes
    }

    /// 31 days ending on `now`'s day, oldest first — the shape the reader emits. `shape` is a
    /// per-day multiplier so a preview strip has the real corpus's lumpiness rather than a
    /// flat wall; the first slot is the clipped partial day.
    static func days(_ shape: [Double], scale: Int, hitLimitOn: Set<Int> = []) -> [HistoryReport.Day] {
        let midnight = Calendar.current.startOfDay(for: now)
        return shape.enumerated().map { index, weight in
            let tokens = Int(weight * Double(scale))
            return HistoryReport.Day(
                start: midnight.addingTimeInterval(-Double(shape.count - 1 - index) * 86_400),
                isPartial: index == 0, tokens: tokens,
                sessions: tokens > 0 ? max(1, Int(weight * 12)) : 0,
                hitLimit: hitLimitOn.contains(index))
        }
    }

    /// One recorded block. `lockout` nil is the honest unknown — the rollup could not supply the
    /// blocking window's reset — and takes the width with it, exactly as the reader does.
    static func block(_ daysBack: Double, hour: Int, minute: Int = 0,
                      lockout: Int?, width: Int? = 18_000) -> HistoryReport.LimitBlock {
        let midnight = Calendar.current.startOfDay(for: now)
        let firedAt = midnight.addingTimeInterval(-daysBack * 86_400
            + Double(hour) * 3600 + Double(minute) * 60)
        return HistoryReport.LimitBlock(
            firedAt: firedAt,
            resetAt: lockout.map { firedAt.addingTimeInterval(Double($0)) },
            windowSeconds: lockout == nil ? nil : width)
    }

    /// 24 weights → displayed tokens per local clock hour.
    static func hours(_ shape: [Double], scale: Int) -> [Int] {
        shape.map { Int($0 * Double(scale)) }
    }

    /// The dogfood machine's real shape: work peaks 9 pm – 1 am, and the blocks land in the
    /// afternoon — the whole point of drawing both (REV-73 §3).
    static let claudeHourShape: [Double] = [
        1.0, 0.51, 0.04, 0, 0, 0, 0, 0, 0.02, 0.34, 0.45, 0.26,
        0.18, 0.06, 0.15, 0.18, 0.10, 0.12, 0.15, 0.38, 0.41, 0.69, 0.63, 0.68]
    static let codexHourShape: [Double] = [
        0.23, 0.02, 0, 0, 0, 0, 0, 0, 0.05, 0, 0.68, 0,
        0, 0, 0.04, 1.0, 0, 0, 0.41, 0, 0.09, 0.79, 0.31, 0.12]

    /// 31 weights, the dogfood machine's rough 30-day shape (a quiet fortnight, then a heavy week).
    static let claudeShape: [Double] = [
        0.02, 0.31, 0.44, 0.12, 0, 0, 0.08, 0.62, 0.95, 0.71, 0.33, 0.05, 0, 0.02,
        0.11, 0.28, 0.04, 0, 0, 0.19, 0.47, 0.58, 0.22, 0.36, 1.0, 0.74, 0.41, 0.06, 0.29, 0.52, 0.34]
    static let codexShape: [Double] = [
        0, 0, 0.06, 0, 0, 0, 0, 0.11, 0.04, 0, 0, 0, 0, 0,
        0.02, 0, 0, 0, 0, 0, 0.21, 0.09, 0, 0.03, 1.0, 0.14, 0, 0, 0.07, 0.02, 0]

    static func cycle(_ startDaysBack: Double, _ delta: Double, _ dollars: Double, _ tokens: Int,
                      days: Double = 7, complete: Bool = true, unexplained: Double? = 0,
                      models: [(String, Double, Double)] = []) -> WorkPerPercentSeries.Point {
        let start = now.addingTimeInterval(startDaysBack * 86_400)
        return WorkPerPercentSeries.Point(
            start: start, end: start.addingTimeInterval(days * 86_400), isComplete: complete,
            deltaPct: delta, dollars: dollars, tokens: tokens,
            perModel: models.map { WorkPerPercentSeries.ModelRate(model: $0.0, deltaPct: $0.1,
                                                                  dollars: $0.2) },
            coverage: 0.9, unexplainedShare: unexplained, crossWindowRatio: nil)
    }

    static let blankCodex = HistoryReport.ToolReport(
        tool: .codex, sessions: 0, totalTokens: 0, modelTotals: [], cacheHitRatio: nil, value: 0,
        projects: [], topSessions: [], weeks: [], evidenceFrom: nil, accountChanges: [],
        watchingSince: nil, workPerPercent: .empty)

    static let freshClaude = HistoryReport.ToolReport(
        tool: .claude, sessions: 0, totalTokens: 0, modelTotals: [], cacheHitRatio: nil, value: 0,
        projects: [], topSessions: [], weeks: [], evidenceFrom: nil, accountChanges: [],
        watchingSince: nil, workPerPercent: .empty)

    static func report(_ tools: [HistoryReport.ToolReport]) -> HistoryReport {
        HistoryReport(periodStart: now.addingTimeInterval(-30 * 86_400), periodEnd: now,
                      tools: tools, pricingVersion: "1.2.0", pricingUpdated: "2026-08-12")
    }

    /// A Codex that was watched but never produced a token — the poll-evidence-only state.
    static let watchedCodex = HistoryReport.ToolReport(
        tool: .codex, sessions: 0, totalTokens: 0, modelTotals: [], cacheHitRatio: nil, value: 0,
        projects: [], topSessions: [], weeks: [], evidenceFrom: nil, accountChanges: [],
        limitBlocks: [block(10, hour: 21, minute: 45, lockout: nil, width: nil)],
        watchingSince: now.addingTimeInterval(-12 * 86_400), workPerPercent: .empty)

    /// A pinned calendar so a preview's recap weeks do not move with the reviewer's locale.
    static let previewCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        return calendar
    }()

    @MainActor
    static func model(_ tools: [HistoryReport.ToolReport],
                      mode: HistoryExperience.Mode = .weeklyRecap,
                      provider: HistoryExperience.Provider = .all) -> HistoryViewModel {
        let vm = HistoryViewModel(
            experience: HistoryDisplay.experience(report(tools), now: now,
                                                  calendar: previewCalendar))
        vm.mode = mode
        vm.provider = provider
        return vm
    }
}

#Preview("Weekly recap · both tools, dense") {
    HistoryView(viewModel: HistoryStub.model([HistoryStub.claude, HistoryStub.codex]))
        .frame(width: 860, height: 640)
}

#Preview("Weekly recap · dense (dark)") {
    HistoryView(viewModel: HistoryStub.model([HistoryStub.claude, HistoryStub.codex]))
        .frame(width: 860, height: 640)
        .preferredColorScheme(.dark)
}

#Preview("Explore quota · both tools") {
    HistoryView(viewModel: HistoryStub.model([HistoryStub.claude, HistoryStub.codex],
                                             mode: .exploreQuota))
        .frame(width: 860, height: 640)
}

#Preview("Explore quota · Claude filter") {
    HistoryView(viewModel: HistoryStub.model([HistoryStub.claude, HistoryStub.codex],
                                             mode: .exploreQuota, provider: .tool(.claude)))
        .frame(width: 860, height: 640)
}

#Preview("Explore usage · both tools, dense") {
    HistoryView(viewModel: HistoryStub.model([HistoryStub.claude, HistoryStub.codex],
                                             mode: .exploreUsage))
        .frame(width: 860, height: 640)
}

#Preview("Explore usage · dense (dark)") {
    HistoryView(viewModel: HistoryStub.model([HistoryStub.claude, HistoryStub.codex],
                                             mode: .exploreUsage))
        .frame(width: 860, height: 640)
        .preferredColorScheme(.dark)
}

#Preview("Hard blocks · both tools, dense") {
    HistoryView(viewModel: HistoryStub.model([HistoryStub.claude, HistoryStub.codex],
                                             mode: .hardBlocks))
        .frame(width: 860, height: 640)
}

#Preview("Weekly recap · minimum width (560)") {
    HistoryView(viewModel: HistoryStub.model([HistoryStub.claude, HistoryStub.codex]))
        .frame(width: 560, height: 420)
}

#Preview("Explore usage · minimum width (560)") {
    HistoryView(viewModel: HistoryStub.model([HistoryStub.claude, HistoryStub.codex],
                                             mode: .exploreUsage))
        .frame(width: 560, height: 420)
}

#Preview("Weekly recap · one tool only") {
    HistoryView(viewModel: HistoryStub.model([HistoryStub.claude, HistoryStub.blankCodex]))
        .frame(width: 860, height: 640)
}

#Preview("Explore quota · events-only provider") {
    HistoryView(viewModel: HistoryStub.model([HistoryStub.claude, HistoryStub.watchedCodex],
                                             mode: .exploreQuota, provider: .tool(.codex)))
        .frame(width: 860, height: 640)
}

#Preview("Hard blocks · no events") {
    HistoryView(viewModel: HistoryStub.model([HistoryStub.freshClaude,
                                              HistoryStub.watchedCodex],
                                             mode: .hardBlocks, provider: .tool(.claude)))
        .frame(width: 860, height: 640)
}

#Preview("History · nothing yet") {
    HistoryView(viewModel: HistoryStub.model([HistoryStub.freshClaude, HistoryStub.blankCodex]))
        .frame(width: 860, height: 640)
}

#Preview("History · loading") {
    HistoryView(viewModel: HistoryViewModel(load: { nil }))
        .frame(width: 860, height: 640)
}

#Preview("Weekly recap · an older week") {
    let vm = HistoryStub.model([HistoryStub.claude, HistoryStub.codex])
    vm.showOlderRecapWeek()
    return HistoryView(viewModel: vm).frame(width: 860, height: 640)
}

#Preview("Explore quota · a pinned window") {
    let vm = HistoryStub.model([HistoryStub.claude, HistoryStub.codex], mode: .exploreQuota)
    if let id = vm.experience?.pages(.all).quota.sections.first?.points.last?.id {
        vm.selectQuotaPoint(id)
    }
    return HistoryView(viewModel: vm).frame(width: 860, height: 640)
}

#Preview("Explore quota · scoped from the recap") {
    let vm = HistoryStub.model([HistoryStub.claude, HistoryStub.codex])
    if let link = vm.experience?.recap.weeks.first?.links
        .first(where: { $0.destination.mode == .exploreQuota }) {
        vm.navigate(to: link.destination)
    }
    return HistoryView(viewModel: vm).frame(width: 860, height: 640)
}
