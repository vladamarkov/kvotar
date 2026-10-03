import XCTest
import KvotarCore

// STEP_140 (REV-77 / D-97): notification copy tests — every body says *left*. The presenter's
// source file is compiled directly into this bundle (there is no app-hosted test target; this
// closes the coverage gap STEP_99 recorded), so the static copy seam
// `UserNotificationPresenter.body(for:includeProject:)` is same-module accessible.
final class UserNotificationPresenterTests: XCTestCase {

    private func decision(_ event: NotificationEventType, tool: Tool = .claude,
                          variant: String? = nil, util: Double? = nil,
                          runway: Double? = nil, resetsAt: Date? = nil,
                          delta: Double? = nil, surfaces: [String] = [],
                          credits: Decimal? = nil, limitCents: Int? = nil,
                          currency: String? = nil,
                          episode: BlockEpisode? = nil,
                          longLimit: LongLimitAssessment? = nil) -> NotificationDecision {
        NotificationDecision(tool: tool, eventType: event, windowStart: 1_756_000_000,
                             copyVariant: variant, utilizationPct: util, runwayMinutes: runway,
                             resetsAt: resetsAt, primaryWindowSeconds: nil, deltaPct: delta,
                             model: nil, project: nil, surfaces: surfaces,
                             extraUsageUsedCredits: credits, extraUsageMonthlyLimit: limitCents,
                             extraUsageCurrency: currency,
                             blockEpisode: episode, longLimit: longLimit)
    }

    private func title(_ d: NotificationDecision) -> String {
        UserNotificationPresenter.title(for: d)
    }

    /// A weekly, `days` out, in whichever tier the caller needs.
    private func weekly(_ tier: LongLimitAssessment.Tier, used: Double = 92,
                        days: Double = 3) -> LongLimitAssessment {
        LongLimitAssessment(limit: .secondary, tier: tier, usedPct: used, elapsedPct: 50,
                            resetsAt: Date().addingTimeInterval(days * 86_400),
                            periodSeconds: 7 * 86_400)
    }

    private func weeklyEpisode(days: Double = 3) -> BlockEpisode {
        BlockEpisode(tool: .claude, limit: .secondary,
                     limitResetsAt: Date().addingTimeInterval(days * 86_400))
    }

    private func body(_ d: NotificationDecision) -> String {
        UserNotificationPresenter.body(for: d, includeProject: false)
    }

    // Spec §4.1 event 1 (as amended 2026-08-23): `[X]% left · runs out in ~[N] min at this pace.
    // Resets at [time].` The reset clock is locale-formatted, so assert the prefix.
    func testAtRiskBodySaysLeft() {
        let b = body(decision(.atRisk, util: 87, runway: 11.4,
                              resetsAt: Date().addingTimeInterval(11 * 60)))
        XCTAssertTrue(b.hasPrefix("13% left · runs out in ~11 min at this pace. Resets at "), b)
    }

    func testAtRiskWithoutRunwayKeepsFallback() {
        let b = body(decision(.atRisk, util: 87))
        XCTAssertTrue(b.hasPrefix("13% left · at risk."), b)
    }

    // Spec §4.1 event 2: `[X]% left with [Nh Nm] until reset. …`
    func testBadTimingBodySaysLeft() {
        let b = body(decision(.badTiming, util: 91,
                              resetsAt: Date().addingTimeInterval(128 * 60 + 5)))
        XCTAssertEqual(b, "9% left with 2h 8m until reset. "
                       + "You could hit the limit before your quota refreshes.")
    }

    // Spec §4.1 event 3, three Claude cases + Codex — over quota reads `0% left` via the floor,
    // and the money clauses keep their word (spend is spent).
    // Case 1 since REV-102 §2.6 (STEP_221): credits are paying, so the banner says that and
    // stops saying "stopped" — one sentence on both plan families.
    func testOverQuotaChargingOnTheFiveHour() {
        let d = decision(.overQuota, variant: "case_1", util: 106,
                         resetsAt: Date().addingTimeInterval(45 * 60 + 5),
                         credits: 3.2, limitCents: 2000)
        XCTAssertEqual(title(d), "Claude 5-hour spent")
        XCTAssertEqual(body(d), "Now running on usage credits ($20.00 cap). "
                       + "5-hour resets in 45 min.")
    }

    /// The tester's Sunday: weekly spent, the organization's credits paying, in euros.
    func testOverQuotaChargingOnTheWeeklyInTheProvidersCurrency() {
        let d = decision(.overQuota, variant: "case_1", util: 40,
                         resetsAt: Date().addingTimeInterval(3600),
                         credits: 17.36, limitCents: 7000, currency: "EUR",
                         episode: weeklyEpisode())
        XCTAssertEqual(title(d), "Claude weekly spent")
        XCTAssertTrue(body(d).hasPrefix("Now running on usage credits (€70.00 cap). "
                                        + "Weekly resets "), body(d))
        XCTAssertTrue(body(d).contains("in 3 days"), body(d))
        XCTAssertFalse(body(d).contains("used up"), body(d))
    }

    func testOverQuotaChargingWithBothWindowsSpentNamesTheWeekly() {
        let d = decision(.overQuota, variant: "case_1", util: 100,
                         resetsAt: Date().addingTimeInterval(3600),
                         limitCents: 7000, episode: weeklyEpisode())
        XCTAssertEqual(title(d), "Claude weekly spent")
        XCTAssertTrue(body(d).contains("Weekly resets "), body(d))
    }

    func testOverQuotaChargingWithNoCapDropsTheBrackets() {
        let b = body(decision(.overQuota, variant: "case_1", util: 100,
                              resetsAt: Date().addingTimeInterval(45 * 60 + 5)))
        XCTAssertEqual(b, "Now running on usage credits. 5-hour resets in 45 min.")
    }

    /// A spent cap arrives as case 3 (`NotificationEngine.overQuotaVariant`): the block is real
    /// and the weekly copy is the one STEP_194 wrote.
    func testOverQuotaWithTheCapSpentIsAPlainWeeklyBlock() {
        let d = decision(.overQuota, variant: "case_3", util: 40,
                         resetsAt: Date().addingTimeInterval(3600),
                         credits: 70.25, limitCents: 7000, currency: "EUR",
                         episode: weeklyEpisode())
        XCTAssertEqual(title(d), "Claude stopped — weekly spent")
        XCTAssertTrue(body(d).hasPrefix("The weekly quota is used up."), body(d))
    }

    func testOverQuotaCase2PrintsTheProvidersCurrency() {
        let b = body(decision(.overQuota, variant: "case_2", util: 104,
                              resetsAt: Date().addingTimeInterval(45 * 60 + 5),
                              credits: 3.2, currency: "EUR"))
        XCTAssertTrue(b.contains("(€3.20 used earlier"), b)
    }

    func testOverQuotaCase2SaysZeroLeft() {
        let b = body(decision(.overQuota, variant: "case_2", util: 104,
                              resetsAt: Date().addingTimeInterval(45 * 60 + 5),
                              credits: 3.2))
        XCTAssertEqual(b, "0% left · credits no longer accruing ($3.20 used earlier · "
                       + "last observed). Hard block. Resets in 45 min.")
    }

    func testOverQuotaCase3SaysZeroLeft() {
        let b = body(decision(.overQuota, variant: "case_3", util: 102,
                              resetsAt: Date().addingTimeInterval(45 * 60 + 5)))
        XCTAssertEqual(b, "0% left · hard block. Resets in 45 min.")
    }

    func testOverQuotaCodexSaysZeroLeft() {
        let b = body(decision(.overQuota, tool: .codex, util: 100,
                              resetsAt: Date().addingTimeInterval(45 * 60 + 5)))
        XCTAssertEqual(b, "0% left · Codex CLI will block new requests. Resets in 45 min.")
    }

    // Spec §4.1 event 6: `Likely Claude Desktop here, claude.ai, or another computer. [X]% left ·
    // resets at [time].` (REV-81 / D-102 — replaces "Likely off-machine or another surface.")
    func testOffMachineClaudeSaysLeft() {
        let b = body(decision(.offMachineBurn, util: 87, resetsAt: Date()))
        XCTAssertTrue(b.hasPrefix("Likely Claude Desktop here, claude.ai, or another computer. "
                                  + "13% left · resets at "), b)
    }

    /// The whole point of REV-81: Desktop chat on *this* Mac writes no JSONL, so it lands in this
    /// bucket — and it is the commonest member, so the body must name it first. Pinned separately
    /// from the prefix assertion above so a later copy edit cannot quietly drop the word.
    func testOffMachineClaudeNamesDesktopFirst() {
        let b = body(decision(.offMachineBurn, util: 87, resetsAt: Date()))
        XCTAssertTrue(b.contains("Claude Desktop"), b)
        XCTAssertFalse(b.contains("off-machine"), b)
    }

    func testOffMachineCodexSaysLeft() {
        let b = body(decision(.offMachineBurn, tool: .codex, util: 87, resetsAt: Date()))
        XCTAssertTrue(b.hasPrefix("Codex is idle here. Usage likely from another machine or "
                                  + "Codex Web. 13% left · resets at "), b)
    }

    // The spike head is a delta (`+[X]% since the last check` — D-119/STEP_189, naming what the
    // rise was measured between rather than a cadence), kept by rule — but its body must not
    // carry a used-based gauge either.
    func testSpikeHeadIsDeltaNotGauge() {
        let b = body(decision(.fastBurnSpike, tool: .codex, util: 64, delta: 24))
        XCTAssertTrue(b.hasPrefix("+24% since the last check"), b)
    }

    // Multi-surface keeps the two-minute wording: it still gates on the 2-minute delta, and the
    // two notifications must not be made to lie alike (STEP_189).
    func testMultiSurfaceHeadKeepsTheTwoMinuteWording() {
        let b = body(decision(.multiSurface, tool: .codex, util: 64, delta: 12,
                              surfaces: ["Desktop", "CLI"]))
        XCTAssertTrue(b.hasPrefix("+12% in ~2 min"), b)
    }

    // DoD sweep: no body of any event, either tool, contains `% used`.
    func testNoBodyContainsPercentUsed() {
        let reset = Date().addingTimeInterval(90 * 60)
        let tools: [Tool] = [.claude, .codex]
        let events: [NotificationEventType] = [.atRisk, .badTiming, .overQuota, .fastBurnSpike,
                                               .offMachineBurn, .multiSurface, .windowResetPre,
                                               .windowResetPost, .spendControl]
        for tool in tools {
            for event in events {
                let b = body(decision(event, tool: tool, variant: "case_1", util: 87,
                                      runway: 20, resetsAt: reset, delta: 24,
                                      surfaces: ["Desktop", "CLI"], credits: 3.2,
                                      limitCents: 2000))
                XCTAssertFalse(b.contains("% used"), "\(tool)/\(event): \(b)")
            }
        }
    }

    // MARK: Multi-surface (UI Spec §4.1 event 6 — STEP_192: never name `Unknown`)

    func testMultiSurfaceBodyNamesTwoRealSurfaces() {
        let b = body(decision(.multiSurface, tool: .codex, delta: 12, surfaces: ["Desktop", "CLI"]))
        XCTAssertEqual(b, "+12% in ~2 min · Desktop + CLI both active.")
    }

    /// Three active surfaces are all named; the unnamed body survives only for a list shorter
    /// than two (unreachable from the engine, which requires two active surfaces).
    func testMultiSurfaceBodyNamesThreeAndGuardsShortLists() {
        let three = body(decision(.multiSurface, tool: .codex, delta: 12,
                                  surfaces: ["Desktop", "CLI", "IDE extension"]))
        XCTAssertEqual(three, "+12% in ~2 min · Desktop + CLI + IDE extension all active.")
        let one = body(decision(.multiSurface, tool: .codex, delta: 12, surfaces: ["Desktop"]))
        XCTAssertEqual(one, "+12% in ~2 min · multiple surfaces active.")
    }

    // MARK: Window changed (UI Spec §4.1a — STEP_146)

    private func windowChanged(_ fact: WindowFact?, tool: Tool = .codex) -> NotificationDecision {
        NotificationDecision(tool: tool, eventType: .windowChanged, windowStart: 1_756_000_000,
                             copyVariant: fact?.kind.rawValue, windowFact: fact)
    }

    /// The reported width names, never a size; a restructuring reads as what you have now.
    func testWindowChangedBodiesNameWidthsNeverSizes() {
        XCTAssertEqual(body(windowChanged(WindowFact(kind: .restructured, before: [604_800],
                                                     after: [18_000, 604_800]))),
                       "You now have a 5-hour window and a weekly window — before, weekly only.")
        XCTAssertEqual(body(windowChanged(WindowFact(kind: .added, after: [604_800]))),
                       "A weekly window was added.")
        XCTAssertEqual(body(windowChanged(WindowFact(kind: .removed, before: [18_000]))),
                       "Your 5-hour window was removed.")
        XCTAssertEqual(body(windowChanged(WindowFact(kind: .widthChanged, before: [604_800],
                                                     after: [432_000]))),
                       "Your weekly window is now 120-hour.")
        XCTAssertEqual(body(windowChanged(nil)),
                       "Your quota windows changed. See the History window.")
    }

    // MARK: REV-96 §3.8 — the block names the limit that caused it (STEP_194)

    /// "Claude quota exceeded" was true of a five-hour block and useless on a weekly one: the
    /// tester read it eleven times in three days about a week-long block, each time pointing at a
    /// five-hour reset clock that freed nothing.
    func testOverQuotaNamesTheWeeklyAndItsOwnReset() {
        let d = decision(.overQuota, util: 40, resetsAt: Date().addingTimeInterval(3600),
                         episode: weeklyEpisode())
        XCTAssertEqual(title(d), "Claude stopped — weekly spent")
        XCTAssertTrue(body(d).hasPrefix("The weekly quota is used up. Resets "), body(d))
        XCTAssertTrue(body(d).contains("in 3 days"), body(d))
    }

    /// Both windows spent: the weekly is still the subject, because it is the later reset and so
    /// the one that has to pass before work resumes.
    func testOverQuotaBothWindowsNamesWhenWorkResumes() {
        let d = decision(.overQuota, util: 100, resetsAt: Date().addingTimeInterval(3600),
                         episode: weeklyEpisode())
        XCTAssertEqual(title(d), "Claude stopped")
        XCTAssertTrue(body(d).hasPrefix("Both windows are spent. Resets "), body(d))
        XCTAssertTrue(body(d).hasSuffix(", when the weekly resets."), body(d))
    }

    /// A five-hour block keeps the copy it has always had.
    func testOverQuotaOnThePrimaryIsUnchanged() {
        let d = decision(.overQuota, util: 100, resetsAt: Date().addingTimeInterval(3600))
        XCTAssertEqual(title(d), "Claude quota exceeded")
        XCTAssertTrue(body(d).hasPrefix("0% left · hard block."), body(d))
    }

    func testSpendControlNamesTheLimitPerTool() {
        let monthly = LongLimitAssessment(
            limit: .monthly, tier: .spent, usedPct: 100, elapsedPct: 70,
            resetsAt: Date().addingTimeInterval(9 * 86_400), periodSeconds: 30 * 86_400,
            usedAmount: 7000, limitAmount: 7000, unit: .money(currency: "EUR", exponent: 2))
        let episode = BlockEpisode(tool: .claude, limit: .monthly,
                                   limitResetsAt: Date().addingTimeInterval(9 * 86_400))
        let claude = decision(.spendControl, episode: episode, longLimit: monthly)
        XCTAssertEqual(title(claude), "Claude spend limit reached")
        XCTAssertTrue(body(claude).hasPrefix("The €70.00 monthly limit is used up. Resets "),
                      body(claude))
        let codex = decision(.spendControl, tool: .codex, episode: episode)
        XCTAssertEqual(title(codex), "Codex monthly limit reached")
        XCTAssertTrue(body(codex).hasPrefix("Monthly workspace limit reached."), body(codex))
    }

    // MARK: Event 9 — Limit nearly spent (UI Spec §4.1 event 9)

    func testNearlySpentWeeklyNamesWhatIsLeftAndHowLongTheWeekHasToRun() {
        let d = decision(.limitNearlySpent, util: 36, longLimit: weekly(.nearlySpent))
        XCTAssertEqual(title(d), "Claude weekly nearly spent")
        let b = body(d)
        XCTAssertTrue(b.hasPrefix("8% of the weekly left, with 3 days until it resets "), b)
        XCTAssertTrue(b.hasSuffix("Your 5-hour window is fine."), b)
    }

    /// The reassurance is dropped when it would be false — a reader at risk on both clocks must
    /// not be told the short one is fine.
    func testNearlySpentDropsTheReassuranceWhenTheFiveHourIsAlsoHot() {
        let d = decision(.limitNearlySpent, util: 95, longLimit: weekly(.nearlySpent))
        XCTAssertFalse(body(d).contains("5-hour window is fine"), body(d))
    }

    func testNearlySpentMonthlyNamesTheAmountAndWhoCanRaiseIt() {
        let monthly = LongLimitAssessment(
            limit: .monthly, tier: .nearlySpent, usedPct: 92, elapsedPct: 67,
            resetsAt: Date().addingTimeInterval(10 * 86_400), periodSeconds: 30 * 86_400,
            usedAmount: 6454, limitAmount: 7000, unit: .money(currency: "EUR", exponent: 2))
        let claude = decision(.limitNearlySpent, util: 20, longLimit: monthly)
        XCTAssertEqual(title(claude), "Claude monthly spend nearly reached")
        XCTAssertTrue(body(claude).hasPrefix("€5.46 of the €70.00 limit left, with 10 days"),
                      body(claude))
        XCTAssertTrue(body(claude).hasSuffix("Ask your workspace admin if you need more."),
                      body(claude))

        let credits = LongLimitAssessment(
            limit: .monthly, tier: .nearlySpent, usedPct: 92, elapsedPct: 67,
            resetsAt: Date().addingTimeInterval(10 * 86_400), periodSeconds: 30 * 86_400,
            usedAmount: 3690, limitAmount: 4000, unit: .credits)
        let codex = decision(.limitNearlySpent, tool: .codex, util: 20, longLimit: credits)
        XCTAssertEqual(title(codex), "Codex monthly limit nearly reached")
        XCTAssertTrue(body(codex).hasPrefix("310 of 4,000 credits left, with 10 days"), body(codex))
        XCTAssertTrue(
            body(codex).hasSuffix("You can request a limit increase from ChatGPT settings → Usage."),
            body(codex))
    }

    /// No assessment ⇒ no invented figure.
    func testNearlySpentWithoutAnAssessmentSaysOnlyWhatItKnows() {
        XCTAssertEqual(body(decision(.limitNearlySpent)), "A limit is nearly spent.")
    }

    /// REV-106 §2.4 (STEP_233): a seven-day primary is the account's weekly. It takes the
    /// weekly title and body, and never the five-hour reassurance — there is no five-hour window.
    func testNearlySpentOnAWeeklyOnlyAccountHasNoFiveHourSentence() {
        let only = LongLimitAssessment(limit: .primary, tier: .nearlySpent, usedPct: 92,
                                       elapsedPct: 50,
                                       resetsAt: Date().addingTimeInterval(3 * 86_400),
                                       periodSeconds: 7 * 86_400)
        // Even with a calm utilization on the decision, the sentence must not appear.
        for util in [92.0, 10.0] {
            let d = decision(.limitNearlySpent, tool: .codex, util: util, longLimit: only)
            XCTAssertEqual(title(d), "Codex weekly nearly spent")
            let b = body(d)
            XCTAssertTrue(b.hasPrefix("8% of the weekly left, with 3 days until it resets "), b)
            XCTAssertFalse(b.contains("5-hour"), b)
        }
    }

    // MARK: Event 10 — Limit ahead of pace (UI Spec §4.1 event 10, REV-106 §2.5 — STEP_233)

    /// Sunday 4 Oct 2026, 8:45 pm **local** — built from calendar components so the fixture
    /// reads `Sun 8:45 pm` in whatever time zone runs it.
    private var sundayReset: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 4,
                                                   hour: 20, minute: 45))!
    }

    /// A weekly `daysLeft` from its reset, `used` percent gone, on either kind of account.
    private func ladderDecision(_ step: String, tool: Tool, limit: BlockEpisode.Limit,
                                used: Double, daysLeft: Double)
        -> (NotificationDecision, now: Date) {
        let weekly = LongLimitAssessment(limit: limit, tier: .aheadOfPace, usedPct: used,
                                         elapsedPct: (7 - daysLeft) / 7 * 100,
                                         resetsAt: sundayReset, periodSeconds: 7 * 86_400)
        return (decision(.limitAheadOfPace, tool: tool, variant: step, util: 20,
                         longLimit: weekly),
                sundayReset.addingTimeInterval(-daysLeft * 86_400))
    }

    private func ladderBody(_ pair: (NotificationDecision, now: Date)) -> String {
        UserNotificationPresenter.aheadOfPaceBody(pair.0, now: pair.now)
    }

    func testHalfStepCopyOnBothTools() {
        for (tool, limit) in [(Tool.claude, BlockEpisode.Limit.secondary), (.codex, .primary)] {
            let half = ladderDecision("half", tool: tool, limit: limit, used: 52, daysLeft: 4)
            XCTAssertEqual(title(half.0), "\(tool.tabLabel) weekly won't last at this pace")
            XCTAssertEqual(ladderBody(half),
                "48% left with 4 days until it resets Sun 8:45 pm. "
                + "That is about 12% a day; this week has averaged 17% a day.")
        }
    }

    func testQuarterStepCopyOnBothTools() {
        for (tool, limit) in [(Tool.claude, BlockEpisode.Limit.secondary), (.codex, .primary)] {
            let quarter = ladderDecision("quarter", tool: tool, limit: limit, used: 76, daysLeft: 3)
            XCTAssertEqual(title(quarter.0), "\(tool.tabLabel) weekly: a quarter left")
            XCTAssertEqual(ladderBody(quarter),
                "24% left with 3 days until it resets Sun 8:45 pm. "
                + "That is about 8% a day; this week has averaged 19% a day.")
        }
    }

    /// The owner's 20 Aug week went 4 → 77 % in its first four hours. "Averaged over 500 % a
    /// day" is not a sentence, so the clause waits for one full day of the week.
    func testTheAverageIsDroppedInTheWeeksFirstDay() {
        let early = ladderDecision("quarter", tool: .codex, limit: .primary, used: 77,
                                   daysLeft: 7 - 4.0 / 24)
        XCTAssertEqual(ladderBody(early),
            "23% left with 7 days until it resets Sun 8:45 pm. That is about 3% a day.")
        let dayOne = ladderDecision("half", tool: .codex, limit: .primary, used: 60, daysLeft: 6)
        XCTAssertTrue(ladderBody(dayOne).hasSuffix("this week has averaged 60% a day."),
                      ladderBody(dayOne))
    }

    /// Under the D-59 day band the countdown is hours and minutes, and the budget divides by
    /// the true 1.2 days, not by a rounded one.
    func testTheBudgetOnAWeekWithALittleOverADayLeft() {
        let late = ladderDecision("quarter", tool: .claude, limit: .secondary, used: 88,
                                  daysLeft: 1.2)
        XCTAssertEqual(ladderBody(late),
            "12% left with 28h 48m until it resets Sun 8:45 pm. "
            + "That is about 10% a day; this week has averaged 15% a day.")
    }

    /// Through the ordinary entry point: no project suffix (the weekly is account-level) and
    /// no five-hour tail, on a decision that carries both a project and a calm five-hour.
    func testAheadOfPaceBodyIsAccountLevelAndSaysOneThing() {
        let weekly = LongLimitAssessment(limit: .secondary, tier: .aheadOfPace, usedPct: 55,
                                         elapsedPct: 40,
                                         resetsAt: Date().addingTimeInterval(4.2 * 86_400),
                                         periodSeconds: 7 * 86_400)
        let d = NotificationDecision(tool: .claude, eventType: .limitAheadOfPace,
                                     windowStart: 1_756_000_000, copyVariant: "half",
                                     utilizationPct: 20, project: "/Users/x/kvotar",
                                     longLimit: weekly)
        let b = UserNotificationPresenter.body(for: d, includeProject: true)
        XCTAssertTrue(b.hasPrefix("45% left with 5 days until it resets "), b)
        XCTAssertFalse(b.contains("Project:"), b)
        XCTAssertFalse(b.contains("5-hour"), b)
    }

    /// No assessment ⇒ no invented figure, as for event 9.
    func testAheadOfPaceWithoutAnAssessmentSaysOnlyWhatItKnows() {
        XCTAssertEqual(body(decision(.limitAheadOfPace, variant: "half")),
                       "The weekly is running ahead of pace.")
    }

    /// The copy sweeps over every string this step added: "resets", never "back" (§4.1); no
    /// run-out date or clock; no polling internal (§9.1/§10); no retired product name.
    func testTheLadderCopyPassesTheStandingSweeps() {
        var strings: [String] = []
        for (tool, limit) in [(Tool.claude, BlockEpisode.Limit.secondary), (.codex, .primary)] {
            for (step, used, days) in [("half", 52.0, 4.0), ("quarter", 76.0, 3.0),
                                       ("quarter", 77.0, 6.9)] {
                let pair = ladderDecision(step, tool: tool, limit: limit, used: used,
                                          daysLeft: days)
                strings += [title(pair.0), ladderBody(pair)]
            }
            let red = LongLimitAssessment(limit: limit, tier: .nearlySpent, usedPct: 92,
                                          elapsedPct: 50,
                                          resetsAt: Date().addingTimeInterval(3 * 86_400),
                                          periodSeconds: 7 * 86_400)
            let d = decision(.limitNearlySpent, tool: tool, util: 95, longLimit: red)
            strings += [title(d), body(d)]
        }
        for text in strings {
            let word = UserCopyRules.pollingWord(in: text)
            XCTAssertNil(word, "\(word ?? "") in: \(text)")
            let lower = text.lowercased()
            for banned in ["agentpilot", " back", "runs out", "stops", "% used"] {
                XCTAssertFalse(lower.contains(banned), "\(banned) in: \(text)")
            }
        }
    }

    // MARK: The hidden-item notice (REV-99 §2.7 — STEP_206)

    /// Copy fixture, verbatim. **"May be hidden", not "is hidden"** — the hedge is load-bearing:
    /// Spike E ran on one notched Mac with one built-in display, so the copy describes a symptom
    /// the reader can check in one glance and never asserts a cause. It names no macOS mechanism,
    /// no API and no polling internal (§9.1/§10).
    func testTheHiddenItemNoticeSaysMayBeHidden() {
        XCTAssertEqual(UserNotificationPresenter.hiddenItemNoticeTitle, "Kvotar is running")
        XCTAssertEqual(UserNotificationPresenter.hiddenItemNoticeBody,
                       "Its menu bar item may be hidden. Open Kvotar to see your quota.")
        XCTAssertNil(UserCopyRules.pollingWord(in: UserNotificationPresenter.hiddenItemNoticeBody))
        for banned in ["occlusion", "menu bar is full"] {
            XCTAssertFalse(UserNotificationPresenter.hiddenItemNoticeBody.lowercased()
                .contains(banned), banned)
        }
    }

    /// It is **not one of the nine**: its own identifier, so it never replaces a quota banner in
    /// place, and its own marker instead of a `(tool, event)` pair — the pair `onAcknowledge` arms
    /// the at-risk re-arm path from.
    func testTheHiddenItemNoticeIsNotAnEngineEvent() {
        XCTAssertNotEqual(UserNotificationPresenter.hiddenItemNoticeID,
                          decision(.atRisk).stableRequestID)
        XCTAssertNil(NotificationEventType(rawValue: UserNotificationPresenter.hiddenItemNoticeValue))
    }

    // MARK: Sound (UI Spec §4.2 — D-126, STEP_224)

    /// Every event type has a pinned answer, so a new case cannot slip in audible or silent by
    /// accident: adding one fails this test until the spec row names it.
    func testEveryEventTypeHasAPinnedSoundAnswer() {
        let audible: Set<NotificationEventType> =
            [.atRisk, .badTiming, .overQuota, .spendControl, .limitNearlySpent]
        let silent: Set<NotificationEventType> =
            [.fastBurnSpike, .offMachineBurn, .multiSurface,
             .windowResetPre, .windowResetPost, .windowChanged,
             // REV-106 §2.7: half a week left is neither "about to be stopped" nor "just were".
             .limitAheadOfPace]
        XCTAssertTrue(audible.isDisjoint(with: silent))
        XCTAssertEqual(audible.union(silent), Set(NotificationEventType.allCases))
        for e in audible { XCTAssertTrue(UserNotificationPresenter.isAudible(e), e.rawValue) }
        for e in silent { XCTAssertFalse(UserNotificationPresenter.isAudible(e), e.rawValue) }
    }

    // MARK: Withdrawal at window reset (D-128, STEP_226)

    func testNoticesAboutTheEndedWindowAreWithdrawn() {
        for e: NotificationEventType in [.atRisk, .badTiming, .fastBurnSpike, .offMachineBurn,
                                         .multiSurface, .windowResetPre] {
            XCTAssertTrue(UserNotificationPresenter.withdrawsAtReset(decision(e)), e.rawValue)
        }
    }

    func testLongLimitsAndNewsAreKept() {
        for e: NotificationEventType in [.spendControl, .limitNearlySpent, .limitAheadOfPace,
                                         .windowResetPost, .windowChanged] {
            XCTAssertFalse(UserNotificationPresenter.withdrawsAtReset(decision(e)), e.rawValue)
        }
    }

    /// A five-hour block goes with its window; a weekly block outlives the rollover.
    func testOverQuotaFollowsItsBlockingLimit() {
        XCTAssertTrue(UserNotificationPresenter.withdrawsAtReset(decision(.overQuota)))
        XCTAssertTrue(UserNotificationPresenter.withdrawsAtReset(decision(.overQuota,
            episode: BlockEpisode(tool: .claude, limit: .primary, limitResetsAt: Date()))))
        XCTAssertFalse(UserNotificationPresenter.withdrawsAtReset(decision(.overQuota,
            episode: weeklyEpisode())))
    }
}
