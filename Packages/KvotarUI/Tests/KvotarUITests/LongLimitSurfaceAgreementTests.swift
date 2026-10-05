import XCTest
import KvotarCore
@testable import KvotarUI

/// The four surfaces must say one thing (REV-96 §3.11, Baseline §19 — STEP_195).
///
/// Each of them is built by a different function from the same snapshot: the menu-bar dot and slot
/// by `toolMenuBar`, the tab dot by `DisplayFormatter.dot(for:)`, the hero and the strip by
/// `header`, the rows by `otherLimitsSection`. Nothing structural stops two of them from drifting
/// — the §19 discipline is a *rule*, and this is where it is enforced. The precedent is
/// `MenuBarExhaustionAgreementTests`, which does the same job for the ◔ slot.
final class LongLimitSurfaceAgreementTests: XCTestCase {

    override func setUp() {
        super.setUp()
        FixtureTimeZone.pin(self)
    }

    private let now = LongLimitFixture.now

    // MARK: The fixtures describe states their own numbers produce

    /// A fixture that names a rank its inputs would never classify as is a fixture that proves
    /// nothing. The ranking is `StateEngineTests`' job; this ties each frame's claimed tier to the
    /// assessment Core actually derives from it.
    func testEveryFixtureCarriesTheTierItClaims() {
        for f in LongLimitFixture.all + LongLimitFixture.outsideTheRankSet {
            XCTAssertEqual(f.snapshot.longLimit(now: now)?.tier, f.expectedTier, f.name)
        }
    }

    /// **The two readings the trigger is calibrated on** (REV-98 §3.8 — STEP_200). They differ by
    /// where their pace lands and by nothing else: both are past the 50 % floor, past the grace,
    /// and ahead of their own calendar, so the shipped-before rule made both amber. The July one
    /// projects to 101 % and is now calm; the owner's live one projects to 115 % and stays amber.
    func testTheProjectionFixturesSitEitherSideOfTheLine() {
        let july = try! XCTUnwrap(LongLimitFixture.claudeProjection101Calm
            .snapshot.longLimit(now: now))
        XCTAssertEqual(july.usedPct / july.elapsedPct * 100, 101, accuracy: 1)
        XCTAssertEqual(july.tier, .onPace)
        XCTAssertGreaterThan(july.usedPct, july.elapsedPct,
                             "ahead of its calendar — amber under the rule this replaces")

        let live = try! XCTUnwrap(LongLimitFixture.claudeProjection115Amber
            .snapshot.longLimit(now: now))
        XCTAssertEqual(live.usedPct / live.elapsedPct * 100, 115, accuracy: 1)
        XCTAssertEqual(live.tier, .aheadOfPace)
    }

    // MARK: Dot agreement — menu bar, tab, hero

    /// The menu-bar dot, the tab dot and the hero's ink are one status. The hero renders in
    /// `dot.color` from the display state, so asserting the display state's dot against the bar's
    /// is asserting all three (`HeaderSectionView` is handed the same value).
    func testMenuBarDotMatchesTheTabDotOnEveryFixture() {
        for f in LongLimitFixture.all {
            if f.staleAsOf != nil { continue }   // stale greys the bar by design (STEP_32)
            XCTAssertEqual(f.menuBar.dot, f.displayDot,
                           "\(f.name): the bar and the tab disagree about the account's status")
            XCTAssertEqual(f.displayDot, DisplayFormatter.dot(for: f.state), f.name)
        }
    }

    /// **The hero is about its own limit** (REV-96 §5.7). Under a long-limit rank with the
    /// five-hour still in the header, the number and its meter take the calm colour and match the
    /// verdict beside them — the account's colour is on the strip and the two dots. In a block
    /// the hero *is* the limit, so all four agree by being one thing.
    func testTheHeroInkFollowsTheLimitInTheHeaderNotTheAccount() {
        for f in LongLimitFixture.all where f.staleAsOf == nil {
            guard let header = f.header else { return XCTFail(f.name) }
            let heroCue = header.heroCue ?? f.displayDot
            if header.longLimitStrip != nil {
                XCTAssertEqual(heroCue, .green,
                               "\(f.name): the five-hour hero took the long limit's colour")
                XCTAssertEqual(heroCue, header.verdict?.colour,
                               "\(f.name): the hero and its own verdict disagree")
            } else {
                XCTAssertEqual(heroCue, f.displayDot, f.name)
            }
        }
    }

    // MARK: The reminder and the strip

    /// **A reminder implies a strip naming the same limit** (REV-97 §2.1, rewritten from
    /// STEP_195's slot version). Not the converse: a five-hour warning outranks ranks 5b and 10,
    /// and the bar then holds its own urgent string while the strip still says the weekly is
    /// nearly spent. Same shape as D-113's "a ◔ slot implies the exhaustion row".
    ///
    /// The **first** reminder is the one checked, because that is the one the strip is about:
    /// both take the head of `longLimitsRanked`, so a disagreement here means the two surfaces
    /// have started ordering the limits differently.
    func testEveryReminderHasAStripBehindIt() {
        for f in LongLimitFixture.all {
            guard let first = f.menuBar.reminders.first else { continue }
            guard let strip = f.header?.longLimitStrip else {
                XCTFail("\(f.name): the bar reminds about a limit the popover does not name")
                continue
            }
            let expected = strip.limitID == .monthly ? "mo" : "wk"
            XCTAssertTrue(first.contains("⚠\(expected)"),
                          "\(f.name): the reminder reads \(first), the strip names \(strip.limitID)")
        }
    }

    /// **Amber** leaves the steady string exactly as a reader has learned to read it and says its
    /// piece in the reminder (REV-97 §2.1, unchanged by REV-100). **Red** does not: it holds the
    /// long limit's own shape — `⚠wk 8% ↻2d` — with no reminder, no pulse, and no width beyond its
    /// steady render (REV-100 §2.1 / D-124 — STEP_210). The expected percent and slot are read off
    /// Core's lead assessment, so the fixture's numbers state the string.
    func testAmberCyclesTheCalmStringAndRedHoldsTheLimit() {
        var red = 0
        for f in LongLimitFixture.all where f.state == .limitAheadOfPace
                                         || f.state == .limitNearlySpent {
            if f.state == .limitAheadOfPace {
                let calm = DisplayFormatter.toolMenuBar(tool: f.tool, state: .healthy,
                                                        snapshot: f.snapshot, forecast: f.forecast,
                                                        now: now)
                XCTAssertEqual(f.menuBar.fullString, calm.fullString,
                               "\(f.name): amber moved the steady string")
                XCTAssertFalse(f.menuBar.reminders.isEmpty, "\(f.name): amber with no reminder")
                XCTAssertEqual(f.menuBar.dot, .amber, f.name)
                continue
            }
            red += 1
            guard let lead = f.snapshot.longLimitsRanked(now: now).first else {
                XCTFail("\(f.name): rank 5b with no assessment"); continue
            }
            let scope = lead.limit == .monthly ? "mo" : "wk"
            XCTAssertEqual(f.menuBar.percentText, "⚠\(scope) \(Fmt.percent(lead.remainingPct))",
                           f.name)
            XCTAssertEqual(f.menuBar.timeSlot,
                           Fmt.countdown(to: lead.resetsAt, from: now).map { "↻\($0)" }, f.name)
            XCTAssertTrue(f.menuBar.reminders.isEmpty, "\(f.name): red should not cycle")
            XCTAssertEqual(f.menuBar.dot, .red, f.name)
            XCTAssertFalse(f.menuBar.longLimits.statuses.isEmpty,
                           "\(f.name): held, not recovered — the limit stays in the reading")
            let render = DisplayFormatter.menuBarRender(mode: .claudeOnly, claude: f.menuBar,
                                                        codex: f.menuBar)
            XCTAssertEqual(MenuBarWidth.phaseRenders(render).count, 1,
                           "\(f.name): nothing to reserve beyond the held string")
            XCTAssertFalse(MenuBarReminder.pulses(reminderIndex: render.lines.first?.reminderIndex,
                                                  reduceMotion: false), f.name)
        }
        XCTAssertGreaterThanOrEqual(red, 3, "the red fixtures went missing")
    }

    /// **A tight five-hour still takes the bar over a red weekly, and gives it back** (REV-100
    /// §2.1). No new predicate: the rank decides. The same snapshot with the five-hour calm
    /// classifies 5b again and the weekly string returns.
    func testATightFiveHourOutranksRedAndTheWeeklyReturns() {
        let tight = LongLimitFixture.claudeFiveHourOutranksTheWeekly
        XCTAssertEqual(tight.menuBar.timeSlot, "◔~11m")
        XCTAssertFalse(tight.menuBar.percentText.contains("⚠"))

        // The same week and the same weekly — only the five-hour has room again.
        let calmPrimary = LongLimitFixture.weeklySnapshot(tool: .claude, primaryUsed: 36,
                                                          weeklyUsed: 91, weekElapsed: 0.5,
                                                          plan: "max")
        let calmed = DisplayFormatter.toolMenuBar(tool: .claude, state: .limitNearlySpent,
                                                  snapshot: calmPrimary, forecast: nil, now: now)
        XCTAssertTrue(calmed.percentText.hasPrefix("⚠wk "), calmed.fullString)
        XCTAssertEqual(calmed.dot, .red)
    }

    /// **The limit that stopped you takes the bar** (REV-97 §2.5) — and it holds, with no
    /// reminder, because a block is not a reminder. The five-hour percent is gone from the bar in
    /// a long-limit block: it was either irrelevant or actively misleading (STEP_195's finding).
    func testABlockingLongLimitTakesTheBarAndHolds() {
        for f in LongLimitFixture.all {
            guard let episode = f.snapshot.blockEpisode, episode.limit != .primary,
                  f.state == .overQuota || f.state == .spendControl
            else { continue }
            let expected = episode.limit == .monthly ? "⚠mo 0%" : "⚠wk 0%"
            XCTAssertEqual(f.menuBar.percentText, expected,
                           "\(f.name): the bar reads \(f.menuBar.fullString)")
            XCTAssertTrue(f.menuBar.reminders.isEmpty, "\(f.name): a block should not cycle")
        }
    }

    // MARK: The strip and the row it names

    /// Exactly one row is lifted, and it is the row the strip is about. The highlight is derived
    /// from the strip builder itself, so this is really asserting that the one derivation reached
    /// both surfaces.
    func testTheStripAndTheHighlightNameOneLimit() {
        for f in LongLimitFixture.all {
            let highlighted = (f.otherLimits?.rows ?? []).filter(\.isHighlighted)
            guard let strip = f.header?.longLimitStrip else {
                XCTAssertTrue(highlighted.isEmpty, "\(f.name): a highlight with no strip")
                continue
            }
            XCTAssertEqual(highlighted.count, 1, "\(f.name): expected one lifted row")
            XCTAssertEqual(highlighted.first?.id, strip.limitID, f.name)
            // The strip and the row open the same card, so a reader who clicks either gets one
            // explanation rather than two accounts of the same limit.
            XCTAssertEqual(highlighted.first?.explanation, strip.explanation, f.name)
        }
    }

    // MARK: A block

    /// In a block the hero is the limit that stopped you, every other limit greys with no dot, and
    /// nothing is highlighted — there is no strip, because the header is already about the limit a
    /// strip would name.
    func testABlockGreysTheOtherLimitsAndDropsTheirDots() {
        for f in [LongLimitFixture.claudeWeeklySpent, .claudeBlockRollover, .claudeBlockBoth] {
            XCTAssertNil(f.header?.longLimitStrip, "\(f.name): a strip beside a block")
            XCTAssertEqual(f.header?.limit?.id, .secondaryWindow,
                           "\(f.name): the blocking limit takes the hero")
            XCTAssertEqual(f.header?.heroText, "0%", f.name)
            let others = f.otherLimits?.rows ?? []
            XCTAssertFalse(others.isEmpty, f.name)
            for row in others {
                XCTAssertTrue(row.isBlocked, "\(f.name): \(row.label) is not marked blocked")
                XCTAssertNil(row.cue, "\(f.name): \(row.label) kept a dot inside a block")
                XCTAssertTrue(row.value.contains("blocked by the weekly"),
                              "\(f.name): \(row.label) reads \(row.value)")
                XCTAssertFalse(row.isHighlighted, f.name)
            }
        }
    }

    /// The stale frame inside the same block: the block survives (quota cannot be un-spent), and
    /// the tier suffixes do not — the `blocked by the` claim is withheld off a frozen reading
    /// exactly as the tier word is.
    func testAStaleBlockKeepsTheBlockAndWithholdsTheTierWords() {
        let f = LongLimitFixture.claudeBlockStale
        XCTAssertNil(f.header?.longLimitStrip)
        for row in f.otherLimits?.rows ?? [] {
            XCTAssertFalse(row.isBlocked, "a frozen reading must not assert unreachable quota")
            XCTAssertFalse(row.value.contains("· spent"))
            XCTAssertFalse(row.value.contains("· on pace"))
        }
    }

    /// The hint under a block quotes **the blocking limit's** reset. The five-hour reset frees
    /// nothing while the weekly holds, and quoting it put "blocked … resets in 226 min" under a
    /// header reading `resets Sep 12 · in 3d` — two answers to one question, on one screen.
    func testTheBlockHintQuotesTheBlockingLimitsReset() {
        let f = LongLimitFixture.claudeWeeklySpent
        let hint = f.claude.recommendation ?? ""
        XCTAssertTrue(hint.contains("3 days"), hint)
        XCTAssertFalse(hint.contains("min"), "the five-hour countdown has no business here: \(hint)")
        // And the header above it names the same reset — one answer to "when does this end".
        XCTAssertTrue(f.header?.verdict?.line1.contains("resets Sep 12") == true,
                      f.header?.verdict?.line1 ?? "—")
    }

    /// A blocked header states its reset once (STEP_223). The hero's `resets in …` line exists
    /// for the calm long-window verdict, which carries no reset; a block verdict names its own,
    /// and the tester's build 16 block read `resets Sep 22` / `in 7h 24m` / `resets in 7h 24m`.
    func testABlockedHeaderStatesItsResetOnce() {
        let blocked = [LongLimitFixture.claudeWeeklySpent,
                       .claudeTeamWeeklySpentCharging,
                       .claudeTeamWeeklySpentCapReached,
                       .claudeTeamWeeklySpentCreditsSwitchedOff]
        for f in blocked {
            let details = f.header?.heroDetails.map(\.text) ?? []
            XCTAssertFalse(details.contains { $0.hasPrefix("resets in") },
                           "\(f.name): \(details)")
        }
        // The `Stopped —` frames carry the one countdown on verdict line 2 …
        XCTAssertEqual(LongLimitFixture.claudeWeeklySpent.header?.verdict?.line2, "blocked · in 3d")
        XCTAssertEqual(LongLimitFixture.claudeTeamWeeklySpentCapReached.header?.verdict?.line2,
                       "blocked · in 18h 7m")
        XCTAssertEqual(LongLimitFixture.claudeTeamWeeklySpentCreditsSwitchedOff.header?.verdict?.line2,
                       "blocked · in 7h 24m")
        // … and the credits-paying frame states the date, with the countdown left to the banner.
        let charging = LongLimitFixture.claudeTeamWeeklySpentCharging
        XCTAssertTrue((charging.header?.verdict?.line2 ?? "").contains("weekly resets "))
        XCTAssertTrue(charging.claude.recommendation?.hasSuffix("Window resets in 38h 0m.") == true,
                      charging.claude.recommendation ?? "—")
    }

    /// The banner under a weekly block names the weekly and speaks in hours (STEP_223) — it read
    /// `until the window resets in 444 min` on the tester's build 16.
    func testTheBlockBannerNamesTheWeeklyInHours() {
        XCTAssertEqual(LongLimitFixture.claudeTeamWeeklySpentCreditsSwitchedOff.claude.recommendation,
                       "New requests are blocked until the weekly resets in 7h 24m. "
                       + "Any task currently running can complete.")
        XCTAssertEqual(LongLimitFixture.claudeTeamWeeklySpentCapReached.claude.recommendation,
                       "New requests are blocked until the weekly resets in 18h 7m. "
                       + "Any task currently running can complete.")
        XCTAssertEqual(LongLimitFixture.claudeWeeklySpent.claude.recommendation,
                       "New requests are blocked until the weekly resets in 3 days. "
                       + "Any task currently running can complete.")
    }

    // MARK: The Team seat — org-paid usage credits (REV-102 §2.3a — STEP_220)

    /// Every Team frame states the tier Core derives, and none of them carries a monthly: no
    /// Monthly row, no strip about one, no near-cap box — the triple statement cannot be built.
    func testTheTeamFramesHaveNoMonthlyAnywhere() {
        for f in LongLimitFixture.teamCredits {
            XCTAssertEqual(f.snapshot.longLimit(now: LongLimitFixture.now)?.tier, f.expectedTier,
                           f.name)
            XCTAssertNil(f.snapshot.monthlyLimit, f.name)
            XCTAssertNil(f.header?.longLimitStrip, "\(f.name): a strip on a Team frame")
            XCTAssertFalse((f.otherLimits?.rows ?? []).contains { $0.label.contains("Monthly") },
                           f.name)
            XCTAssertEqual(f.claude.creditsCard?.title,
                           "Usage credits · set by your organization", f.name)
            XCTAssertNil(f.claude.creditsCard?.manageURL, "\(f.name): the seat cannot self-serve")
            XCTAssertEqual(f.claude.creditsCard?.rows.map(\.label), ["This month"], f.name)
        }
    }

    /// Frame A: the weekly is spent and the organization is paying.
    func testFrameAWeeklySpentCharging() {
        let f = LongLimitFixture.claudeTeamWeeklySpentCharging
        XCTAssertEqual(f.menuBar.fullString, "CL ⚠wk 0% ↻38h00m")
        XCTAssertEqual(f.menuBar.glyph, .charging)
        XCTAssertEqual(f.menuBar.moneySymbol, "€")
        XCTAssertEqual(f.menuBar.dot, .red)
        XCTAssertEqual(f.header?.limit?.id, .secondaryWindow)
        XCTAssertEqual(f.header?.heroText, "0%")
        XCTAssertEqual(f.header?.verdict?.line1, "Running on credits — every token costs now")
        XCTAssertEqual(f.header?.verdict?.moneySymbol, "€")
        let line2 = f.header?.verdict?.line2 ?? ""
        XCTAssertTrue(line2.hasPrefix("€29.96 of €70.00 this month · weekly resets "), line2)
        let card = f.claude.creditsCard
        XCTAssertEqual(card?.status.value, "Charging now")
        XCTAssertEqual(card?.status.dot, .red)
        XCTAssertTrue(card?.rows.first?.value.hasPrefix("€29.96 of €70.00 · resets ") == true)
        XCTAssertEqual(card?.subLine, "Paid by your organization at API rates.")
        XCTAssertTrue((f.claude.recommendation ?? "").hasPrefix("Operating on usage credits."))
    }

    /// Frame B — the bundle's moment: an ordinary weekly block, held, plus the one muted line.
    func testFrameBWeeklySpentCapReached() {
        let f = LongLimitFixture.claudeTeamWeeklySpentCapReached
        XCTAssertEqual(f.menuBar.fullString, "CL ⚠wk 0% ↻18h07m")
        XCTAssertEqual(f.menuBar.glyph, .none)
        XCTAssertTrue(f.menuBar.reminders.isEmpty)
        XCTAssertEqual(f.header?.limit?.id, .secondaryWindow)
        XCTAssertTrue(f.header?.verdict?.line1.hasPrefix("Stopped — weekly spent, resets ") == true)
        XCTAssertEqual(f.header?.verdict?.moneyPrefix, false)
        let spent = f.header?.heroDetails.map(\.text).filter { $0.hasPrefix("Usage credits") }
        XCTAssertEqual(spent?.count, 1)
        XCTAssertTrue(spent?.first?.hasSuffix("— €70.00 cap, set by your organization") == true)
        let card = f.claude.creditsCard
        XCTAssertTrue(card?.status.value.hasPrefix("Spent for ") == true)
        XCTAssertEqual(card?.status.dot, .neutral, "at the cap the card is neutral, not red")
        XCTAssertTrue(card?.rows.first?.value.hasPrefix("€70.25 of €70.00 · resets ") == true)
        XCTAssertEqual(card?.subLine, "You stop when a window runs out.")
        XCTAssertFalse((f.claude.recommendation ?? "").contains("usage credits"),
                       "a spent cap is not accruing")
    }

    /// Frame B a day later (REV-102 §6 item 1 — STEP_222): the meter is switched off and sends no
    /// amounts. Header and bar as frame B; the card is still the organization's — no amounts, no
    /// Manage link, and the provider's reason string on no surface.
    func testFrameBSwitchedOffIsStillTheOrganizationsCard() {
        let f = LongLimitFixture.claudeTeamWeeklySpentCreditsSwitchedOff
        XCTAssertEqual(f.menuBar.fullString, "CL ⚠wk 0% ↻7h24m")
        XCTAssertEqual(f.menuBar.glyph, .none)
        XCTAssertTrue(f.header?.verdict?.line1.hasPrefix("Stopped — weekly spent, resets ") == true)
        let spent = f.header?.heroDetails.map(\.text).filter { $0.hasPrefix("Usage credits") }
        XCTAssertEqual(spent?.count, 1)
        XCTAssertTrue(spent?.first?.hasPrefix("Usage credits spent for ") == true)
        XCTAssertTrue(spent?.first?.hasSuffix(" — set by your organization") == true,
                      "no cap clause where the provider states no cap")
        let card = try? XCTUnwrap(f.claude.creditsCard)
        XCTAssertEqual(card?.moneyState, .capReached)
        XCTAssertTrue(card?.status.value.hasPrefix("Spent for ") == true)
        XCTAssertEqual(card?.status.dot, .neutral)
        XCTAssertTrue(card?.rows.first?.value.hasPrefix("resets ") == true,
                      "the reset alone — never a fabricated €0.00")
        XCTAssertEqual(card?.subLine, "You stop when a window runs out.")
        XCTAssertNil(card?.manageURL)
        let everything = [card?.status.value, card?.subLine, card?.rows.first?.value,
                          f.header?.verdict?.line1, f.header?.verdict?.line2, f.claude.recommendation]
            .compactMap { $0 } + (f.header?.heroDetails.map(\.text) ?? [])
        XCTAssertFalse(everything.contains { $0.contains("out_of_credits") || $0.contains("€") },
                       everything.joined(separator: " | "))
    }

    /// Any other org-managed off state reads `Off` and still never prints the reason.
    func testOrgCardNeverPrintsARawReason() {
        let snapshot = QuotaSnapshot(
            tool: .claude, primaryUsedPct: 10,
            primaryResetsAt: LongLimitFixture.now.addingTimeInterval(3_600),
            secondaryUsedPct: 20, secondaryResetsAt: LongLimitFixture.now.addingTimeInterval(86_400),
            rateLimitReached: false,
            extraUsage: ExtraUsage(isEnabled: false, monthlyLimit: 7_000, usedCredits: 16.8,
                                   currency: "EUR", disabledReason: "org_disabled",
                                   managedByOrganization: true, currencyExponent: 2))
        let card = DisplayFormatter.creditsCard(snapshot: snapshot, forecast: nil, pollAsOf: nil,
                                                staleAsOf: nil, now: LongLimitFixture.now)
        XCTAssertEqual(card?.status.value, "Off")
        XCTAssertNil(card?.subLine)
    }

    /// Frame C: fresh windows, the cap still reached. Calm everywhere but the card.
    func testFrameCCapReachedWindowsFine() {
        let f = LongLimitFixture.claudeTeamCapReachedWindowsFine
        XCTAssertEqual(f.menuBar.fullString, "CL 100%")
        XCTAssertEqual(f.menuBar.dot, .green)
        XCTAssertEqual(f.menuBar.glyph, .none)
        XCTAssertEqual(f.header?.limit?.id, .primaryWindow)
        XCTAssertFalse((f.header?.heroDetails ?? []).contains { $0.text.hasPrefix("Usage credits") },
                       "with no window spent the card alone carries the cap")
        XCTAssertTrue(f.claude.creditsCard?.status.value.hasPrefix("Spent for ") == true)
        XCTAssertEqual(f.claude.creditsCard?.status.dot, .neutral)
    }

    // MARK: The tier words the rows carry

    /// **The row the strip names states its number and stops** (REV-98 §2.5(c) — STEP_201). On
    /// each of these frames the strip is about the row being read, so the verdict is already on
    /// screen one line under the hero; repeating it here said one thing twice and wrapped the row
    /// to two lines. The row value is the bare remaining percent — "left" is the §0.1 convention
    /// stated once, in the label, and not repeated on every number (REV-77 / D-97).
    func testTheHighlightedRowDropsItsTierSuffix() {
        let ahead = LongLimitFixture.claudeAheadOfPace.otherLimits?.rows
            .first { $0.id == .secondaryWindow }
        XCTAssertEqual(ahead?.isHighlighted, true)
        XCTAssertEqual(ahead?.value, "30%")
        XCTAssertTrue(ahead?.reset?.contains("day 3 of 7") == true, ahead?.reset ?? "—")

        let nearly = LongLimitFixture.claudeNearlySpent.otherLimits?.rows
            .first { $0.id == .secondaryWindow }
        XCTAssertEqual(nearly?.isHighlighted, true)
        XCTAssertEqual(nearly?.value, "9%")

        let monthly = LongLimitFixture.claudeMonthlyNearlyReached.otherLimits?.rows
            .first { $0.id == .monthly }
        XCTAssertEqual(monthly?.isHighlighted, true)
        XCTAssertFalse(monthly?.value.contains("·") == true, monthly?.value ?? "—")
    }

    /// **A second elevated limit has no strip, so it keeps the only verdict it has** (§2.5(c)).
    /// The monthly is nearly reached and takes the strip; the weekly is running out early and is
    /// named nowhere else on the screen. Dropping every suffix unconditionally would silence it.
    ///
    /// A monthly pool is *reached*, not spent — you do not spend a budget someone else set.
    func testASecondElevatedLimitKeepsItsSuffix() {
        let f = LongLimitFixture.claudeBothLimitsWarning
        XCTAssertEqual(f.header?.longLimitStrip?.limitID, .monthly, "the worse tier takes the strip")

        let weekly = try! XCTUnwrap((f.otherLimits?.rows ?? []).first { $0.id == .secondaryWindow })
        XCTAssertFalse(weekly.isHighlighted)
        XCTAssertTrue(weekly.value.hasSuffix("· runs out early"), weekly.value)

        let monthly = try! XCTUnwrap((f.otherLimits?.rows ?? []).first { $0.id == .monthly })
        XCTAssertTrue(monthly.isHighlighted)
        XCTAssertFalse(monthly.value.contains("nearly reached"), monthly.value)
    }

    /// **`ahead of pace` reads as good news** (REV-98 §1 item 5, §2.5(b)). It was the one rung of
    /// the ladder whose plain sense inverted its meaning, and it is gone from every surface a
    /// reader sees. The rank's own name is deliberately untouched (Baseline §13).
    func testNoSurfaceSaysAheadOfPace() {
        for f in LongLimitFixture.all + LongLimitFixture.outsideTheRankSet {
            let strings = [f.header?.longLimitStrip?.text, f.header?.verdict?.line1,
                           f.header?.verdict?.line2, f.claude.recommendation]
                + (f.otherLimits?.rows ?? []).map(\.value)
            for text in strings.compactMap({ $0 }) {
                XCTAssertFalse(text.contains("ahead of pace"), "\(f.name): \(text)")
            }
        }
    }

    // MARK: One tier, one colour

    /// **The defect this step exists for.** The weekly row took its dot from `Fmt.thresholdDot`,
    /// a bare utilization threshold that calls 70 % amber and 52 % green, while the row's own
    /// words and the strip above it came from the tier. Live on the owner's account that rendered
    /// an amber strip reading "Weekly ahead of pace" directly above a **green** row about the
    /// same limit. Now the tier owns the dot, the value's ink and the words together.
    func testATieredRowTakesTheTiersColourOnEveryFixture() {
        for f in LongLimitFixture.all {
            guard let strip = f.header?.longLimitStrip,
                  let row = (f.otherLimits?.rows ?? []).first(where: { $0.id == strip.limitID })
            else { continue }
            XCTAssertEqual(row.cue, strip.cue,
                           "\(f.name): the strip is \(strip.cue) and its row is \(String(describing: row.cue))")
        }
    }

    /// The projection fixture the threshold rule would have got wrong on its own: 52 % used is
    /// green to `Fmt.thresholdDot` and amber to the pace clock, and the pace clock is what the
    /// rest of the row says. This is the owner's live 2026-09-14 reading.
    func testTheAmberWeeklyIsAmberWhereTheThresholdWouldSayGreen() {
        let f = LongLimitFixture.claudeProjection115Amber
        let weekly = try! XCTUnwrap((f.otherLimits?.rows ?? []).first { $0.id == .secondaryWindow })
        XCTAssertEqual(Fmt.thresholdDot(52), .green, "the threshold rule's own reading")
        XCTAssertEqual(weekly.cue, .amber)
    }

    /// **Model allowances are not tiered and keep the threshold dot** (§2.5(a)). The section
    /// knowingly runs two colour rules, because REV-96 tiers a secondary window and a monthly
    /// pool and nothing else — this is the assertion that says so rather than leaving it implied.
    func testAModelWindowKeepsTheThresholdDot() {
        let f = LongLimitFixture.claudeAheadOfPace
        let models = (f.otherLimits?.modelGroups ?? []).flatMap(\.rows)
        for row in models {
            guard case .modelWindow = row.id else { continue }
            XCTAssertNotNil(row.cue, row.label)
        }
        // And the rule itself, on the one input the tier and the threshold disagree about.
        XCTAssertEqual(DisplayFormatter.tieredCue(nil, stale: false, fallback: .green), .green)
    }

    /// A tier read off a frozen snapshot would be the confident claim D-35 refuses, so the dot
    /// falls back with the words: the stale weekly is coloured by its utilization, not by a pace
    /// nobody has measured since the reading froze.
    func testAStaleRowFallsBackToTheThresholdDot() {
        let assessment = LongLimitFixture.claudeAheadOfPace.snapshot.longLimit(now: now)
        XCTAssertEqual(assessment?.tier, .aheadOfPace)
        XCTAssertEqual(DisplayFormatter.tieredCue(assessment, stale: true, fallback: .green), .green)
        XCTAssertEqual(DisplayFormatter.tieredCue(assessment, stale: false, fallback: .green), .amber)
    }
}
