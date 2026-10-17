import XCTest
import KvotarCore
@testable import KvotarUI

final class ClaudeAppDisplayTests: XCTestCase {
    func testActionsMatchStateAndGate() {
        let states: [ClaudeAppConnection.State] = [.unavailable, .ready, .permissionRequired, .expired,
            .ambiguous, .accountChanged, .noEntry, .unreadable, .connected, .codeIdentityDiffers]
        for state in states {
            for gate in [true, false] {
                let connection = ClaudeAppConnection(state: state, gate: gate, appPresent: true, codeAbsent: true, usingApp: true)
                let card = DisplayFormatter.claudeAppCard(connection)
                XCTAssertEqual(card?.action != nil, connection.offersConnection)
                if let card {
                    let copy = [card.title, card.detail, card.permissionNote ?? ""].joined(separator: " ")
                    for word in UserCopyRules.pollingWords { XCTAssertFalse(copy.lowercased().contains(word.lowercased()), word) }
                }
                if state == .permissionRequired, gate { XCTAssertEqual(card?.action, "Retry") }
                if state == .accountChanged {
                    XCTAssertNil(card?.permissionNote)
                    XCTAssertFalse(card?.detail.contains("permission") ?? true)
                }
            }
        }
    }
    func testCLIUsersHaveNoAppSetupCardAndSourcesAreNamedOnlyWhenKnown() {
        let cli = ClaudeAppConnection(state: .unavailable, appPresent: true)
        XCTAssertNil(DisplayFormatter.claudeAppCard(cli))
        for (source, name) in [(QuotaSource.oauth, "Source: Claude Code"), (.claudeApp, "Source: Claude app")] {
            let snapshot = QuotaSnapshot(tool: .claude, primaryUsedPct: 12,
                primaryResetsAt: Date().addingTimeInterval(3600), secondaryUsedPct: nil,
                secondaryResetsAt: nil, rateLimitReached: false, source: source)
            let display = DisplayFormatter.claude(state: .healthy, snapshot: snapshot, forecast: nil)
            XCTAssertTrue(display.header?.sourceTag?.base.hasPrefix(name) == true)
        }
    }

    @MainActor
    func testRecheckAndConnectionActionsAreSeparateAndGateIsEnforced() {
        let vm = AppViewModel()
        var connections = 0, checks = 0
        vm.onConnectClaudeApp = { connections += 1 }
        vm.onRecheck = { _ in checks += 1 }
        vm.connectClaudeApp()
        XCTAssertEqual(connections, 0)
        vm.claudeAppConnection = .init(state: .ready, gate: true, appPresent: true, codeAbsent: true)
        vm.recheck(.claude)
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(connections, 0)
        vm.connectClaudeApp()
        XCTAssertEqual(connections, 1)
        vm.connectingClaudeApp = true
        vm.connectClaudeApp()
        XCTAssertEqual(connections, 1)
    }

    @MainActor
    func testSuccessfulConnectionLeavesSetupAndClearsPriorDelta() {
        let vm = AppViewModel()
        vm.openSetup(.claude)
        vm.deltaLines[.claude] = "old account"
        vm.resetClaudeAccountDisplay()
        XCTAssertNil(vm.transientSetupTool)
        XCTAssertNil(vm.deltaLines[.claude])
        XCTAssertEqual(vm.activeTab, .claude)
    }

    @MainActor
    func testStoppedSourceImmediatelyMarksRetainedQuotaHistorical() {
        let vm = AppViewModel()
        let now = Date()
        let snapshot = QuotaSnapshot(tool: .claude, primaryUsedPct: 12,
            primaryResetsAt: now.addingTimeInterval(3600), secondaryUsedPct: nil,
            secondaryResetsAt: nil, rateLimitReached: false, source: .claudeApp)
        let forecast = Forecast(tool: .claude, tier: .unknown, runwayMinutes: nil,
            burnRatePerMin: nil, isEstimate: false, pollCount: 0)
        vm.apply(tool: .claude, snapshot: snapshot, forecast: forecast, state: .healthy, now: now)
        vm.applyClaudeAppConnection(.init(state: .accountChanged, gate: true,
            appPresent: true, codeAbsent: true, usingApp: true))
        let source = vm.claudeState.header?.sourceTag?.base ?? ""
        XCTAssertTrue(source.contains("historical reading"))
        XCTAssertTrue(source.contains("as of"))
        XCTAssertEqual(vm.claudeState.dot, .grey)
    }

    func testAppExpiryExplanationNamesItsOwner() {
        let card = ExplanationRegistry.sourceTagCard(tool: .claude,
            tag: SourceTag(base: "Source: Claude app · exact"), freeze: .claudeAppExpired)
        XCTAssertTrue(card?.contains("waiting for the Claude app to renew it") == true)
        XCTAssertFalse(card?.contains("open Claude Code") == true)
    }

    func testHistoricalSourceAndChangedAccountFact() {
        let connection = ClaudeAppConnection(state: .accountChanged, gate: true, appPresent: true, codeAbsent: true, usingApp: true)
        XCTAssertEqual(DisplayFormatter.claudeAppSource(connection), "Source: Claude app · historical reading")
        let change = HistoryReport.AccountChange(at: Date(), kind: .accountRebound)
        XCTAssertEqual(DeltaLine.windowFactTokens([change]), ["Claude account changed"])
        let parts = HistoryDisplay.changeParts(.single(change))
        XCTAssertEqual(parts.lead, "Claude account changed")
    }
}
