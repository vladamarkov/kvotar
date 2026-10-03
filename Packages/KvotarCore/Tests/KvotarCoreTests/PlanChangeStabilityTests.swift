import XCTest
@testable import KvotarCore

/// The plan-name stability rule (REV-73 §4.2 / D-81 — STEP_121). Every fixture here is the shape
/// the dogfood corpus actually holds: 248 stored Codex `plan_changed` rows, 245 of them one
/// `enterprise ↔ business` argument between two provider sources, and exactly three real changes.
final class PlanChangeStabilityTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let minute: TimeInterval = 60

    /// The corpus, to scale: 122 `enterprise ↔ business` episodes over thirteen days — the name
    /// flips out for about a minute and comes back, every couple of hours — then the three real
    /// transitions. `at` runs oldest first, as the store returns them.
    private var corpus: [PlanTransition] {
        var rows: [PlanTransition] = []
        let start = now.addingTimeInterval(-29 * 86_400)
        for episode in 0..<122 {
            let at = start.addingTimeInterval(Double(episode) * 2.5 * 3600)
            rows.append(PlanTransition(at: at, from: "enterprise", to: "business"))
            rows.append(PlanTransition(at: at.addingTimeInterval(70),
                                       from: "business", to: "enterprise"))
        }
        rows.append(PlanTransition(at: now.addingTimeInterval(-16 * 86_400),
                                   from: "business", to: "free"))
        rows.append(PlanTransition(at: now.addingTimeInterval(-15 * 86_400), from: "free", to: "go"))
        rows.append(PlanTransition(at: now.addingTimeInterval(-4 * 86_400), from: "go", to: "plus"))
        return rows.sorted { $0.at < $1.at }
    }

    // MARK: - The write gate

    func testAFirstDisagreementIsRecorded() {
        XCTAssertFalse(PlanChangeStability.isDamped(from: "enterprise", to: "business", at: now,
                                                    history: []))
    }

    func testTheReturnTripIsNotASecondChange() {
        let history = [PlanTransition(at: now.addingTimeInterval(-minute),
                                      from: "enterprise", to: "business")]
        XCTAssertTrue(PlanChangeStability.isDamped(from: "business", to: "enterprise", at: now,
                                                   history: history))
    }

    func testAGenuineChangeOnAFreshPairIsNeverDamped() {
        let history = [PlanTransition(at: now.addingTimeInterval(-minute),
                                      from: "enterprise", to: "business")]
        XCTAssertFalse(PlanChangeStability.isDamped(from: "business", to: "free", at: now,
                                                    history: history))
    }

    func testAPairQuietForLongerThanTheWindowReArms() {
        let history = [PlanTransition(at: now.addingTimeInterval(-PlanChangeStability.dampingWindow - 1),
                                      from: "enterprise", to: "business")]
        XCTAssertFalse(PlanChangeStability.isDamped(from: "business", to: "enterprise", at: now,
                                                    history: history))
    }

    func testAMissingHalfNeverPairs() {
        let history = [PlanTransition(at: now.addingTimeInterval(-minute), from: nil, to: "business")]
        XCTAssertFalse(PlanChangeStability.isDamped(from: nil, to: "business", at: now,
                                                    history: history))
    }

    /// Replay the whole corpus through the gate the way `PollCoordinator` does — write when not
    /// damped, and judge the next observation against what was **written**. 248 rows become a
    /// handful, and every real change survives, which is the whole claim of D-81's precondition.
    func testReplayingTheCorpusThroughTheGateStoresAHandfulAndKeepsEveryRealChange() {
        var stored: [PlanTransition] = []
        for row in corpus where !PlanChangeStability.isDamped(from: row.from, to: row.to,
                                                              at: row.at, history: stored) {
            stored.append(row)
        }
        let real = stored.filter { ["free", "go", "plus"].contains($0.to ?? "") }
        XCTAssertEqual(real.map { "\($0.from ?? "")→\($0.to ?? "")" },
                       ["business→free", "free→go", "go→plus"])
        XCTAssertEqual(stored.count, 5, "244 arguments become two rows — one a week — plus the three")
        XCTAssertGreaterThan(stored.count, real.count,
                             "the first flip of an episode is still an observation")
    }

    // MARK: - The read collapse

    func testTheCorpusCollapsesToItsThreeRealChanges() {
        XCTAssertEqual(PlanChangeStability.settled(corpus).map { "\($0.from ?? "")→\($0.to ?? "")" },
                       ["business→free", "free→go", "go→plus"])
    }

    /// A user who upgrades and comes back down is two transitions of one pair, and that is a real
    /// story about their account — the collapse must not eat it.
    func testAGenuineUpThenDownSurvives() {
        let rows = [PlanTransition(at: now.addingTimeInterval(-20 * 86_400), from: "pro", to: "max"),
                    PlanTransition(at: now.addingTimeInterval(-3 * 86_400), from: "max", to: "pro")]
        XCTAssertEqual(PlanChangeStability.settled(rows), rows)
    }

    func testThreeTransitionsOfOnePairAreDroppedTogether() {
        let rows = (0..<3).map {
            PlanTransition(at: now.addingTimeInterval(Double(-20 + $0) * 86_400),
                           from: $0.isMultiple(of: 2) ? "a" : "b",
                           to: $0.isMultiple(of: 2) ? "b" : "a")
        }
        XCTAssertEqual(PlanChangeStability.settled(rows), [],
                       "including the first and the last — the whole episode is one indistinct state")
    }

    func testRowsWithAMissingHalfAreKept() {
        let rows = [PlanTransition(at: now, from: nil, to: "plus")]
        XCTAssertEqual(PlanChangeStability.settled(rows), rows)
    }

    func testOrderIsPreserved() {
        let rows = [PlanTransition(at: now.addingTimeInterval(-86_400), from: "free", to: "go"),
                    PlanTransition(at: now, from: "go", to: "plus")]
        XCTAssertEqual(PlanChangeStability.settled(rows).map(\.at), rows.map(\.at))
    }
}
