import XCTest
import KvotarCore

// REV-77 / D-97 (STEP_140) no-change ruling: the anatomy card keeps its used-based lines by
// rule — the `Remaining` row is already remaining, the Pace line (`87% used at 64% of the
// window`) is a pace comparison (used-vs-elapsed by definition), and shape B's `Weekly used
// 91% · Weekly threshold 85%` compares against a used-based threshold. The %-left flip
// touches gauges only; these fixtures deliberately still say `used`.
@testable import KvotarUI

/// STEP_110 — the verdict anatomy (UI Spec Part 3 §5.3, REV-67 / D-73). Every §2.2a row carries a
/// `VerdictFamily`; the computed families carry a `VerdictAnatomy` built by the same branch walk
/// as the line itself, and the Baseline §19 fixtures below assert the two cannot disagree.
final class DisplayFormatterAnatomyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        tool: Tool = .claude, used: Double?, secondary: Double? = nil,
        secondaryResetDays: Double? = nil, resetMinutes: Double? = nil,
        windowSeconds: Int? = nil,
        extraUsage: ExtraUsage = .disabled, plan: String? = "Pro"
    ) -> QuotaSnapshot {
        QuotaSnapshot(tool: tool,
                      primaryUsedPct: used,
                      primaryResetsAt: resetMinutes.map { now.addingTimeInterval($0 * 60) },
                      primaryWindowSeconds: windowSeconds,
                      secondaryUsedPct: secondary,
                      secondaryResetsAt: secondaryResetDays.map { now.addingTimeInterval($0 * 86_400) },
                      rateLimitReached: false,
                      extraUsage: extraUsage,
                      planType: plan)
    }

    private func forecast(tool: Tool = .claude, runway: Double?, burn: Double? = -1,
                          span: Double? = nil) -> Forecast {
        let resolved = burn == -1 ? (runway == nil ? 0 : 1) : burn
        return Forecast(tool: tool, tier: .fullRunway, runwayMinutes: runway,
                        burnRatePerMin: resolved, isEstimate: false, pollCount: 10,
                        burnSpanMinutes: span)
    }

    private func verdict(tool: Tool = .claude, state: AppState, snapshot: QuotaSnapshot?,
                         forecast: Forecast?, nullWindowObsolete: Bool = false,
                         freezeReason: AdapterHealth? = nil,
                         stale: Bool = false) -> HeaderVerdict? {
        DisplayFormatter.headerVerdict(tool: tool, state: state, snapshot: snapshot,
                                       forecast: forecast, nullWindowObsolete: nullWindowObsolete,
                                       freezeReason: freezeReason, stale: stale,
                                       staleAsOf: stale ? now.addingTimeInterval(-3600) : nil,
                                       now: now)
    }

    private func value(_ a: VerdictAnatomy, _ label: String) -> String? {
        a.rows.first { $0.label == label }?.value
    }

    // MARK: Families — every branch tags itself; condition families are inert

    func testConditionFamiliesAreInert() {
        let cases: [(String, HeaderVerdict?)] = [
            ("spendControl", verdict(tool: .codex, state: .spendControl,
                                     snapshot: snapshot(tool: .codex, used: nil), forecast: nil)),
            ("signInExpired", verdict(state: .nullWindow, snapshot: snapshot(used: nil), forecast: nil,
                                      freezeReason: .credentialExpired)),
            ("reconnecting", verdict(state: .nullWindow, snapshot: snapshot(used: nil), forecast: nil,
                                     freezeReason: .rateLimited(retryAfter: 600))),
            ("unknown", verdict(state: .nullWindow, snapshot: snapshot(used: nil), forecast: nil,
                                nullWindowObsolete: true)),
            ("nullWindow", verdict(state: .nullWindow, snapshot: snapshot(used: nil), forecast: nil)),
            ("idle", verdict(state: .idleFallback, snapshot: snapshot(used: 40, resetMinutes: 100),
                             forecast: nil)),
            ("overQuota", verdict(state: .overQuota, snapshot: snapshot(used: 100, resetMinutes: 100),
                                  forecast: forecast(runway: nil))),
            ("measuring", verdict(state: .healthy, snapshot: snapshot(used: 38, resetMinutes: 112),
                                  forecast: forecast(runway: nil, burn: nil))),
        ]
        let expected: [String: VerdictFamily] = [
            "spendControl": .spendControl, "signInExpired": .signInExpired,
            "reconnecting": .reconnecting, "unknown": .unknown, "nullWindow": .nullWindow,
            "idle": .idle, "overQuota": .overQuota, "measuring": .measuring,
        ]
        for (name, v) in cases {
            XCTAssertEqual(v?.family, expected[name], name)
            XCTAssertNil(v?.anatomy, "\(name) must be inert")
        }
        // Low-allowance shape: the row is removed outright (D-60), so nothing to click.
        XCTAssertNil(verdict(tool: .codex, state: .healthy,
                             snapshot: snapshot(tool: .codex, used: 40, resetMinutes: 100,
                                                windowSeconds: 30 * 86_400, plan: "free"),
                             forecast: forecast(tool: .codex, runway: nil, burn: nil)))
    }

    // MARK: Fixture anatomy-burn-exit (Baseline §19)

    func testAnatomyBurnExit() {
        // 87% used, 100 min to reset on a 5-hour window → elapsed 66.7%, pace firing;
        // burn 0.32 → runway 40.6 < 100 → "Won't make it". Threshold 13 ÷ 100 = 0.13.
        let v = verdict(state: .elevated, snapshot: snapshot(used: 87, resetMinutes: 100),
                        forecast: forecast(runway: 13 / 0.32, burn: 0.32, span: 9))!
        XCTAssertEqual(v.family, .exhaustion)
        let a = try! XCTUnwrap(v.anatomy)
        XCTAssertEqual(value(a, "Remaining"), "13% of window")
        XCTAssertEqual(value(a, "Burn (last 9m)"), "0.32% / min")
        // Runway row and stops clock come from the same numbers as line 2.
        let runwayToken = v.line2!.components(separatedBy: " · ").first { $0.hasPrefix("runway ~") }!
            .replacingOccurrences(of: "runway ", with: "")
        let stopsToken = v.line2!.components(separatedBy: " · ").first { $0.hasPrefix("stops ~") }!
            .replacingOccurrences(of: "stops ", with: "")
        XCTAssertEqual(value(a, "Runway at this burn"), "\(runwayToken) → stops \(stopsToken)")
        XCTAssertEqual(value(a, "Reset"),
                       "\(Fmt.clockDay(now.addingTimeInterval(100 * 60), from: now)) — 1h 40m away")
        XCTAssertEqual(value(a, "Pace"), "87% used at 67% of the window — over pace")
        XCTAssertEqual(a.comparison,
                       "At this speed you run out in about 41m — before the reset, which is 1h 40m away.")
        XCTAssertEqual(a.flip,
                       "Turns to *Was on track to run out — safe if this pace holds* if you slow down below ~0.13% / min.")
    }

    func testBurnLabelWithoutSpan() {
        let v = verdict(state: .elevated, snapshot: snapshot(used: 87, resetMinutes: 100),
                        forecast: forecast(runway: 13 / 0.32, burn: 0.32))!
        XCTAssertEqual(value(v.anatomy!, "Burn"), "0.32% / min")
    }

    // MARK: Fixture anatomy-held (Baseline §19)

    func testAnatomyHeldNamesTheActualNextRow() {
        // Warning colour still held, runway 200 > 112 to reset → held row; margin 88 → Safe.
        let held = verdict(state: .elevated, snapshot: snapshot(used: 38, resetMinutes: 112),
                           forecast: forecast(runway: 200, burn: 0.3))!
        XCTAssertEqual(held.family, .held)
        XCTAssertEqual(held.line1, "Was on track to run out — safe if this pace holds")
        XCTAssertEqual(held.anatomy?.flip,
                       "Reads *Safe at this pace* once this pace holds a few more minutes")
        XCTAssertEqual(held.anatomy?.comparison,
                       "At this speed you have about 3h20m left — the reset, 1h 52m away, comes first by about 1h28m.")
        // Margin under thinMarginMinutes → the green row it would take is "Safe, barely".
        let barely = verdict(state: .elevated, snapshot: snapshot(used: 38, resetMinutes: 112),
                             forecast: forecast(runway: 130, burn: 0.3))!
        XCTAssertEqual(barely.anatomy?.flip,
                       "Reads *Safe, barely* once this pace holds a few more minutes")
        // Held with an unmeasured burn: line stays, anatomy is nil (nothing to show).
        let noBurn = verdict(state: .elevated, snapshot: snapshot(used: 38, resetMinutes: 112),
                             forecast: forecast(runway: 200, burn: nil))!
        XCTAssertEqual(noBurn.family, .held)
        XCTAssertNil(noBurn.anatomy)
    }

    func testAnatomyHeldOnLongWindowNamesThePaceFamily() {
        // Weekly window, 6 days to reset, 7% used → elapsed 14%, under pace → next is "On pace".
        let v = verdict(state: .elevated,
                        snapshot: snapshot(used: 7, resetMinutes: 6 * 1440, windowSeconds: 604_800),
                        forecast: forecast(runway: 20_000, burn: 0.005))!
        XCTAssertEqual(v.family, .held)
        XCTAssertEqual(v.anatomy?.flip, "Reads *On pace* once this pace holds a few more minutes")
        let above = verdict(state: .elevated,
                            snapshot: snapshot(used: 30, resetMinutes: 6 * 1440, windowSeconds: 604_800),
                            forecast: forecast(runway: 20_000, burn: 0.005))!
        XCTAssertEqual(above.anatomy?.flip, "Reads *Above pace* once this pace holds a few more minutes")
    }

    /// REV-74/D-83 (STEP_123) — the anatomy's burn row follows the card's unit. STEP_110 gave this
    /// row two-to-three decimals because one would round a weekly flip threshold to `0.0`; that was
    /// the right number in the wrong unit. On a window a day or wider it now reads per hour at one
    /// decimal, and the two-decimal `% / min` form stays exactly where it was correct.
    func testAnatomyBurnRowReadsPerHourOnALongWindow() {
        let v = verdict(state: .elevated,
                        snapshot: snapshot(used: 25, resetMinutes: 6 * 1440, windowSeconds: 604_800),
                        forecast: forecast(runway: 20_000, burn: 0.0667, span: 58))!
        XCTAssertEqual(v.family, .held)
        XCTAssertEqual(value(v.anatomy!, "Burn (last 58m)"), "4.0% / hr")
    }

    /// And the helper's founding rule survives the unit change: a rate too small for one decimal
    /// falls to two rather than printing a zero it does not mean (§11.2a, unknown ≠ zero).
    func testAnatomyLongWindowBurnNeverPrintsAZeroItDoesNotMean() {
        XCTAssertEqual(Fmt.burnRate2(0.0005, window: 604_800), "0.03% / hr")
        XCTAssertEqual(Fmt.burnRate2(0, window: 604_800), "0.0% / hr")
        // Unchanged where it was already right.
        XCTAssertEqual(Fmt.burnRate2(0.32, window: 18_000), "0.32% / min")
        XCTAssertEqual(Fmt.burnRate2(0.32, window: nil), "0.32% / min")
        XCTAssertEqual(Fmt.burnRate2(0.0005, window: 18_000), "0.001% / min")
    }

    // MARK: Fixtures anatomy-safe-under-pace / anatomy-safe-over-pace (Baseline §19)

    func testAnatomySafeUnderPace() {
        // 38% used at 63% of the window: under pace, cannot become a warning by burn alone.
        let v = verdict(state: .healthy, snapshot: snapshot(used: 38, resetMinutes: 112),
                        forecast: forecast(runway: 155, burn: 0.4))!
        XCTAssertEqual(v.family, .resetsFirst)
        XCTAssertEqual(v.line1, "Safe at this pace — reset comes first")
        let a = try! XCTUnwrap(v.anatomy)
        XCTAssertEqual(value(a, "Pace"), "38% used at 63% of the window — under pace")
        XCTAssertEqual(a.flip,
                       "Can't turn into a warning yet — you're under pace: 38% used with 63% of the window gone.")
    }

    func testAnatomySafeOverPace() {
        // 85% used at 80% of the window: pace firing, so a burn rise flips it. 15 ÷ 60 = 0.25.
        let v = verdict(state: .healthy, snapshot: snapshot(used: 85, resetMinutes: 60),
                        forecast: forecast(runway: 100, burn: 0.15))!
        XCTAssertEqual(v.family, .resetsFirst)
        XCTAssertEqual(v.anatomy?.flip, "Turns to *Won't make it* if you speed up past ~0.25% / min.")
        XCTAssertEqual(value(v.anatomy!, "Pace"), "85% used at 80% of the window — over pace")
    }

    func testAnatomyGraceBandNeverClaimsUnderPace() {
        // 1% of the window elapsed (inside the 2% grace), 5% used: the clock is silent, and the
        // anatomy says why instead of "under pace".
        let v = verdict(state: .healthy, snapshot: snapshot(used: 5, resetMinutes: 297),
                        forecast: forecast(runway: 950, burn: 0.1))!
        XCTAssertEqual(value(v.anatomy!, "Pace"), "5% used at 1% of the window — window just started")
        XCTAssertEqual(v.anatomy?.flip, "Can't turn into a warning yet — the window just started.")
    }

    // MARK: Nothing burning

    func testAnatomyNothingBurning() {
        let v = verdict(state: .healthy, snapshot: snapshot(used: 38, resetMinutes: 112),
                        forecast: forecast(runway: nil, span: 12))!
        XCTAssertEqual(v.family, .nothingBurning)
        let a = try! XCTUnwrap(v.anatomy)
        XCTAssertEqual(value(a, "Burn (last 12m)"), "0.00% / min")
        XCTAssertEqual(value(a, "Runway at this burn"), "∞")
        XCTAssertEqual(a.comparison, "Nothing is burning, so the reset comes first.")
        XCTAssertEqual(a.flip, "Changes as soon as usage is measured again.")
    }

    // MARK: Shape B — the long limit (REV-96 §3.9 — STEP_194)

    /// Shape B moved with the row it explained. The weekly no longer takes the header for being
    /// *tight* — it takes it for having *stopped* you — so the anatomy now hangs off the
    /// blocked-weekly verdict, where the reader most needs to see why a five-hour window with
    /// room is not helping.
    func testAnatomyBlockingWeekly() {
        let v = verdict(state: .overQuota,
                        snapshot: snapshot(used: 22, secondary: 100, secondaryResetDays: 4,
                                           resetMinutes: 112),
                        forecast: nil)!
        XCTAssertEqual(v.family, .overQuota)
        XCTAssertEqual(v.line1, "Stopped — weekly spent, resets "
                       + Fmt.monthDay(now.addingTimeInterval(4 * 86_400)))
        let a = try! XCTUnwrap(v.anatomy)
        XCTAssertEqual(value(a, "Weekly used"), "100%")
        XCTAssertEqual(value(a, "Nearly-spent line"),
                       "\(Fmt.percent(StateEngine.longLimitNearlySpentPct)) used")
        XCTAssertEqual(value(a, "Week elapsed"), "43% · day 4 of 7")
        XCTAssertEqual(value(a, "Weekly resets"), Fmt.monthDay(now.addingTimeInterval(4 * 86_400)))
        XCTAssertEqual(value(a, "5-hour"), "22% — not the driver")
        XCTAssertEqual(a.comparison,
                       "Weekly is at 100%, past the 90% line — that's what sets the verdict whatever the pace; the 5-hour window at 22% isn't the problem.")
        XCTAssertEqual(a.flip,
                       "Stays until the reset on \(Fmt.monthDay(now.addingTimeInterval(4 * 86_400))) — usage can't go down before then.")
    }

    /// Ahead of pace shows the other hand: the calendar, and how far past it the week is.
    func testAnatomyWeeklyAheadOfPace() {
        let a = try! XCTUnwrap(DisplayFormatter.weeklyAnatomy(
            snapshot: snapshot(used: 22, secondary: 70, secondaryResetDays: 4,
                               resetMinutes: 112),
            util: 22, now: now))
        XCTAssertEqual(value(a, "Weekly used"), "70%")
        XCTAssertEqual(value(a, "Even pace would be"), "43% used")
        XCTAssertNil(a.rows.first { $0.label == "Nearly-spent line" },
                     "the line is named only when it is what decided the verdict")
        XCTAssertEqual(a.comparison,
                       "You've used 70% of the week with 43% of it gone — 27 points ahead of even pace.")
        XCTAssertEqual(a.flip,
                       "Reads *on pace* again once the calendar catches up. 30% left is about 8% a day.")
    }

    /// A block the five-hour window owns carries no Shape B — there is no second limit to explain.
    func testAnatomyAbsentOnAPrimaryBlock() {
        let v = verdict(state: .overQuota, snapshot: snapshot(used: 100, resetMinutes: 112),
                        forecast: nil)!
        XCTAssertNil(v.anatomy)
    }

    // MARK: Shape C — long-window pace

    func testAnatomyLongWindowOnPace() {
        let v = verdict(state: .healthy,
                        snapshot: snapshot(used: 7, resetMinutes: 6 * 1440, windowSeconds: 604_800),
                        forecast: forecast(runway: nil, burn: nil))!
        XCTAssertEqual(v.family, .longWindowPace)
        XCTAssertEqual(v.line1, "On pace")
        let a = try! XCTUnwrap(v.anatomy)
        XCTAssertEqual(value(a, "Used"), "7%")
        XCTAssertEqual(value(a, "Window elapsed"), "14% (day 2 of 7)")
        XCTAssertEqual(value(a, "Resets"), Fmt.monthDay(now.addingTimeInterval(6 * 86_400)))
        XCTAssertEqual(a.comparison, "You've used 7 points less than the calendar would by now")
        XCTAssertEqual(a.flip,
                       "Reads *Above pace* once you've used more than the calendar — 14% today, rising about 14% a day.")
    }

    func testAnatomyLongWindowAbovePace() {
        let v = verdict(state: .healthy,
                        snapshot: snapshot(used: 30, resetMinutes: 6 * 1440, windowSeconds: 604_800),
                        forecast: forecast(runway: nil, burn: nil))!
        XCTAssertEqual(v.line1, "Above pace — 30% used")
        let a = try! XCTUnwrap(v.anatomy)
        XCTAssertEqual(a.comparison, "You've used 16 points more than the calendar would by now")
        XCTAssertTrue(a.flip!.hasPrefix("Reads *On pace* by about "), a.flip!)
        XCTAssertTrue(a.flip!.hasSuffix("if you pause — the calendar catches up with 30%."), a.flip!)
    }

    // MARK: Cross-tool parity and the §10 ban

    func testCodexExhaustionAnatomyEqualsClaude() {
        let claude = verdict(state: .elevated, snapshot: snapshot(used: 87, resetMinutes: 100),
                             forecast: forecast(runway: 13 / 0.32, burn: 0.32, span: 9))!
        let codex = verdict(tool: .codex, state: .elevated,
                            snapshot: snapshot(tool: .codex, used: 87, resetMinutes: 100,
                                               windowSeconds: 18_000),
                            forecast: forecast(tool: .codex, runway: 13 / 0.32, burn: 0.32, span: 9))!
        XCTAssertEqual(codex.family, .exhaustion)
        XCTAssertEqual(codex.anatomy, claude.anatomy)
    }

    func testAnatomyNeverExposesPollingMechanics() {
        let all: [HeaderVerdict?] = [
            verdict(state: .elevated, snapshot: snapshot(used: 87, resetMinutes: 100),
                    forecast: forecast(runway: 13 / 0.32, burn: 0.32, span: 9)),
            verdict(state: .elevated, snapshot: snapshot(used: 38, resetMinutes: 112),
                    forecast: forecast(runway: 200, burn: 0.3)),
            verdict(state: .healthy, snapshot: snapshot(used: 38, resetMinutes: 112),
                    forecast: forecast(runway: 155, burn: 0.4)),
            verdict(state: .healthy, snapshot: snapshot(used: 38, resetMinutes: 112),
                    forecast: forecast(runway: nil)),
            verdict(state: .overQuota,
                    snapshot: snapshot(used: 22, secondary: 100, secondaryResetDays: 4,
                                       resetMinutes: 112),
                    forecast: nil),
            verdict(state: .healthy,
                    snapshot: snapshot(used: 30, resetMinutes: 6 * 1440, windowSeconds: 604_800),
                    forecast: forecast(runway: nil, burn: nil)),
        ]
        for v in all {
            let a = try! XCTUnwrap(v?.anatomy)
            let text = (a.rows.map { $0.label + " " + $0.value } + [a.comparison, a.flip ?? ""])
                .joined(separator: "\n").lowercased()
            for banned in ["poll", "cadence", "throttl", "backing off", "rate limit"] {
                XCTAssertFalse(text.contains(banned), "\(banned) leaked: \(text)")
            }
        }
    }
}
