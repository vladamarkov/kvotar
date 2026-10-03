import XCTest
@testable import KvotarCore

/// Money state / glyph model (UI Spec §1.6 / §2.4a, Baseline §7.1, REV-29). Covers the data-driven
/// card state, the forecast-driven glyph, the shared imminence/eta helpers, and the 2-poll glyph
/// hysteresis. The cross-surface invariant (glyph state ⟷ card money state) is asserted in the UI
/// suite against the DisplayFormatter; here we pin the pure Core derivations.
final class MoneyStateTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snap(used: Double?, extra: ExtraUsage?, resetMin: Double? = 120) -> QuotaSnapshot {
        QuotaSnapshot(
            tool: .claude, primaryUsedPct: used,
            primaryResetsAt: resetMin.map { now.addingTimeInterval($0 * 60) },
            secondaryUsedPct: nil, secondaryResetsAt: nil, rateLimitReached: used.map { $0 >= 100 },
            extraUsage: extra)
    }

    private func forecast(burn: Double?, tier: ForecastTier = .fullRunway) -> Forecast {
        Forecast(tool: .claude, tier: tier, runwayMinutes: nil, burnRatePerMin: burn,
                 isEstimate: false, pollCount: 10)
    }

    private let on = ExtraUsage(isEnabled: true, monthlyLimit: 2000, usedCredits: 3.2, currency: "USD")
    private let off = ExtraUsage.disabled
    private var lastObserved: ExtraUsage {
        ExtraUsage(isEnabled: false, monthlyLimit: 2000, usedCredits: 3.2, usedCreditsIsCached: true)
    }

    // MARK: Card money state (§2.4a.1)

    func testMoneyStateArmedChargingNoBackstopBlocked() {
        XCTAssertEqual(MoneyModel.moneyState(snapshot: snap(used: 40, extra: on)), .armed)
        XCTAssertEqual(MoneyModel.moneyState(snapshot: snap(used: 100, extra: on)), .charging)
        XCTAssertEqual(MoneyModel.moneyState(snapshot: snap(used: 40, extra: off)), .noBackstop)
        XCTAssertEqual(MoneyModel.moneyState(snapshot: snap(used: 100, extra: off)), .blocked)
    }

    func testMoneyStateLastObservedAndAbsent() {
        XCTAssertEqual(MoneyModel.moneyState(snapshot: snap(used: 100, extra: lastObserved)), .lastObserved)
        XCTAssertEqual(MoneyModel.moneyState(snapshot: snap(used: 40, extra: nil)), .absent)
        XCTAssertEqual(MoneyModel.moneyState(snapshot: nil), .absent)
    }

    // MARK: Either window + the spent cap (REV-102 §2.2 — STEP_218)

    /// The Team tester's shape: five-hour un-started, weekly as given, org-paid credits in EUR.
    private func teamSnap(weekly: Double, usedCredits: Decimal) -> QuotaSnapshot {
        QuotaSnapshot(
            tool: .claude, primaryUsedPct: 0, primaryResetsAt: nil,
            secondaryUsedPct: weekly, secondaryResetsAt: now.addingTimeInterval(86_400),
            rateLimitReached: false,
            extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: 7000, usedCredits: usedCredits,
                                   currency: "EUR", managedByOrganization: true,
                                   currencyExponent: 2))
    }

    func testSpentWeeklyWithCreditsOnIsCharging() {
        let snapshot = teamSnap(weekly: 100, usedCredits: 16.8)
        XCTAssertEqual(MoneyModel.moneyState(snapshot: snapshot), .charging)
        XCTAssertEqual(MoneyModel.moneyGlyphInstant(snapshot: snapshot, forecast: nil, now: now),
                       .charging, "the glyph reads the same either-window test as the card")
    }

    func testCapReachedIsTestedBeforeCharging() {
        let snapshot = teamSnap(weekly: 100, usedCredits: Decimal(string: "70.25")!)
        XCTAssertEqual(MoneyModel.moneyState(snapshot: snapshot), .capReached)
        XCTAssertEqual(MoneyModel.moneyGlyphInstant(snapshot: snapshot, forecast: nil, now: now),
                       MoneyGlyph.none)
        // Exactly at the cap counts.
        XCTAssertEqual(MoneyModel.moneyState(snapshot: teamSnap(weekly: 100, usedCredits: 70)),
                       .capReached)
    }

    func testCapReachedWithWindowsFineHasNoGlyph() {
        let snapshot = teamSnap(weekly: 10, usedCredits: Decimal(string: "70.25")!)
        XCTAssertEqual(MoneyModel.moneyState(snapshot: snapshot), .capReached)
        XCTAssertEqual(MoneyModel.moneyGlyphInstant(snapshot: snapshot, forecast: forecast(burn: 5),
                                                    now: now), MoneyGlyph.none)
    }

    /// The second shape of a reached cap (REV-102 §6 item 1 — STEP_222): a day later the meter
    /// is switched off, reason `out_of_credits`, no amounts. Still `capReached`, never `Off`.
    func testOrgCreditsSwitchedOffIsCapReached() {
        func snapshot(weekly: Double, reason: String?, org: Bool = true) -> QuotaSnapshot {
            QuotaSnapshot(
                tool: .claude, primaryUsedPct: 0, primaryResetsAt: nil,
                secondaryUsedPct: weekly, secondaryResetsAt: now.addingTimeInterval(86_400),
                rateLimitReached: false,
                extraUsage: ExtraUsage(isEnabled: false, monthlyLimit: nil, usedCredits: nil,
                                       currency: "EUR", disabledReason: reason,
                                       managedByOrganization: org, currencyExponent: 2))
        }
        for weekly in [100.0, 10.0] {
            let spent = snapshot(weekly: weekly, reason: "out_of_credits")
            XCTAssertEqual(MoneyModel.moneyState(snapshot: spent), .capReached)
            XCTAssertEqual(MoneyModel.moneyGlyphInstant(snapshot: spent, forecast: nil, now: now),
                           MoneyGlyph.none)
        }
        // Any other org-managed off state stays Off.
        XCTAssertEqual(MoneyModel.moneyState(snapshot: snapshot(weekly: 100, reason: "org_disabled")),
                       .blocked)
        XCTAssertEqual(MoneyModel.moneyState(snapshot: snapshot(weekly: 10, reason: nil)),
                       .noBackstop)
        // And the reason alone is not enough: a self-serve account keeps today's reading.
        XCTAssertEqual(MoneyModel.moneyState(
            snapshot: snapshot(weekly: 100, reason: "out_of_credits", org: false)), .blocked)
    }

    /// The cap is minor units and the used side major units — the exponent joins them. A
    /// zero-exponent currency (JPY) must not be read as cents.
    func testCapComparisonRidesTheExponent() {
        let yen = ExtraUsage(isEnabled: true, monthlyLimit: 5000, usedCredits: 4000,
                             currency: "JPY", managedByOrganization: true, currencyExponent: 0)
        XCTAssertEqual(MoneyModel.moneyState(snapshot: snap(used: 40, extra: yen)), .armed)
        // Pro/Max: no exponent ⇒ cents. $3.20 of $20.00 stays armed; $20.00 is the cap.
        let atCap = ExtraUsage(isEnabled: true, monthlyLimit: 2000, usedCredits: 20)
        XCTAssertEqual(MoneyModel.moneyState(snapshot: snap(used: 40, extra: atCap)), .capReached)
    }

    // MARK: eta_to_100 + imminence (§1.6 shared with the card)

    func testEtaTo100() throws {
        // used 90, burn 1%/min → 10 min to 100.
        let eta = try XCTUnwrap(MoneyModel.etaTo100Minutes(snapshot: snap(used: 90, extra: on),
                                                           forecast: forecast(burn: 1.0)))
        XCTAssertEqual(eta, 10, accuracy: 0.01)
        // Burn at/below the §1.6 floor → nil (∞).
        XCTAssertNil(MoneyModel.etaTo100Minutes(snapshot: snap(used: 90, extra: on),
                                                forecast: forecast(burn: 0.04)))
        // A tier with no quota denominator → nil (was `.inferredRunway` until REV-80 retired it).
        XCTAssertNil(MoneyModel.etaTo100Minutes(snapshot: snap(used: 90, extra: on),
                                                forecast: forecast(burn: 1.0, tier: .creditBased)))
    }

    func testImminentByForecastAndByNoBurnFallback() {
        // eta 10 min < 120 min to reset → imminent.
        XCTAssertTrue(MoneyModel.isImminent(snapshot: snap(used: 90, extra: on),
                                            forecast: forecast(burn: 1.0), now: now))
        // eta 10 min but reset only 5 min away → not imminent (resets first).
        XCTAssertFalse(MoneyModel.isImminent(snapshot: snap(used: 90, extra: on, resetMin: 5),
                                             forecast: forecast(burn: 1.0), now: now))
        // ≥98% with no usable burn → imminent via the no-burn fallback.
        XCTAssertTrue(MoneyModel.isImminent(snapshot: snap(used: 98.5, extra: on),
                                            forecast: forecast(burn: nil), now: now))
    }

    // MARK: Glyph (§1.6) — is_enabled-gated

    func testGlyphOffAlwaysNone() {
        XCTAssertEqual(MoneyModel.moneyGlyphInstant(snapshot: snap(used: 99, extra: off),
                                                    forecast: forecast(burn: 5), now: now), MoneyGlyph.none)
    }

    func testGlyphChargingArmedCoast() {
        XCTAssertEqual(MoneyModel.moneyGlyphInstant(snapshot: snap(used: 100, extra: on),
                                                    forecast: forecast(burn: 1), now: now), .charging)
        XCTAssertEqual(MoneyModel.moneyGlyphInstant(snapshot: snap(used: 90, extra: on),
                                                    forecast: forecast(burn: 1), now: now), .armed)
        // Low burn, plenty of headroom → not imminent → none.
        XCTAssertEqual(MoneyModel.moneyGlyphInstant(snapshot: snap(used: 40, extra: on),
                                                    forecast: forecast(burn: 0.1), now: now), MoneyGlyph.none)
    }

    // MARK: Glyph hysteresis (§13.4 rule, N = 2)

    func testGlyphEscalatesImmediately() {
        let r = StateEngine.resolveGlyphHysteresis(previous: .none, candidate: .charging,
                                                   demoteStreak: 0, trigger: .poll)
        XCTAssertEqual(r.glyph, .charging)
    }

    func testGlyphDemotesOnlyAfterTwoConfirmingPolls() {
        // Poll 1 calmer → hold red, streak 1.
        var r = StateEngine.resolveGlyphHysteresis(previous: .charging, candidate: .armed,
                                                   demoteStreak: 0, trigger: .poll)
        XCTAssertEqual(r.glyph, .charging)
        XCTAssertEqual(r.streak, 1)
        // Poll 2 calmer → adopt armed.
        r = StateEngine.resolveGlyphHysteresis(previous: .charging, candidate: .armed,
                                               demoteStreak: 1, trigger: .poll)
        XCTAssertEqual(r.glyph, .armed)
        XCTAssertEqual(r.streak, 0)
    }

    func testGlyphJsonlDeltaDoesNotAdvanceDemoteStreak() {
        let r = StateEngine.resolveGlyphHysteresis(previous: .charging, candidate: .none,
                                                   demoteStreak: 1, trigger: .jsonlDelta)
        XCTAssertEqual(r.glyph, .charging, "a JSONL delta must not demote")
        XCTAssertEqual(r.streak, 1, "and must not advance the demote streak")
    }

    func testGlyphJsonlDeltaMayStillEscalate() {
        let r = StateEngine.resolveGlyphHysteresis(previous: .armed, candidate: .charging,
                                                   demoteStreak: 0, trigger: .jsonlDelta)
        XCTAssertEqual(r.glyph, .charging, "a real charge must show at once, even off a JSONL delta")
    }
}
