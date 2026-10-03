import XCTest
import KvotarCore
@testable import KvotarUI

/// The shape of the render contract (STEP_159 — REV-84/D-108; four modes STEP_182 — REV-93/
/// D-115): mode names and order, the cross-provider recap at the root, provider order, footer and
/// pricing copy, the whole-report empty state, and the structural bans — no combined token figure,
/// no retired vocabulary, and no `Summary` payload left anywhere.
final class HistoryExperienceContractTests: XCTestCase {

    // MARK: - Shape

    func testModeLabelsAreTheDecidedNames() {
        XCTAssertEqual(HistoryExperience.Mode.allCases.map(\.label),
                       ["Weekly recap", "Explore quota", "Explore usage", "Hard blocks"])
        XCTAssertEqual(HistoryExperience.Mode.allCases.first, .weeklyRecap,
                       "Weekly recap is the ordinary-open default (REV-93 §2.1)")
    }

    func testStableWindowTitleAndModeLocalHierarchyAreModelOwned() {
        let experience = HXFix.experience([HXFix.tool(.claude), HXFix.tool(.codex)])
        XCTAssertEqual(experience.header.title, "History")
        XCTAssertEqual(experience.header.evidenceEyebrow,
                       "Last 30 days · \(experience.header.subtitle)")
        XCTAssertEqual(HistoryExperience.Mode.allCases.map(\.windowSubtitle), [
            "Weekly recaps and the evidence behind them",
            "Explore provider-reported quota history",
            "Explore recorded local activity",
            "Investigate recorded interruptions",
        ])
        XCTAssertEqual(HistoryExperience.Mode.allCases.map(\.evidenceSubtitle), [
            nil,
            "How each provider-reported quota window ended. Current windows are shown separately as “So far.”",
            "Recorded local activity by day, week, project and model.",
            "Recorded interruptions and the evidence around them.",
        ])
    }

    /// The legacy mode is gone by name and by payload — a `Summary` string must not survive on
    /// any rendered surface either.
    func testNoSummaryModeOrPayloadRemains() {
        let experience = HXFix.experience([HXFix.tool(.claude), HXFix.tool(.codex)])
        XCTAssertFalse(HistoryExperience.Mode.allCases.map(\.label).contains("Summary"))
        var strings = HXFix.allStrings(of: experience.recap)
        for provider in experience.providers {
            strings += HXFix.allStrings(of: experience.pages(provider))
        }
        for string in strings {
            XCTAssertFalse(string.contains("Summary"), "retired mode name in: \(string)")
        }
    }

    /// Weekly recap is cross-provider by contract: it hangs off the root, not off a provider
    /// page, so a provider filter has nothing to select on it (§6.2).
    func testRecapIsCrossProviderAndLivesAtTheRoot() {
        let experience = HXFix.experience([HXFix.tool(.claude), HXFix.tool(.codex)])
        XCTAssertFalse(experience.recap.weeks.isEmpty)
        let mirrored = Mirror(reflecting: experience.pages(.all)).children.compactMap(\.label)
        XCTAssertEqual(mirrored, ["provider", "quota", "explore", "hardBlocks"],
                       "no per-provider recap payload exists")
    }

    func testProvidersAreAllThenOnePerToolInReportOrder() {
        let experience = HXFix.experience([HXFix.tool(.claude), HXFix.tool(.codex)])
        XCTAssertEqual(experience.providers,
                       [.all, .tool(.claude), .tool(.codex)])
        XCTAssertEqual(experience.providers.map(\.label), ["All", "Claude", "Codex"])
        // Every position has all three payloads — nine combinations, precomputed.
        for provider in experience.providers {
            let pages = experience.pages(provider)
            XCTAssertEqual(pages.provider, provider)
            XCTAssertNil(pages.explore.emptyMessage)
        }
    }

    func testMissingProviderFallsBackToAll() {
        let experience = HXFix.experience([HXFix.tool(.claude)])
        XCTAssertEqual(experience.pages(.tool(.codex)).provider, .all,
                       "the same fallback rule HistoryScreen.tab(_:) has")
    }

    // MARK: - Footer and pricing copy

    func testFooterNamesTheRecordsTheHorizonsAndThePrices() {
        let experience = HXFix.experience([HXFix.tool(.claude)])
        XCTAssertEqual(experience.footer,
                       "Local Claude Code and Codex records on this Mac · "
                       + "evidence horizons vary · prices v1.4 (2026-08-11)")
        XCTAssertEqual(experience.pricingNote,
                       "Priced at published API rates for each model. Not a bill.")
    }

    func testFooterWithoutAPricingStampOmitsTheSegment() {
        let experience = HXFix.experience([HXFix.tool(.claude)], pricing: nil)
        XCTAssertEqual(experience.footer,
                       "Local Claude Code and Codex records on this Mac · "
                       + "evidence horizons vary")
    }

    // MARK: - Empty report

    func testEmptyReportKeepsControlsAndSaysSoOnce() {
        let experience = HXFix.experience([HXFix.blank(.claude), HXFix.blank(.codex)])
        XCTAssertEqual(experience.emptyMessage,
                       "No local Claude Code or Codex activity in the last 30 days yet.")
        XCTAssertEqual(experience.providers.count, 3, "the controls stay visible (REV-84 §8)")
        let all = experience.pages(.all)
        XCTAssertEqual(all.explore.emptyMessage, experience.emptyMessage)
        XCTAssertEqual(all.hardBlocks.emptyMessage, experience.emptyMessage)
        XCTAssertEqual(experience.pages(.tool(.codex)).explore.emptyMessage,
                       "No local Codex activity in the last 30 days.")
        XCTAssertEqual(all.quota.emptyMessage, HistoryDisplay.quotaFreshInstallMessage,
                       "no provider window was ever observed — poll evidence cannot be recovered")
    }

    func testAWatchedButIdleToolIsNotBlank() {
        let watched = HXFix.blank(.codex, watchingSince: HXFix.now.addingTimeInterval(-8 * 86_400))
        let pages = HXFix.pages([HXFix.tool(.claude), watched], .tool(.codex))
        XCTAssertEqual(pages.explore.emptyMessage,
                       "No local Codex activity in the last 30 days.",
                       "Explore usage is about local activity and says so honestly")
        XCTAssertNil(pages.hardBlocks.emptyMessage)
    }

    // MARK: - Structural bans

    /// A rich fixture: both providers, models, weeks, days, blocks, observations, changes and
    /// an earned quota-change row — then walk every string of all nine payloads.
    private func richTools() -> [HistoryReport.ToolReport] {
        let claudeDays = HXFix.withDay(
            HXFix.days([0, 500_000, 1_000_000]), at: 2,
            modelTotals: [HXFix.totals(input: 1_000_000)],
            modelValues: [HXFix.mv("claude-sonnet-4-6", 8.4)], value: 8.4)
        let claude = HXFix.tool(
            .claude, totalTokens: 1_500_000,
            projects: [HistoryReport.Project(name: "/u/kvotar", sessions: 4, tokens: 900_000)],
            topSessions: [HistoryReport.Session(sessionId: "s1", project: "/u/kvotar",
                                                model: "claude-sonnet-4-6",
                                                lastSeenAt: HXFix.now, tokens: 400_000,
                                                value: 3.2)],
            weeks: [HXFix.week(daysBack: 0, tokens: 900_000, value: 7.5),
                    HXFix.week(daysBack: 7, tokens: 600_000, value: 5.0),
                    HXFix.week(daysBack: 28, tokens: 0, partial: true)],
            accountChanges: [HXFix.change(at: HXFix.dayStart(index: 1, of: 3)
                                            .addingTimeInterval(3600),
                                          old: "go", new: "plus")],
            limitBlocks: [HXFix.block(at: HXFix.dayStart(index: 1, of: 3)
                                        .addingTimeInterval(2 * 3600)),
                          HXFix.block(at: HXFix.dayStart(index: 2, of: 3)
                                        .addingTimeInterval(3 * 3600), lockout: nil)],
            watchingSince: HXFix.now.addingTimeInterval(-20 * 86_400),
            workPerPercent: HXFix.qualifyingSeries(),
            days: claudeDays,
            workByHour: [Int](repeating: 0, count: 20) + [7_000, 0, 0, 0],
            criticalObservations: [HXFix.observation(
                at: HXFix.dayStart(index: 2, of: 3).addingTimeInterval(3600),
                .atRisk, util: 92)])
        let codex = HXFix.tool(
            .codex, sessions: 2, totalTokens: 400_000,
            modelTotals: [HXFix.totals(model: nil, input: 400_000)],
            modelValues: [HXFix.mv(nil, 1.1)], value: 1.1,
            weeks: [HXFix.week(daysBack: 0, tokens: 300_000, value: 0.8),
                    HXFix.week(daysBack: 7, tokens: 100_000, value: 0.3)],
            days: HXFix.days([0, 100_000, 300_000]))
        return [claude, codex]
    }

    func testNoRenderedStringUsesRetiredVocabulary() {
        let experience = HXFix.experience(richTools())
        var strings = HXFix.allStrings(of: experience)
        for provider in experience.providers {
            strings += HXFix.allStrings(of: experience.pages(provider))
        }
        XCTAssertGreaterThan(strings.count, 50, "the walker actually reached the payloads")
        for string in strings {
            XCTAssertFalse(string.contains("Est. API value"), "retired term in: \(string)")
            XCTAssertFalse(string.contains("Explore days"), "retired term in: \(string)")
            XCTAssertFalse(string.contains("Cost"), "banned term in: \(string)")
            XCTAssertFalse(string.contains("No typical block time yet"),
                           "retired caveat in: \(string)")
        }
    }

    func testNoCombinedTokenFigureAppearsAnywhereOnAll() {
        // 1.5M + 400k = 1.9M — a sum whose rendering appears nowhere unless something added
        // what does not add.
        let combined = Fmt.tokens(1_500_000 + 400_000)
        let pages = HXFix.pages(richTools(), .all)
        for string in HXFix.allStrings(of: pages) {
            XCTAssertFalse(string.contains(combined),
                           "a cross-provider token sum leaked into: \(string)")
        }
        // …while each provider's own total is present.
        XCTAssertEqual(pages.explore.totals.map(\.tokens),
                       [Fmt.tokens(1_500_000), Fmt.tokens(400_000)])
    }

    func testEvidenceSentenceAppearsOncePerDayDetail() {
        let pages = HXFix.pages(richTools(), .all)
        for entry in pages.explore.days {
            let strings = HXFix.allStrings(of: entry.detail)
            XCTAssertEqual(
                strings.filter { $0.contains("no warning here does not guarantee headroom") }
                    .count,
                1, "the honesty sentence is once per detail — no more, no less")
        }
    }
}
