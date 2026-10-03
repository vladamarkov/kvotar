import XCTest
@testable import KvotarCore

/// D-99 — the helper-vs-surface split moved out of `DisplayFormatter` so the state and
/// notification engines read the same definition the copy layer names from.
final class SurfaceWorkSplitTests: XCTestCase {

    private func share(_ label: String, _ fraction: Double,
                       lastEventAt: Date? = nil) -> SurfaceShare {
        SurfaceShare(label: label, fraction: fraction, lastEventAt: lastEventAt)
    }

    /// The live shape that produced the defect: one ChatGPT desktop app and two helper threads it
    /// spawned itself, all three `originator: Codex Desktop` (dogfood DB, 2026-08-24 14:57 CEST).
    /// One surface — §13 rule 8's `>= 2` must not fire.
    func testOneDesktopAppWithTwoSubagentsIsOneSurface() {
        let split = SurfaceWorkSplit([
            share("Subagent · Bacon", 0.49),
            share("Desktop", 0.29),
            share("Subagent · McClintock", 0.22),
        ])
        XCTAssertEqual(split.surfaces.map(\.label), ["Desktop"])
        XCTAssertEqual(split.helpers.count, 2)
    }

    /// The state the rule exists for still fires: two genuinely different surfaces.
    func testTwoRealSurfacesStillCountAsTwo() {
        let split = SurfaceWorkSplit([share("Desktop", 0.6), share("CLI", 0.4)])
        XCTAssertEqual(split.surfaces.count, 2)
        XCTAssertTrue(split.helpers.isEmpty)
    }

    /// `Unknown` is a real bucket, not a helper — it is a surface we could not name, and it has
    /// been live (P2-4, 2026-07-16). It must keep counting.
    func testUnknownIsASurfaceNotAHelper() {
        let split = SurfaceWorkSplit([share("Desktop", 0.7), share("Unknown", 0.3)])
        XCTAssertEqual(split.surfaces.count, 2)
    }

    /// Share order is the engine's tokens-descending order on both sides — the multi-surface
    /// recommendation reads `surfaces[0]` as "the primary driver".
    func testShareOrderSurvivesTheSplit() {
        let split = SurfaceWorkSplit([
            share("Desktop", 0.5),
            share("Subagent · Ohm", 0.3),
            share("CLI", 0.15),
            share("Subagent · Meitner", 0.05),
        ])
        XCTAssertEqual(split.surfaces.map(\.label), ["Desktop", "CLI"])
        XCTAssertEqual(split.helpers.map(\.label), ["Subagent · Ohm", "Subagent · Meitner"])
    }

    /// `mainFraction` is the remainder, so the two rows always describe one denominator (D-96).
    func testMainFractionIsTheRemainder() {
        let split = SurfaceWorkSplit([
            share("Desktop", 0.6),
            share("Subagent · Bacon", 0.25),
            share("Subagent · McClintock", 0.15),
        ])
        XCTAssertEqual(split.helperFraction, 0.4, accuracy: 0.0001)
        XCTAssertEqual(split.mainFraction, 0.6, accuracy: 0.0001)
    }

    func testEmptyShares() {
        let split = SurfaceWorkSplit([])
        XCTAssertTrue(split.surfaces.isEmpty)
        XCTAssertTrue(split.helpers.isEmpty)
        XCTAssertEqual(split.mainFraction, 1)
    }

    /// The prefix is the parsers' own, and it carries a U+00B7 middle dot — a plain hyphen or an
    /// ASCII dot would silently classify every helper as a surface again.
    func testPrefixMatchesTheParserVocabulary() {
        XCTAssertEqual(SurfaceWorkSplit.subagentPrefix, "Subagent \u{00B7} ")
        XCTAssertEqual(SurfaceWorkSplit([share("Subagent - Bacon", 1)]).surfaces.count, 1)
    }

    // MARK: STEP_192 — active means burning now (§13 rule 8, closes A28)

    private let now = Date(timeIntervalSince1970: 1_757_800_000)

    /// The 2026-09-13 22:18 CEST card: Desktop idle since 16:24 but holding the larger weekly
    /// share, the CLI the only surface writing. The whole-window split still lists both; the
    /// active list has one — so rank 8 does not fire and nothing is named.
    func testSurfaceIdleForHoursIsNotActive() {
        let split = SurfaceWorkSplit([
            share("Desktop", 0.57, lastEventAt: now.addingTimeInterval(-6 * 3600)),
            share("CLI", 0.43, lastEventAt: now.addingTimeInterval(-60)),
        ])
        XCTAssertEqual(split.surfaces.map(\.label), ["Desktop", "CLI"], "window split unchanged")
        XCTAssertEqual(split.activeSurfaces(now: now).map(\.label), ["CLI"])
    }

    /// The gap is `LocalAttribution.idleGap` (8 min): 7 min ago is active, 9 min ago is not, and
    /// a share with no measured event never is.
    func testActiveGapIsTheIdleGap() {
        let split = SurfaceWorkSplit([
            share("Desktop", 0.5, lastEventAt: now.addingTimeInterval(-7 * 60)),
            share("CLI", 0.3, lastEventAt: now.addingTimeInterval(-9 * 60)),
            share("IDE extension", 0.2),
        ])
        XCTAssertEqual(split.activeSurfaces(now: now).map(\.label), ["Desktop"])
    }

    /// `Unknown` is never active (owner ruling 2026-09-13): the live upgrade shape — one
    /// `codex-tui` session whose pre-upgrade rows sit in `Unknown` and post-upgrade rows in `CLI`,
    /// both fresh — is one surface, not two. It stays in the whole-window split.
    func testUnknownIsNeverActive() {
        let split = SurfaceWorkSplit([
            share("Unknown", 0.6, lastEventAt: now.addingTimeInterval(-60)),
            share("CLI", 0.4, lastEventAt: now.addingTimeInterval(-30)),
        ])
        XCTAssertEqual(split.surfaces.map(\.label), ["Unknown", "CLI"])
        XCTAssertEqual(split.activeSurfaces(now: now).map(\.label), ["CLI"])
    }

    /// Two surfaces burning together are still two, in share order; a fresh helper thread is
    /// still not a surface.
    func testTwoFreshSurfacesAreActiveInShareOrderWithoutHelpers() {
        let split = SurfaceWorkSplit([
            share("Subagent · Mill", 0.5, lastEventAt: now),
            share("Desktop", 0.3, lastEventAt: now.addingTimeInterval(-30)),
            share("CLI", 0.2, lastEventAt: now.addingTimeInterval(-120)),
        ])
        XCTAssertEqual(split.activeSurfaces(now: now).map(\.label), ["Desktop", "CLI"])
    }
}
