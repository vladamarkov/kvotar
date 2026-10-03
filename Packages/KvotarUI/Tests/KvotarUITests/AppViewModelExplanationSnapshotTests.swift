import XCTest
import KvotarCore
@testable import KvotarUI

/// `explanation-snapshot.json`'s producer (REV-75/D-93 — STEP_133): what the popover was
/// explaining, walked off the rendered state.
///
/// Two things are pinned here. **The drop reason survives** — a live line that fell back leaves no
/// trace on screen by rule 4, and this file is the only place that says why. **Only tagged
/// elements are walked** — which is not a comment but the privacy rule itself, so the encoded JSON
/// is searched for the fixture's email, its project name and its model name, all of which sit on
/// untagged rows and must therefore be absent.
@MainActor
final class AppViewModelExplanationSnapshotTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Values that must never reach the file — each one is rendered on an *untagged* row.
    private let email = "tester@example.com"
    private let project = "top-secret-acquisition"
    /// No `claude-` prefix on purpose: `modelDisplayName` strips that prefix, so a prefixed string
    /// would be absent from the file for the wrong reason and the assertion below would prove
    /// nothing. This one renders into the per-model row verbatim.
    private let model = "internal-model-x9"

    private func snapshot(used: Double? = 40, weekly: Double? = 14) -> QuotaSnapshot {
        QuotaSnapshot(tool: .claude, primaryUsedPct: used,
                      primaryResetsAt: now.addingTimeInterval(2 * 3600),
                      primaryWindowSeconds: 18_000,
                      secondaryUsedPct: weekly,
                      secondaryResetsAt: now.addingTimeInterval(4 * 24 * 3600),
                      rateLimitReached: false, extraUsage: .disabled,
                      email: email, planType: "Pro")
    }

    private func forecast(burn: Double? = 0.4) -> Forecast {
        Forecast(tool: .claude, tier: .fullRunway, runwayMinutes: burn.map { (100 - 40) / $0 },
                 burnRatePerMin: burn, isEstimate: false, pollCount: 5)
    }

    private func attribution() -> LocalAttribution {
        LocalAttribution(
            project: project, model: model, surfaceBucket: nil, subagentCount: 1,
            cacheHitRatio: 0.5,
            estValue: EstimatedValueEngine.WindowValue(weekly: 12.5, thirtyDay: 44),
            surfaceShares: [], tokensPerMinute: 3300, lastActivityAt: now,
            sessionCount: 2,
            modelTotals: [SQLiteStore.ModelTokenTotals(
                model: model, inputTokens: 1000, outputTokens: 2000,
                cacheCreationTokens: 300, cacheReadTokens: 900)],
            windowValue: 12.5)
    }

    private func rendered(withDailyReport: Bool = false) -> AppViewModel {
        let vm = AppViewModel()
        if withDailyReport {
            vm.applyDailyReport(tool: .claude, .available(dailyReport()), now: now)
        }
        vm.apply(tool: .claude, snapshot: snapshot(), forecast: forecast(), state: .healthy,
                 localAttribution: attribution(), now: now)
        return vm
    }

    /// A day whose one project and one model are the strings the privacy assertion hunts for.
    private func dailyReport() -> DailyLocalReport {
        DailyLocalReport(
            tool: .claude, dayStart: now.addingTimeInterval(-8 * 3600), readUntil: now,
            totalTokens: 1_200, sessionCount: 1, cacheHitRatio: 0.5,
            projects: [DailyLocalReport.Project(
                name: "/Users/u/\(project)", tokens: 1_200,
                models: [.init(model: model, tokens: 1_200, value: 0.2)],
                latestEventAt: now.addingTimeInterval(-600), value: 0.2)],
            lastEventAt: now.addingTimeInterval(-600), value: 0.2)
    }

    // MARK: Shape

    func testNoRenderedTabProducesNoSnapshot() {
        XCTAssertNil(AppViewModel().explanationSnapshot(now: now),
                     "the loading card explains nothing — the bundle says so in a note instead")
    }

    func testEveryTaggedElementOnTheRenderedTabIsRecorded() throws {
        let vm = rendered()
        let snapshot = try XCTUnwrap(vm.explanationSnapshot(now: now))
        let claude = try XCTUnwrap(snapshot.tools.first { $0.tool == "claude" })

        XCTAssertFalse(claude.stale)
        XCTAssertEqual(snapshot.activeTab, vm.activeTab.rawValue)
        XCTAssertEqual(snapshot.peekDelayMs, 600)
        XCTAssertEqual(snapshot.graceLeaveMs, 120)

        // The four elements this fixture is built to render, each identified by (site, element).
        let ids = Set(claude.entries.map { "\($0.element)@\($0.site)" })
        XCTAssertTrue(ids.contains("E-04@header hero"), "the hero explains itself")
        XCTAssertTrue(claude.entries.contains { $0.element == "E-01" }, "the 5-hour row")
        XCTAssertTrue(claude.entries.contains { $0.element == "E-02" }, "the weekly row")
        XCTAssertTrue(claude.entries.contains { $0.element == "E-08" }, "the verdict's detail line")

        // Every recorded entry could have been opened: it has a card, or a line, or a drop to
        // explain the absence of one. A target with none of the three is inert and unrecorded.
        for entry in claude.entries {
            XCTAssertTrue(entry.cardText != nil || entry.liveLine != nil
                          || entry.liveDropReason != nil,
                          "\(entry.element)@\(entry.site) is inert and should not be recorded")
        }

        // E-08's card is one per verdict family (D-90), so it arrives whole in the live slot.
        let detail = try XCTUnwrap(claude.entries.first { $0.element == "E-08" })
        XCTAssertNil(detail.cardText)
        XCTAssertNotNil(detail.liveLine)

        // The row entries carry the label the pointer would have rested on, beside their section.
        // E-01 is the header caption under a primary hero since the STEP_178 cutover.
        let primary = try XCTUnwrap(claude.entries.first { $0.element == "E-01" })
        XCTAssertEqual(primary.site, "caption")
        XCTAssertEqual(primary.value, "5-hour quota left")
    }

    func testTheVerdictAnatomyTravelsOnAComputedFamily() throws {
        let vm = rendered()
        XCTAssertNotNil(vm.claudeState.header?.verdict?.anatomy, "fixture must render an anatomy")
        let claude = try XCTUnwrap(
            vm.explanationSnapshot(now: now)?.tools.first { $0.tool == "claude" })
        let anatomy = try XCTUnwrap(claude.anatomy)
        XCTAssertEqual(anatomy.family, vm.claudeState.header?.verdict?.family.rawValue)
        XCTAssertFalse(anatomy.rows.isEmpty)
        XCTAssertTrue(anatomy.rows.allSatisfy { $0.count == 2 }, "[label, value] per row")
        XCTAssertFalse(anatomy.comparison.isEmpty)
    }

    /// The point of the file: a line the formatter dropped says so, rather than being a gap.
    func testADroppedLiveLineRecordsItsReason() throws {
        let vm = AppViewModel()
        // No burn measured yet — E-04's runway line and the runway verdict cards have nothing to
        // compute from, which is exactly the STEP_130 drop path.
        vm.apply(tool: .claude, snapshot: snapshot(), forecast: forecast(burn: nil),
                 state: .healthy, localAttribution: attribution(), now: now)
        let claude = try XCTUnwrap(
            vm.explanationSnapshot(now: now)?.tools.first { $0.tool == "claude" })

        let dropped = claude.entries.filter { $0.liveDropReason != nil }
        XCTAssertFalse(dropped.isEmpty, "an unmeasured burn must leave a written reason")
        XCTAssertTrue(dropped.allSatisfy { $0.liveLine == nil },
                      "a dropped line is not also a shown one")
        XCTAssertTrue(dropped.allSatisfy { LiveDropReason(rawValue: $0.liveDropReason!) != nil },
                      "the reason is the enum's own raw value, not free text")
    }

    /// `inputs` is what the entries were computed *from*, so a wrong line can be told apart from a
    /// wrong input. Absent values are omitted rather than dashed.
    func testInputsCarryTheRenderTheEntriesWereBuiltFrom() throws {
        let claude = try XCTUnwrap(
            rendered().explanationSnapshot(now: now)?.tools.first { $0.tool == "claude" })
        XCTAssertEqual(claude.inputs["usedPct"], "40%")
        XCTAssertEqual(claude.inputs["weeklyPct"], "14%")
        XCTAssertEqual(claude.inputs["windowSeconds"], "18000")
        XCTAssertEqual(claude.inputs["burnPctPerMin"], "0.4000")
        XCTAssertEqual(claude.inputs["tokensPerMinute"], "3300")
        XCTAssertNotNil(claude.inputs["primaryResetsAt"])
        XCTAssertNil(claude.inputs["monthlyLimit"], "no monthly meter on this fixture")
    }

    // MARK: The privacy rule — an assertion, not a comment

    /// Only tagged elements are walked. The account email, the project name and the model name are
    /// all rendered on untagged rows, so none of them can reach the file. This is the whole of
    /// D-93's privacy argument, and it is checked against the *encoded* bytes rather than the
    /// model, because that is what leaves the machine.
    func testTheEncodedFileCarriesNoEmailProjectOrPerModelRow() throws {
        let vm = rendered(withDailyReport: true)
        // The fixture must actually be rendering them, or the assertion below proves nothing.
        XCTAssertEqual(vm.claudeState.header?.email, email)
        let local = try XCTUnwrap(vm.claudeState.localActivity)
        XCTAssertTrue(local.projects.contains { ($0.fullName ?? "").contains(project) },
                      "fixture must render the project row")
        XCTAssertTrue(local.projects.flatMap(\.models).contains { $0.name.contains(model) },
                      "fixture must render a per-model row")
        // The local section is a tagged element since STEP_178, so the walk records it — but only
        // its **fixed** rows. The project names, their paths and their model rows never enter the
        // file, and the recency marker reports a constant site for the same reason.

        let snapshot = try XCTUnwrap(vm.explanationSnapshot(now: now))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(snapshot), as: UTF8.self)

        XCTAssertFalse(json.contains(email))
        XCTAssertFalse(json.contains(project))
        XCTAssertFalse(json.contains(model))
    }

    /// The file does not cross the `DiagnosticsPayloadSanitizer` boundary — that seam is for raw
    /// provider bodies. Its key names avoid the sanitizer's fragments anyway, so a later decision
    /// to route it through would not silently redact half of it.
    func testKeyNamesAvoidTheSanitizerFragments() throws {
        let snapshot = try XCTUnwrap(rendered().explanationSnapshot(now: now))
        let object = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(snapshot)) as? [String: Any]
        // The sanitizer's own list, not a copy of it — a hand-written one drifts from the list
        // that does the redacting.
        let forbidden = DiagnosticsPayloadSanitizer.forbiddenKeyFragments
        for key in Self.keys(in: object as Any) {
            let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
            for fragment in forbidden {
                XCTAssertFalse(normalized.contains(fragment),
                               "key '\(key)' collides with the sanitizer fragment '\(fragment)'")
            }
        }
    }

    /// Every key in the encoded tree, `inputs`' own keys included.
    private static func keys(in value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            return dictionary.keys + dictionary.values.flatMap { keys(in: $0) }
        }
        if let array = value as? [Any] { return array.flatMap { keys(in: $0) } }
        return []
    }
}
