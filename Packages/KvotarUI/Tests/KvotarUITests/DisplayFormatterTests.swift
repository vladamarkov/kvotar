import XCTest
import KvotarCore
@testable import KvotarUI

final class DisplayFormatterTests: XCTestCase {

    // MARK: Helpers

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(tool: Tool = .claude, used: Double? = 38, resetsInMin: Double? = 120,
                          windowSeconds: Int? = nil,
                          secondary: Double? = 14, reached: Bool? = false,
                          email: String? = "user@example.com", plan: String? = "Pro",
                          extraUsage: ExtraUsage? = .disabled,
                          prepaid: PrepaidCredits? = nil) -> QuotaSnapshot {
        QuotaSnapshot(
            tool: tool,
            primaryUsedPct: used,
            primaryResetsAt: resetsInMin.map { now.addingTimeInterval($0 * 60) },
            primaryWindowSeconds: windowSeconds,
            secondaryUsedPct: secondary,
            secondaryResetsAt: secondary.map { _ in now.addingTimeInterval(3 * 86400) },
            rateLimitReached: reached,
            extraUsage: extraUsage,
            prepaid: prepaid,
            email: email,
            planType: plan)
    }

    private func forecast(tool: Tool = .claude, runway: Double? = nil,
                          burn: Double? = 0.4) -> Forecast {
        Forecast(tool: tool, tier: .fullRunway, runwayMinutes: runway,
                 burnRatePerMin: burn, isEstimate: false, pollCount: 5)
    }

    // MARK: dot / phase

    func testDotMapping() {
        XCTAssertEqual(DisplayFormatter.dot(for: .healthy), .green)
        XCTAssertEqual(DisplayFormatter.dot(for: .elevated), .amber)
        XCTAssertEqual(DisplayFormatter.dot(for: .fastBurnSpike), .amber)
        XCTAssertEqual(DisplayFormatter.dot(for: .atRisk), .red)
        XCTAssertEqual(DisplayFormatter.dot(for: .overQuota), .red)
        XCTAssertEqual(DisplayFormatter.dot(for: .spendControl), .red)
        XCTAssertEqual(DisplayFormatter.dot(for: .nullWindow), .neutral)
        XCTAssertEqual(DisplayFormatter.dot(for: .idleFallback), .grey)
    }

    func testPhaseMapping() {
        XCTAssertEqual(DisplayFormatter.phase(for: .idleFallback), .idle)
        XCTAssertEqual(DisplayFormatter.phase(for: .healthy), .content)
        XCTAssertEqual(DisplayFormatter.phase(for: .nullWindow), .content)
    }

    // MARK: Menu bar

    func testMenuBarLoading() {
        let m = DisplayFormatter.loadingMenuBar(.claude)
        XCTAssertEqual(m.prefix, "CL")
        XCTAssertEqual(m.percentText, "…")
        XCTAssertNil(m.timeSlot)
        XCTAssertEqual(m.dot, .grey)
    }

    func testMenuBarIdle() {
        let m = DisplayFormatter.toolMenuBar(tool: .codex, state: .idleFallback,
                                             snapshot: nil, forecast: nil, now: now)
        XCTAssertEqual(m.prefix, "CX")
        XCTAssertEqual(m.percentText, "––")
        XCTAssertEqual(m.timeSlot, "est")
        XCTAssertEqual(m.dot, .grey)
    }

    func testMenuBarNullWindow() {
        let m = DisplayFormatter.toolMenuBar(tool: .codex, state: .nullWindow,
                                             snapshot: snapshot(tool: .codex, used: nil, secondary: nil),
                                             forecast: forecast(tool: .codex, burn: nil), now: now)
        XCTAssertEqual(m.percentText, "——")
        XCTAssertEqual(m.timeSlot, "est")
        XCTAssertEqual(m.dot, .neutral)
    }

    func testMenuBarHealthyShowsResetSlot() {
        // No runway → reset countdown. 120 min away → "↻2h00m".
        let m = DisplayFormatter.toolMenuBar(tool: .claude, state: .healthy,
                                             snapshot: snapshot(), forecast: forecast(), now: now)
        XCTAssertEqual(m.percentText, "62%", "remaining — the number says what's left (D-97)")
        XCTAssertEqual(m.timeSlot, "↻2h00m")
        XCTAssertEqual(m.dot, .green)
    }

    func testMenuBarShowsRunwayWhenUnder60AndBeforeReset() {
        // runway 20m, reset 120m away, 68% used against 60% elapsed → exhaustion → "◔~20m".
        let m = DisplayFormatter.toolMenuBar(tool: .claude, state: .elevated,
                                             snapshot: snapshot(used: 68), forecast: forecast(runway: 20),
                                             now: now)
        XCTAssertEqual(m.timeSlot, "◔~20m")
    }

    func testMenuBarHidesRunwayWhenOver60() {
        // Every other condition met (68% against 60% elapsed, reset 120m out) — the bar's own
        // 60-minute urgency threshold is the only thing keeping the slot off (§1.3).
        let m = DisplayFormatter.toolMenuBar(tool: .claude, state: .elevated,
                                             snapshot: snapshot(used: 68), forecast: forecast(runway: 90),
                                             now: now)
        XCTAssertEqual(m.timeSlot, "↻2h00m")
    }

    func testMenuBarHidesRunwayWhenResetIsSooner() {
        // runway 30m but reset only 20m away → reset comes first → show reset. Used 95% against
        // 93% elapsed so the pace clock fires: the reset comparison is what decides this one.
        let m = DisplayFormatter.toolMenuBar(tool: .claude, state: .elevated,
                                             snapshot: snapshot(used: 95, resetsInMin: 20),
                                             forecast: forecast(runway: 30),
                                             now: now)
        XCTAssertEqual(m.timeSlot, "↻20m")
    }

    func testMenuBarShowsRunwayWhenLocalIdle() {
        // D-113 (STEP_172) — was `testMenuBarHidesRunwayWhenLocalIdle`. §1.3 condition 1
        // ("tokens flowing in JSONL", STEP_27) is retired: identical inputs to the test above,
        // and the bar now carries the same estimate the popover verdict does. Local silence is
        // not evidence that the account stopped spending. The anti-jitter job the condition was
        // doing belongs to the pace clock, which STEP_27 predates.
        let m = DisplayFormatter.toolMenuBar(tool: .claude, state: .elevated,
                                             snapshot: snapshot(used: 68), forecast: forecast(runway: 20),
                                             now: now)
        XCTAssertEqual(m.timeSlot, "◔~20m")
    }

    func testMenuBarHidesRunwayWhenPaceClockQuiet() {
        // 38% used against 60% elapsed — under budget, so no exhaustion claim on either surface
        // even with a 20-minute runway (REV-65/D-69).
        let m = DisplayFormatter.toolMenuBar(tool: .claude, state: .elevated,
                                             snapshot: snapshot(used: 38), forecast: forecast(runway: 20),
                                             now: now)
        XCTAssertEqual(m.timeSlot, "↻2h00m")
    }

    func testMenuBarHidesRunwayWhenRunwayNotPositive() {
        // A spent or absent runway is not an urgent estimate — it is no estimate (D-113 aligned
        // the bar with the verdict, which has always required a positive runway).
        for runway in [nil, -5, 0] as [Double?] {
            let m = DisplayFormatter.toolMenuBar(tool: .claude, state: .elevated,
                                                 snapshot: snapshot(used: 68),
                                                 forecast: forecast(runway: runway), now: now)
            XCTAssertEqual(m.timeSlot, "↻2h00m", "runway \(String(describing: runway))")
        }
    }

    func testMenuBarHidesRunwayWhenResetUnknown() {
        // §1.3 condition 2 (STEP_27): "exhaustion before reset" cannot be confirmed without a
        // known reset time → percent-only slot, no fabricated runway.
        let m = DisplayFormatter.toolMenuBar(tool: .claude, state: .elevated,
                                             snapshot: snapshot(resetsInMin: nil),
                                             forecast: forecast(runway: 20),
                                             now: now)
        XCTAssertNil(m.timeSlot)
    }

    // MARK: Claude popover

    func testClaudeContentHeaderAndQuota() {
        let c = DisplayFormatter.claude(state: .healthy, snapshot: snapshot(),
                                        forecast: forecast(), now: now)
        XCTAssertEqual(c.phase, .content)
        XCTAssertEqual(c.dot, .green)
        XCTAssertEqual(c.header?.heroText, "62%", "38 used → 62 left (REV-77 / D-97)")
        XCTAssertEqual(c.header?.progress ?? -1, 0.62, accuracy: 0.001, "the bar drains with it")
        XCTAssertEqual(c.header?.email, "user@example.com")
        XCTAssertEqual(c.header?.planBadge, "Pro")
        // The hero is the primary window, and its caption names it (STEP_178).
        XCTAssertEqual(c.header?.limitCaption, "5-hour quota left")
        XCTAssertEqual(c.header?.limit?.id, .primaryWindow)
        // The weekly is listed once, in `OTHER LIMITS`.
        XCTAssertEqual(c.otherLimits?.rows.map(\.id), [.secondaryWindow])
        // The local section is present with nothing observed rather than absent — a missing
        // section must read as a bug, not as "no data".
        XCTAssertEqual(c.localActivity?.availability, .loading)
        XCTAssertNil(c.recommendation)         // healthy → no warning copy
    }

    // MARK: Local session / credits (Step 22)

    private func attribution(
        project: String? = "/Users/u/kvotar", model: String? = "claude-sonnet-4-6",
        surface: String? = "Claude Code", subagents: Int = 0, cacheHit: Double? = 0.71,
        shares: [SurfaceShare] = [], tokPerMin: Double? = 350, lastActivity: Date? = nil,
        value: EstimatedValueEngine.WindowValue = .init(weekly: 8.20, thirtyDay: 3.97),
        sessionCount: Int = 3, windowValue: Double = 0.40,
        // REV-44 §2.5a per-model totals — opus 980k, haiku 240k (order deliberately not descending
        // in the input, so the formatter's sort is exercised).
        modelTotals: [SQLiteStore.ModelTokenTotals] = [
            .init(model: "claude-haiku-4-5", inputTokens: 40_000, outputTokens: 20_000,
                  cacheCreationTokens: 100_000, cacheReadTokens: 80_000),   // 240k
            .init(model: "claude-opus-4-8", inputTokens: 200_000, outputTokens: 80_000,
                  cacheCreationTokens: 400_000, cacheReadTokens: 300_000),  // 980k
        ]
    ) -> LocalAttribution {
        // REV-23: liveness is a recency gap on `lastActivityAt`. By default track `tokPerMin` (the
        // pre-REV-23 active signal) so existing expectations hold — a non-nil rate ⇒ recent activity;
        // nil ⇒ no activity. Pass `lastActivity` explicitly to decouple them (the long-turn case:
        // recent activity with a momentarily-nil rate).
        let activity = lastActivity ?? (tokPerMin != nil ? Date() : nil)
        return LocalAttribution(project: project, model: model, surfaceBucket: surface,
                                subagentCount: subagents, cacheHitRatio: cacheHit, estValue: value,
                                surfaceShares: shares, tokensPerMinute: tokPerMin,
                                lastActivityAt: activity, sessionCount: sessionCount,
                                modelTotals: modelTotals, windowValue: windowValue)
    }

    /// The Enterprise credits/spend card survives the STEP_178 cutover unchanged — it is one of
    /// the "applicable credits controls" §REV92 keeps.
    func testCodexEnterpriseCreditsCard() {
        let shares = [SurfaceShare(label: "Desktop", fraction: 0.82), SurfaceShare(label: "CLI", fraction: 0.18)]
        let attr = attribution(project: "/repo", model: "gpt-5.5", surface: "Desktop",
                               cacheHit: nil, shares: shares, tokPerMin: nil)
        let cx = DisplayFormatter.codex(state: .healthy, snapshot: snapshot(tool: .codex, plan: "enterprise"),
                                        forecast: forecast(tool: .codex), localAttribution: attr, now: now)
        let credits = try! XCTUnwrap(cx.creditsSpend)
        XCTAssertEqual(credits.rows.first?.label, "Plan")
        XCTAssertEqual(credits.rows.first?.value, "Enterprise")   // §0.4 display mapping (STEP_27)
        // §2.4 (STEP_27): Credit balance row always present — "unavailable" when null (D1).
        XCTAssertTrue(credits.rows.contains { $0.label == "Credit balance" && $0.value == "unavailable" })
        // Est. token value today + 30-day rows carry the " est." suffix (§2.4).
        XCTAssertTrue(credits.rows.contains { $0.label == "Est. token value · today" })
        XCTAssertTrue(credits.rows.contains { $0.label == "Est. token value · 30-day" && $0.value.hasSuffix(" est.") })
    }

    func testCodexNonEnterpriseHasNoCreditsSection() {
        let cx = DisplayFormatter.codex(state: .healthy, snapshot: snapshot(tool: .codex, plan: "Plus"),
                                        forecast: forecast(tool: .codex),
                                        localAttribution: attribution(cacheHit: nil), now: now)
        XCTAssertNil(cx.creditsSpend)
    }

    func testClaudeIdlePhase() {
        let c = DisplayFormatter.claude(state: .idleFallback, snapshot: nil, forecast: nil, now: now)
        XCTAssertEqual(c.phase, .idle)
        XCTAssertEqual(c.dot, .grey)
        XCTAssertNil(c.header)
    }

    func testClaudeAtRiskHasRecommendation() {
        let c = DisplayFormatter.claude(state: .atRisk, snapshot: snapshot(used: 87),
                                        forecast: forecast(runway: 11), now: now)
        XCTAssertEqual(c.dot, .red)
        XCTAssertNotNil(c.recommendation)
    }

    // MARK: Usage-credits card (§2.4a) + money glyph (§1.6) — REV-29

    /// `used_credits` is dollars (`3.20` → $3.20), `monthly_limit` cents.
    private func extra(enabled: Bool, used: Decimal? = 3.20, limit: Int? = 2000,
                       currency: String? = "usd", cached: Bool = false,
                       disabledReason: String? = nil) -> ExtraUsage {
        ExtraUsage(isEnabled: enabled, monthlyLimit: limit, usedCredits: used,
                   utilization: nil, currency: currency, disabledReason: disabledReason,
                   usedCreditsIsCached: cached)
    }

    private func card(used: Double?, extra: ExtraUsage?, prepaid: PrepaidCredits? = nil,
                      resetsInMin: Double? = 120, burn: Double? = 0.4) -> CreditsCardSection? {
        DisplayFormatter.claude(
            state: .healthy,
            snapshot: snapshot(used: used, resetsInMin: resetsInMin, extraUsage: extra, prepaid: prepaid),
            forecast: forecast(burn: burn), now: now).creditsCard
    }

    /// Fixture 1 — armed, no spend: on, <100, $0.00 of $Y names the headroom, status neutral.
    func testCardArmedNoSpend() throws {
        let c = try XCTUnwrap(card(used: 40, extra: extra(enabled: true, used: 0)))
        XCTAssertEqual(c.moneyState, .armed)
        XCTAssertEqual(c.status.value, "On · not charging")
        XCTAssertEqual(c.status.dot, .neutral)
        XCTAssertTrue(c.rows.contains { $0.value == "$0.00 of $20.00" })
    }

    /// Fixture 2 — armed, spent: shows "$X of $Y".
    func testCardArmedSpent() throws {
        let c = try XCTUnwrap(card(used: 62, extra: extra(enabled: true)))
        XCTAssertEqual(c.moneyState, .armed)
        XCTAssertTrue(c.rows.contains { $0.value == "$3.20 of $20.00" })
    }

    /// Fixture 3 — charging: on, ≥100 → red status + red This-month value.
    func testCardCharging() throws {
        let c = try XCTUnwrap(card(used: 100, extra: extra(enabled: true)))
        XCTAssertEqual(c.moneyState, .charging)
        XCTAssertEqual(c.status.value, "On · charging")
        XCTAssertEqual(c.status.dot, .red)
        XCTAssertEqual(c.rows.first { $0.label == "This month" }?.dot, .red)
    }

    /// Fixture 4 — charging + auto-reload + prepaid balance.
    func testCardChargingAutoReload() throws {
        let p = PrepaidCredits(amountCents: 3024, autoReloadOn: true, asOf: now)
        let c = try XCTUnwrap(card(used: 100, extra: extra(enabled: true), prepaid: p))
        XCTAssertEqual(c.moneyState, .charging)
        XCTAssertEqual(c.rows.first { $0.label == "Auto-reload" }?.value, "On")
        XCTAssertEqual(c.rows.first { $0.label == "Auto-reload" }?.dot, .amber)
        XCTAssertEqual(c.rows.first { $0.label == "Prepaid balance" }?.value, "$30.24")
    }

    // MARK: Provider currency (REV-102 §2.5 — STEP_219)

    /// The Team tester's card: org-paid credits in euros, as STEP_218 maps them.
    func testCardRendersTheProvidersCurrency() throws {
        let team = ExtraUsage(isEnabled: true, monthlyLimit: 7000, usedCredits: 16.8,
                              currency: "EUR", managedByOrganization: true, currencyExponent: 2)
        let c = try XCTUnwrap(card(used: 40, extra: team))
        // STEP_220: the org-managed figure carries the month's reset.
        XCTAssertEqual(c.rows.first { $0.label == "This month" }?.value.hasPrefix(
            "€16.80 of €70.00 · resets "), true)

        // A Pro/Max account billed in euros — the latent `$` bug this step closes.
        let proMax = ExtraUsage(isEnabled: true, monthlyLimit: 2000,
                                usedCredits: Decimal(string: "3.2"), currency: "EUR")
        let p = PrepaidCredits(amountCents: 3024, autoReloadOn: false, asOf: now, currency: "EUR")
        let euro = try XCTUnwrap(card(used: 40, extra: proMax, prepaid: p))
        XCTAssertEqual(euro.rows.first { $0.label == "This month" }?.value, "€3.20 of €20.00")
        XCTAssertEqual(euro.rows.first { $0.label == "Prepaid balance" }?.value, "€30.24")
    }

    /// The wallet's own currency wins; without one it follows the credits'. No symbol ⇒ ISO code.
    func testPrepaidBalanceCurrencyFallsBackToTheCredits() throws {
        let francs = ExtraUsage(isEnabled: true, monthlyLimit: 2000, usedCredits: 1, currency: "CHF")
        let bare = PrepaidCredits(amountCents: 3024, autoReloadOn: false, asOf: now)
        let c = try XCTUnwrap(card(used: 40, extra: francs, prepaid: bare))
        XCTAssertEqual(c.rows.first { $0.label == "Prepaid balance" }?.value, "30.24 CHF")
        XCTAssertEqual(c.rows.first { $0.label == "This month" }?.value, "1.00 CHF of 20.00 CHF")
    }

    /// Owner ruling 2026-09-21: one thousands rule. Below 1,000 Pro/Max is byte-identical to the
    /// old `$%.2f`; above it the credits card gains the comma the Monthly section always had.
    func testCreditsCardGroupsThousands() throws {
        let big = ExtraUsage(isEnabled: true, monthlyLimit: 250_000,
                             usedCredits: Decimal(string: "1234.56"), currency: "USD")
        let c = try XCTUnwrap(card(used: 40, extra: big))
        XCTAssertEqual(c.rows.first { $0.label == "This month" }?.value, "$1,234.56 of $2,500.00")
    }

    /// The §1.6 glyph is the account's currency symbol on both surfaces that draw it.
    func testMoneyGlyphIsTheAccountsCurrencySymbol() {
        func symbols(_ currency: String?) -> (bar: String, verdict: String?) {
            let extra = ExtraUsage(isEnabled: true, monthlyLimit: 2000, usedCredits: 3,
                                   currency: currency)
            let snap = snapshot(used: 106, resetsInMin: 48, extraUsage: extra)
            let bar = DisplayFormatter.toolMenuBar(tool: .claude, state: .overQuota, snapshot: snap,
                                                   forecast: forecast(burn: 0.4),
                                                   glyph: .charging, now: now)
            let verdict = DisplayFormatter.headerVerdict(tool: .claude, state: .overQuota,
                                                         snapshot: snap,
                                                         forecast: forecast(burn: 0.4), now: now)
            return (bar.moneySymbol, verdict?.moneySymbol)
        }
        XCTAssertEqual(symbols("EUR").bar, "€")
        XCTAssertEqual(symbols("EUR").verdict, "€")
        XCTAssertEqual(symbols("GBP").bar, "£")
        XCTAssertEqual(symbols("CHF").bar, "$", "no symbol of its own keeps the `$`")
        XCTAssertEqual(symbols(nil).bar, "$")
        XCTAssertEqual(symbols(nil).verdict, "$")
    }

    /// Fixture 5 — no-backstop, calm: off, <100, not imminent → "Off", muted hard-block sub-line.
    func testCardNoBackstopCalm() throws {
        let c = try XCTUnwrap(card(used: 40, extra: .disabled, burn: 0.01))
        XCTAssertEqual(c.moneyState, .noBackstop)
        XCTAssertEqual(c.status.value, "Off")
        XCTAssertEqual(c.status.dot, .neutral)
        XCTAssertEqual(c.subLine, "Hard-block at 100% — usage credits are off")
        XCTAssertEqual(c.subLineSeverity, .info)
        XCTAssertFalse(c.rows.contains { $0.label == "This month" })   // no spend row when off
        // STEP_35 — the card always exposes the "Manage in Claude web" link target.
        XCTAssertEqual(c.manageURL, URL(string: "https://claude.ai/new#settings/usage"))
    }

    /// Fixture 6 — no-backstop, imminent: off, eta<reset → amber status + "Blocks in ~" sub-line,
    /// and NO glyph (a block is not a charge).
    func testCardNoBackstopImminent() throws {
        let c = try XCTUnwrap(card(used: 90, extra: .disabled, burn: 1.0))
        XCTAssertEqual(c.moneyState, .noBackstop)
        XCTAssertEqual(c.status.dot, .amber)
        XCTAssertTrue(c.subLine?.hasPrefix("Blocks in ~") ?? false)
        XCTAssertEqual(c.subLineSeverity, .warning)
        // §1.6: off credits never light the glyph.
        let glyph = MoneyModel.moneyGlyphInstant(
            snapshot: snapshot(used: 90, extraUsage: .disabled), forecast: forecast(burn: 1.0), now: now)
        XCTAssertEqual(glyph, MoneyGlyph.none)
    }

    /// Fixture 7 — last observed: off, cached used>0 → "was on earlier", "$X (last observed)".
    func testCardLastObserved() throws {
        let c = try XCTUnwrap(card(used: 100, extra: extra(enabled: false, cached: true)))
        XCTAssertEqual(c.moneyState, .lastObserved)
        XCTAssertEqual(c.status.value, "Off · was on earlier this window")
        XCTAssertTrue(c.rows.contains { $0.value == "$3.20 (last observed)" })
    }

    /// Fixture 8 — disabled_reason passed through raw (P2-3: never switched on). Shown in the
    /// BLOCKED state (off, ≥100); for a NO-BACKSTOP account (off, <100) the backstop line wins.
    func testCardDisabledReason() throws {
        let c = try XCTUnwrap(card(used: 106, extra: extra(enabled: false, used: 0,
                                                           disabledReason: "payment_failed")))
        XCTAssertEqual(c.moneyState, .blocked)
        XCTAssertEqual(c.subLine, "Off: payment_failed")
    }

    /// Fixture 9 — Enterprise: no extra_usage object → card absent entirely (not empty).
    func testCardEnterpriseSuppressed() {
        let c = DisplayFormatter.claude(state: .healthy,
                                        snapshot: snapshot(used: 40, extraUsage: nil),
                                        forecast: forecast(), now: now)
        XCTAssertNil(c.creditsCard)
    }

    /// Fixture 10 — prepaid call absent: extra_usage rows intact, balance/auto-reload rows absent,
    /// single Claude-account source stamp (no dual "Balance/reload" leg).
    func testCardPrepaidCallAbsent() throws {
        let c = try XCTUnwrap(card(used: 62, extra: extra(enabled: true), prepaid: nil))
        XCTAssertTrue(c.rows.contains { $0.label == "This month" })
        XCTAssertFalse(c.rows.contains { $0.label == "Auto-reload" })
        XCTAssertFalse(c.rows.contains { $0.label == "Prepaid balance" })
        XCTAssertFalse(c.sourceTag.base.contains("Balance/reload"))
    }

    /// D-08 retired: the header no longer carries any extra-usage alert row; the badge still goes
    /// blue while on credits, and the credit-aware recommendation still suppresses "avoid heavy".
    func testHeaderAlertRetiredButCreditAwarenessRemains() {
        let c = DisplayFormatter.claude(
            state: .badTiming, snapshot: snapshot(used: 100, extraUsage: extra(enabled: true)),
            forecast: forecast(), now: now)
        XCTAssertEqual(c.header?.badgeKind, .credit)
        XCTAssertTrue(c.recommendation?.contains("usage credits") ?? false)
        XCTAssertFalse(c.recommendation?.contains("you risk hitting the limit") ?? true)
    }

    // MARK: Money glyph (§1.6) in the menu bar

    private func glyph(used: Double?, extra: ExtraUsage?, burn: Double?, resetsInMin: Double? = 120)
        -> MoneyGlyph {
        MoneyModel.moneyGlyphInstant(
            snapshot: snapshot(used: used, resetsInMin: resetsInMin, extraUsage: extra),
            forecast: forecast(burn: burn), now: now)
    }

    func testGlyphFourStates() {
        XCTAssertEqual(glyph(used: 85, extra: extra(enabled: true), burn: 0.01), MoneyGlyph.none)   // coast
        XCTAssertEqual(glyph(used: 90, extra: extra(enabled: true), burn: 1.0), .armed)             // eta<reset
        XCTAssertEqual(glyph(used: 100, extra: extra(enabled: true), burn: 1.0), .charging)         // ≥100
        XCTAssertEqual(glyph(used: 95, extra: .disabled, burn: 5.0), MoneyGlyph.none)               // off → block
    }

    /// The glyph is appended after the time slot in the menu-bar render, in its own colour.
    func testGlyphAppendedToMenuBarLine() {
        let m = DisplayFormatter.toolMenuBar(
            tool: .claude, state: .overQuota,
            snapshot: snapshot(used: 100, extraUsage: extra(enabled: true)),
            forecast: forecast(burn: 1.0), glyph: .charging, now: now)
        XCTAssertEqual(m.glyph, .charging)
        let render = DisplayFormatter.menuBarRender(mode: .claudeOnly, claude: m, codex: nil)
        XCTAssertEqual(render.lines.first?.glyph, .charging)
    }

    /// Cross-surface invariant (§19): for identical forecast input, the §1.6 glyph and the §2.4a
    /// card money state agree — charging⟺charging, armed⟹armed, off/blocked/absent⟹none.
    func testCrossSurfaceGlyphCardAgreement() {
        struct Case { let used: Double?; let extra: ExtraUsage?; let burn: Double? }
        let cases = [
            Case(used: 100, extra: extra(enabled: true), burn: 1.0),   // charging
            Case(used: 90, extra: extra(enabled: true), burn: 1.0),    // armed
            Case(used: 40, extra: extra(enabled: true), burn: 0.01),   // on, coast
            Case(used: 40, extra: .disabled, burn: 1.0),               // off
            Case(used: 40, extra: nil, burn: 1.0),                     // absent
        ]
        for c in cases {
            let snap = snapshot(used: c.used, extraUsage: c.extra)
            let g = MoneyModel.moneyGlyphInstant(snapshot: snap, forecast: forecast(burn: c.burn), now: now)
            let state = MoneyModel.moneyState(snapshot: snap)
            switch g {
            case .charging: XCTAssertEqual(state, .charging)
            case .armed:    XCTAssertEqual(state, .armed)
            case .none:     XCTAssertNotEqual(state, .charging,
                                              "glyph none must never coincide with a charging card")
            }
        }
    }

    /// Fully-spent hard-capped window, no credits (util == 100, Case 3) reads the merged
    /// blocked template (D-31, STEP_39): "Stopped — quota returns at [t]" — one advisory string
    /// for every blocked over-quota, live and stale. (This fixture's reset crosses local
    /// midnight, so the clock token carries the D-29 ` tomorrow` suffix via `clockDay`.)
    func testOverQuotaNoCreditsReadsQuotaSpent() {
        let c = DisplayFormatter.claude(state: .overQuota,
                                        snapshot: snapshot(used: 100, extraUsage: .disabled),
                                        forecast: forecast(), now: now)
        XCTAssertEqual(c.header?.verdict?.line1,
                       "Stopped — quota returns at \(Fmt.clockDay(now.addingTimeInterval(120 * 60), from: now))")
        XCTAssertEqual(c.dot, .red)
    }

    /// On usage credits at the limit → §7.1 Case 1, the v5.1 accruing row (§2.2a, STEP_40):
    /// "$ Running on credits" with the `$` as the §1.6 glyph prefix, never in the string.
    func testOverQuotaOnCreditsReadsOverQuota() {
        let c = DisplayFormatter.claude(state: .overQuota,
                                        snapshot: snapshot(used: 100, extraUsage: extra(enabled: true)),
                                        forecast: forecast(), now: now)
        XCTAssertEqual(c.header?.verdict?.line1, "Running on credits — every token costs now")
        XCTAssertEqual(c.header?.verdict?.moneyPrefix, true)
    }

    func testQuotaThresholdDots() {
        XCTAssertEqual(Fmt.thresholdDot(38), .green)
        XCTAssertEqual(Fmt.thresholdDot(60), .amber)
        XCTAssertEqual(Fmt.thresholdDot(85), .amber)
        XCTAssertEqual(Fmt.thresholdDot(86), .red)
    }

    // MARK: Codex popover

    func testCodexNullWindow() {
        let x = DisplayFormatter.codex(state: .nullWindow,
                                       snapshot: snapshot(tool: .codex, used: nil, secondary: nil, plan: "Enterprise"),
                                       forecast: forecast(tool: .codex, burn: nil), now: now)
        XCTAssertEqual(x.phase, .content)
        XCTAssertEqual(x.dot, .neutral)
        // Always-show (STEP_32): quota rows render with `—` placeholders even in null-window.
        // The primary reads `Used` since STEP_87 (REV-59 / D-58): the provider sent no window and
        // therefore no width, so there is no grain to claim. `5-hour used —` asserted a five-hour
        // window the payload never mentioned and left the dash reading as a failed fetch — the
        // exact confusion D-58 exists to remove. The four rows themselves are untouched: without a
        // width we cannot tell an absent secondary from an unread one, so always-show still holds.
        // Nothing is reported, so there is no limit to list and no caption to write — the hero
        // reads the unknown form and the note below says why (STEP_178).
        XCTAssertNil(x.otherLimits)
        // The caption names the slot without inventing a width — never `5-hour quota left` over
        // a payload that mentioned no window (D-58 clause 3).
        XCTAssertEqual(x.header?.limitCaption, "Window quota left")
        XCTAssertEqual(x.header?.heroText, "——")
        XCTAssertEqual(x.header?.email, "user@example.com")   // Codex carries account email (Baseline §8.2 parity, dac43d3)
        // §2.2a null-windows verdict (Codex).
        XCTAssertEqual(x.header?.verdict?.line1, "No active window")
        XCTAssertEqual(x.header?.verdict?.line2, "—")
        XCTAssertEqual(x.nullWindowNote,
                       "Account quota windows are null (healthy idle). Showing local token data.")
    }

    // MARK: Claude not-started window (STEP_32 overnight shape → REV-80 / D-101, STEP_147)

    /// The overnight shape — a present five_hour with `resets_at: null` and a live weekly — is
    /// the not-started shape since REV-80: hero `100%`, the D-58 caption, `5-hour left 100%`,
    /// `Resets at — (no window open)`, and the weekly rows intact. Never "No active session".
    func testClaudeNotStartedKeepsWeeklyData() {
        let weeklyReset = now.addingTimeInterval(4 * 86_400)
        let s = QuotaSnapshot(tool: .claude, primaryUsedPct: 0, primaryResetsAt: nil,
                              primaryWindowSeconds: 18_000,
                              secondaryUsedPct: 51, secondaryResetsAt: weeklyReset,
                              rateLimitReached: false, extraUsage: .disabled, source: .oauth,
                              email: "user@example.com", planType: "max")
        let c = DisplayFormatter.claude(state: .healthy, snapshot: s,
                                        forecast: forecast(runway: nil, burn: nil), now: now)
        XCTAssertEqual(c.phase, .content)
        XCTAssertEqual(c.header?.heroText, "100%")
        XCTAssertEqual(c.header?.limitCaption, "5-hour quota left")
        XCTAssertEqual(c.header?.heroDetails.map(\.text), ["not started"])
        // No verdict row at all since D-123 (STEP_207) — and still never "No active session",
        // which is what this test was written to deny.
        XCTAssertNil(c.header?.verdict)
        // The weekly data is intact, once, in `OTHER LIMITS` (STEP_178).
        let weekly = try! XCTUnwrap(c.otherLimits?.rows.first { $0.id == .secondaryWindow })
        // 51 % used with four of the week's seven days left — **42.9 % of the week gone, not
        // 50 %**: `day 4 of 7` is a ceiling and reading elapsed off it is the premise error
        // REV-98 §1 corrects. That pace lands the week at 119 %, so the row is amber under the
        // projection test as it was under the comparison it replaces (STEP_200). The tier is
        // what STEP_196 and REV-98 replay; the row shape is what is pinned here.
        // The amber tier reaches the row as its **dot** — 51 % used is green to the utilization
        // threshold this row used to read (REV-98 §2.5(a)) — and its words are the strip's, so
        // the lifted row states the number alone (§2.5(c)).
        XCTAssertEqual(weekly.value, "49%")
        XCTAssertTrue(weekly.isHighlighted)
        XCTAssertEqual(weekly.cue, .amber)
        XCTAssertEqual(weekly.reset, "resets \(Fmt.monthDay(weeklyReset)) · day 4 of 7")
        XCTAssertEqual(c.header?.sourceTag, "Source: Claude account · exact")
    }

    /// D-101 — one fact, one shape, both tabs: the Claude render of the not-started shape is the
    /// Codex render of the same shape, field for field, on the hero, the caption, the verdict
    /// family, the reset row and the menu bar.
    func testClaudeNotStartedRendersAsCodexDoes() {
        func shape(_ tool: Tool) -> QuotaSnapshot {
            QuotaSnapshot(tool: tool, primaryUsedPct: 0, primaryResetsAt: nil,
                          primaryWindowSeconds: 18_000,
                          secondaryUsedPct: 20, secondaryResetsAt: now.addingTimeInterval(86_400),
                          rateLimitReached: false, extraUsage: tool == .claude ? .disabled : nil,
                          planType: tool == .claude ? "max" : "plus")
        }
        let f = { (tool: Tool) in
            Forecast(tool: tool, tier: .fullRunway, runwayMinutes: nil, burnRatePerMin: nil,
                     isEstimate: false, pollCount: 1)
        }
        let c = DisplayFormatter.claude(state: .healthy, snapshot: shape(.claude), forecast: f(.claude), now: now)
        let x = DisplayFormatter.codex(state: .healthy, snapshot: shape(.codex), forecast: f(.codex), now: now)
        XCTAssertEqual(c.header?.heroText, "100%")
        XCTAssertEqual(c.header?.heroText, x.header?.heroText)
        XCTAssertEqual(c.header?.limitCaption, "5-hour quota left")
        XCTAssertEqual(c.header?.limitCaption, x.header?.limitCaption)
        XCTAssertEqual(c.header?.heroDetails.map(\.text), ["not started"])
        XCTAssertEqual(c.header?.heroDetails.map(\.text), x.header?.heroDetails.map(\.text))
        // One fact, one shape: the row is removed on both tools, not merely equal (D-123).
        XCTAssertNil(c.header?.verdict)
        XCTAssertNil(x.header?.verdict)
        XCTAssertEqual(c.header?.windowScopeLive?.text,
                       "*Not started yet — your first turn starts the clock.*")
        XCTAssertEqual(c.header?.windowScopeLive?.text, x.header?.windowScopeLive?.text)
        XCTAssertEqual(c.header?.limit?.availability, .unanchored)
        XCTAssertEqual(c.header?.limit?.availability, x.header?.limit?.availability)
        let cm = DisplayFormatter.toolMenuBar(tool: .claude, state: .healthy, snapshot: shape(.claude),
                                              forecast: f(.claude), now: now)
        let xm = DisplayFormatter.toolMenuBar(tool: .codex, state: .healthy, snapshot: shape(.codex),
                                              forecast: f(.codex), now: now)
        XCTAssertEqual(cm.fullString, "CL 100%")
        XCTAssertEqual(xm.fullString, "CX 100%")
    }

    /// REV-57 / STEP_85 — an unanchored Codex window: 0% used, no reset, because none has started.
    /// The popover cannot be driven programmatically, so this is the only check on the copy.
    func testUnanchoredWindowSaysNoWindowOpen() {
        let now = Date()
        let s = QuotaSnapshot(tool: .codex, primaryUsedPct: 0, primaryResetsAt: nil,
                              primaryWindowSeconds: 2_592_000,
                              secondaryUsedPct: nil, secondaryResetsAt: nil,
                              rateLimitReached: false, source: .appServerRPC,
                              email: "user@example.com", planType: "go")
        let x = DisplayFormatter.codex(state: .healthy, snapshot: s,
                                       forecast: forecast(runway: nil, burn: nil), now: now)
        // The fixture is a real `go` payload, and its 30-day width is what names the hero
        // (REV-59 / D-58). Utilization is real and must still render — 0 used is 100 left — and
        // the missing reset says *not started*, never a bare em dash that reads as missing data.
        XCTAssertEqual(x.header?.heroText, "100%")
        XCTAssertEqual(x.header?.limitCaption, "Monthly quota left")
        XCTAssertEqual(x.header?.heroDetails.map(\.text), ["not started"])
        // And the verdict row is removed (D-123): this shape has no runway to speak about, which
        // on a `go` account the low-allowance rule one line above already said.
        XCTAssertNil(x.header?.verdict)
        // The menu bar drops the countdown entirely rather than showing one that cannot count down.
        XCTAssertNil(DisplayFormatter.menuBarTimeSlot(state: .healthy, snapshot: s,
                                                     forecast: nil, now: now))
    }

    /// The Claude guard for the row above: a real window whose `resets_at` failed to parse also has
    /// a percent and no reset, but it *is* open — it must keep the bare `—`. `quotaRows` is shared
    /// by both tools, so this distinction is the whole reason the copy keys on the snapshot's own
    /// unanchored verdict rather than on "percent without reset".
    func testClaudeUnparseableResetKeepsBareDash() {
        let s = QuotaSnapshot(tool: .claude, primaryUsedPct: 42, primaryResetsAt: nil,
                              secondaryUsedPct: nil, secondaryResetsAt: nil,
                              rateLimitReached: false, extraUsage: .disabled, source: .oauth,
                              email: "user@example.com", planType: "max")
        let c = DisplayFormatter.claude(state: .healthy, snapshot: s,
                                        forecast: forecast(runway: nil, burn: nil), now: Date())
        // No width, so the D-58 band rule cannot fire and the header states no reset at all —
        // never "not started", which would claim a window that is in fact open.
        XCTAssertTrue(c.header!.heroDetails.isEmpty)
        XCTAssertNotEqual(c.header?.limit?.availability, .unanchored)
        XCTAssertFalse(s.primaryWindowIsUnanchored)
    }

    func testHealthyRendersResetsFirstVerdict() {
        // Healthy with a finite runway that outlasts the reset → the v5.1 resets-first row,
        // green. reset 120 min, runway 900 → margin 780 ≥ 30 → comfortable variant.
        let c = DisplayFormatter.claude(state: .healthy, snapshot: snapshot(),
                                        forecast: forecast(runway: 900), now: now)
        XCTAssertEqual(c.header?.verdict?.line1, "Safe at this pace — reset comes first")
        XCTAssertEqual(c.header?.verdict?.colour, .green)
    }

    func testCodexContentBurnRate() {
        let x = DisplayFormatter.codex(state: .elevated,
                                       snapshot: snapshot(tool: .codex, used: 71, plan: "Plus"),
                                       forecast: forecast(tool: .codex, runway: 31, burn: 1.9), now: now)
        XCTAssertNotNil(x.header)
        XCTAssertEqual(x.header?.accountBurn?.tier, "mid")
        XCTAssertEqual(x.header?.accountBurn?.value, "Mid · 1.9% / min")
    }

    // MARK: The header's two facts (STEP_178 — the retired burn card's quantities)
    //
    // `Local source` (E-06) left the popover with the card: what ran locally is now the
    // `LOCAL ACTIVITY · TODAY` section's own story, and a per-surface roll-call above the
    // account meter was the twin D-67 already deleted once. The two quantities that answer
    // *how fast* and *how much wasn't mine* survive, one compact line each.

    func testBurnFactIsHiddenDuringColdStart() {
        // No account rate yet (cold start / post-gap buffer clear): omit the optional fact.
        let c = DisplayFormatter.claude(state: .healthy, snapshot: snapshot(),
                                        forecast: Forecast(tool: .claude, tier: .fullRunway,
                                                           runwayMinutes: nil, burnRatePerMin: nil,
                                                           isEstimate: false, pollCount: 1),
                                        localAttribution: attribution(), now: now)
        XCTAssertNil(c.header?.accountBurn)
        XCTAssertEqual(c.header?.notSeenLocally?.value, "—")
    }

    func testNotSeenLocallyWhileLocalIsActive() {
        // REV-28: the cumulative Elsewhere share stays visible even while local is active — the
        // value is points-of-quota, so it ties to the header %.
        let wa = WindowAttribution(offMachinePct: 10, localPct: 4, unattributedPct: 0, totalUsedPct: 14)
        let c = DisplayFormatter.claude(state: .healthy, snapshot: snapshot(),
                                        forecast: forecast(burn: 1.4),
                                        localAttribution: attribution(), offMachine: wa, now: now)
        XCTAssertEqual(c.header?.notSeenLocally?.label, "Not seen locally")
        XCTAssertEqual(c.header?.notSeenLocally?.value, "≈10% (est.)")
    }

    func testNotSeenLocallyWhileLocalIsIdle() {
        let wa = WindowAttribution(offMachinePct: 30, localPct: 0, unattributedPct: 0, totalUsedPct: 30)
        let c = DisplayFormatter.claude(state: .offMachineBurn, snapshot: snapshot(used: 72),
                                        forecast: forecast(burn: 1.2),
                                        localAttribution: attribution(tokPerMin: nil),
                                        offMachine: wa, now: now)
        XCTAssertEqual(c.header?.notSeenLocally?.value, "≈30% (est.)")
    }

    func testNotSeenLocallyIsHiddenWhenZeroThisWindow() {
        // Window observed but nothing elsewhere accumulated → a supported zero, not unknown.
        let wa = WindowAttribution(offMachinePct: 0, localPct: 5, unattributedPct: 0, totalUsedPct: 5)
        let c = DisplayFormatter.claude(state: .healthy, snapshot: snapshot(),
                                        forecast: forecast(burn: 0.5),
                                        localAttribution: attribution(), offMachine: wa, now: now)
        XCTAssertNil(c.header?.notSeenLocally)
    }

    func testNotSeenLocallyBoundsASmallPositiveInsteadOfRoundingToZero() {
        let wa = WindowAttribution(offMachinePct: 0.4, localPct: 5,
                                   unattributedPct: 0, totalUsedPct: 5.4)
        let c = DisplayFormatter.claude(state: .healthy, snapshot: snapshot(),
                                        forecast: forecast(burn: 0.5),
                                        localAttribution: attribution(), offMachine: wa, now: now)
        XCTAssertEqual(c.header?.notSeenLocally?.value, "<1% (est.)")
    }

    func testNotSeenLocallyIsUnknownWithoutAWindowAttribution() {
        let c = DisplayFormatter.claude(state: .healthy, snapshot: snapshot(),
                                        forecast: forecast(burn: 0.5),
                                        localAttribution: attribution(), offMachine: nil, now: now)
        XCTAssertEqual(c.header?.notSeenLocally?.value, "—")
        XCTAssertEqual(c.header?.notSeenLocally?.availability, .unknown)
    }

    // MARK: Reset formatting

    func testCountdownFormat() {
        XCTAssertEqual(Fmt.countdown(to: now.addingTimeInterval(112 * 60), from: now), "1h52m")
        XCTAssertEqual(Fmt.countdown(to: now.addingTimeInterval(112 * 60), from: now, spaced: true), "1h 52m")
        XCTAssertEqual(Fmt.countdown(to: now.addingTimeInterval(58 * 60), from: now), "58m")
        XCTAssertEqual(Fmt.countdown(to: now.addingTimeInterval(58 * 60), from: now, spaced: true), "58m")
        XCTAssertNil(Fmt.countdown(to: now.addingTimeInterval(-60), from: now))
    }

    // MARK: STEP_27 — plan badge, resets-red rule, burn tier, source tags

    func testPlanDisplayNameMapping() {
        XCTAssertEqual(DisplayFormatter.planDisplayName("plus"), "Plus")
        XCTAssertEqual(DisplayFormatter.planDisplayName("prolite"), "Pro")
        XCTAssertEqual(DisplayFormatter.planDisplayName("max"), "Max")
        XCTAssertEqual(DisplayFormatter.planDisplayName("self_serve_business_usage_based"), "Business")
        XCTAssertEqual(DisplayFormatter.planDisplayName("enterprise_cbp_usage_based"), "Enterprise")
        XCTAssertEqual(DisplayFormatter.planDisplayName("k12"), "Education")
        XCTAssertEqual(DisplayFormatter.planDisplayName("guest"), "Free")
        XCTAssertEqual(DisplayFormatter.planDisplayName("wat_new_tier"), "wat_new_tier",
                       "unknown plan strings show raw — never crash (§0.4)")
    }

    func testPlanBadgeNoCreditSuffixWhileOnCredits() {
        // The invented "· credit" badge text is gone (STEP_27); the blue badgeKind pill carries
        // the credits signal instead.
        let c = DisplayFormatter.claude(
            state: .healthy,
            snapshot: snapshot(extraUsage: extra(enabled: true)),
            forecast: forecast(), now: now)
        XCTAssertEqual(c.header?.planBadge, "Pro")
        XCTAssertEqual(c.header?.badgeKind, .credit)
    }

    func testBurnPillNoneBelowPointOne() {
        // §2.4 (STEP_27): "none" below 0.1 %/min — a 0.05 trickle is idle.
        let c = DisplayFormatter.claude(state: .healthy, snapshot: snapshot(),
                                        forecast: forecast(burn: 0.05),
                                        localAttribution: attribution(), now: now)
        XCTAssertEqual(c.header?.accountBurn?.tier, "none")
        let low = DisplayFormatter.claude(state: .healthy, snapshot: snapshot(),
                                          forecast: forecast(burn: 0.1),
                                          localAttribution: attribution(), now: now)
        XCTAssertEqual(low.header?.accountBurn?.tier, "low")
    }

    func testCodexSourceTagsFollowSnapshotSource() {
        let viaWham = QuotaSnapshot(tool: .codex, primaryUsedPct: 42,
                                    primaryResetsAt: now.addingTimeInterval(7200),
                                    secondaryUsedPct: 18, secondaryResetsAt: nil,
                                    rateLimitReached: false, extraUsage: .disabled,
                                    source: .wham, planType: "plus")
        let cx = DisplayFormatter.codex(state: .healthy, snapshot: viaWham,
                                        forecast: forecast(tool: .codex),
                                        localAttribution: attribution(cacheHit: nil), now: now)
        XCTAssertEqual(cx.header?.sourceTag, "Source: wham/usage · exact")

        let viaRPC = DisplayFormatter.codex(state: .healthy,
                                            snapshot: snapshotCodex(source: .appServerRPC),
                                            forecast: forecast(tool: .codex), now: now)
        XCTAssertEqual(viaRPC.header?.sourceTag, "Source: app-server RPC · exact")
    }

    /// STEP_87 (REV-59 / D-58): the width is what names the window, and a real Codex payload with a
    /// populated window always carries it — all three surfaces do (wham `limit_window_seconds`, RPC
    /// `windowDurationMins`, Codex's own JSONL `window_minutes`). This fixture predates the field
    /// and so described a payload that cannot occur; 300 minutes is the five-hour width it always
    /// meant, taken from the corpus (384 blocks).
    private func snapshotCodex(source: QuotaSource? = nil, plan: String = "plus",
                               resetsInMin: Double? = 120) -> QuotaSnapshot {
        QuotaSnapshot(tool: .codex, primaryUsedPct: 42,
                      primaryResetsAt: resetsInMin.map { now.addingTimeInterval($0 * 60) },
                      primaryWindowSeconds: 300 * 60,
                      secondaryUsedPct: 18, secondaryResetsAt: nil,
                      rateLimitReached: false, extraUsage: .disabled,
                      source: source, planType: plan)
    }

    // MARK: STEP_27 — Codex local session (cache hit, window grain) & additional limits

    func testCodexCacheHitRowAndWindowGrain() {
        let attr = attribution(surface: "Desktop", cacheHit: 0.75)
        let confirmed = DisplayFormatter.codex(state: .healthy, snapshot: snapshotCodex(),
                                               forecast: forecast(tool: .codex),
                                               localAttribution: attr, now: now)
        // §8.4's cache-hit row survives the cutover as `Cache hit` on the daily local
        // section, over the day's own population rather than the window's (STEP_178).
        XCTAssertNotNil(confirmed.localActivity)
        XCTAssertEqual(LocalActivitySection.cacheHitLabel, "Cache hit")
    }

    func testCodexWindowGrainTodayOnNullWindowFallback() {
        let nullSnap = QuotaSnapshot(tool: .codex, primaryUsedPct: nil, primaryResetsAt: nil,
                                     secondaryUsedPct: nil, secondaryResetsAt: nil,
                                     rateLimitReached: nil, extraUsage: .disabled, planType: "enterprise")
        let cx = DisplayFormatter.codex(state: .nullWindow, snapshot: nullSnap,
                                        forecast: forecast(tool: .codex, burn: nil),
                                        localAttribution: attribution(cacheHit: nil),
                                        localDay: .today, now: now)
        // Since STEP_178 the local section is **always** the local calendar day — no window
        // anchor, no confidence fork, no automatic yesterday (REV-92 §2.4). The window-grain
        // confidence question the old title answered no longer arises.
        XCTAssertEqual(LocalActivitySection.title, "LOCAL ACTIVITY · TODAY")
        XCTAssertNotNil(cx.localActivity)
    }

    /// The `+ N model limits` disclosure was replaced by a visible-by-default model group in
    /// `OTHER LIMITS` (STEP_178 — REV-92 §2 follow-up).
    func testModelLimitsRenderAsAVisibleGroup() {
        let spark = AdditionalRateLimit(id: "codex_spark", name: "GPT-5.3-Codex-Spark",
                                        usedPercent: 12, resetsAt: nil)
        let snap = QuotaSnapshot(tool: .codex, primaryUsedPct: 42,
                                 primaryResetsAt: now.addingTimeInterval(7200),
                                 secondaryUsedPct: 18, secondaryResetsAt: nil,
                                 rateLimitReached: false, extraUsage: .disabled,
                                 additionalRateLimits: [spark], planType: "plus")
        let cx = DisplayFormatter.codex(state: .healthy, snapshot: snap,
                                        forecast: forecast(tool: .codex), now: now)
        let group = try! XCTUnwrap(cx.otherLimits?.modelGroups.first)
        XCTAssertEqual(group.name, "GPT-5.3-Codex-Spark")
        XCTAssertEqual(group.rows.count, 1)
        XCTAssertEqual(group.rows.first?.value, "88%", "model rows are remaining too (D-97)")

        let none = DisplayFormatter.codex(state: .healthy, snapshot: snapshotCodex(),
                                          forecast: forecast(tool: .codex), now: now)
        XCTAssertTrue(none.otherLimits?.modelGroups.isEmpty ?? true,
                      "no sub-buckets → no model group")
    }

    /// `Not seen locally` on the Codex tab reads exactly as it does on Claude — one grammar,
    /// both tools (STEP_178; the burn card that used to carry it is gone).
    func testCodexNotSeenLocally() {
        let wa = WindowAttribution(offMachinePct: 5, localPct: 15, unattributedPct: 0, totalUsedPct: 20)
        let cx = DisplayFormatter.codex(state: .offMachineBurn, snapshot: snapshotCodex(),
                                        forecast: forecast(tool: .codex, burn: 2.0),
                                        localAttribution: attribution(surface: "Desktop", cacheHit: nil,
                                                                      tokPerMin: nil),
                                        offMachine: wa, now: now)
        XCTAssertEqual(cx.header?.notSeenLocally?.value, "≈5% (est.)")
    }

    // MARK: STEP_27 — §2.6/§2.8 recommendation templates

    func testAtRiskRecommendationWithClockTime() {
        let c = DisplayFormatter.claude(state: .atRisk, snapshot: snapshot(used: 87, resetsInMin: 58),
                                        forecast: forecast(runway: 11), now: now)
        let text = try! XCTUnwrap(c.recommendation)
        XCTAssertTrue(text.hasPrefix("Finish your current task and pause new prompts. Quota resets at "))
        XCTAssertTrue(text.hasSuffix("— 58 minutes away."))
    }

    func testBadTimingRecommendationFullSentence() {
        let c = DisplayFormatter.claude(state: .badTiming, snapshot: snapshot(used: 91),
                                        forecast: forecast(), now: now)
        XCTAssertEqual(c.recommendation,
                       "With 9% left and 2h 0m until reset, you risk hitting the limit before your "
                       + "quota refreshes.")
    }

    func testOverQuotaCase1CreditsAccruing() {
        let c = DisplayFormatter.claude(
            state: .overQuota,
            snapshot: snapshot(used: 106, extraUsage: extra(enabled: true)),
            forecast: forecast(), now: now)
        XCTAssertEqual(c.recommendation,
                       "Operating on usage credits. $3.20 of $20.00 used this month · still "
                       + "accruing. Window resets in 2h 0m.")
        XCTAssertEqual(c.recommendationSeverity, .warning)
    }

    func testOverQuotaCase2LastObserved() {
        let c = DisplayFormatter.claude(
            state: .overQuota,
            snapshot: snapshot(used: 106, extraUsage: extra(enabled: false, cached: true)),
            forecast: forecast(), now: now)
        XCTAssertEqual(c.recommendation,
                       "Credits were used earlier this window ($3.20 of $20.00 · last observed). "
                       + "New requests are now blocked. Window resets in 2h 0m.")
        XCTAssertEqual(c.recommendationSeverity, .danger)
    }

    func testOverQuotaCase3HardBlockCanComplete() {
        let c = DisplayFormatter.claude(state: .overQuota,
                                        snapshot: snapshot(used: 106, extraUsage: .disabled),
                                        forecast: forecast(), now: now)
        XCTAssertEqual(c.recommendation,
                       "New requests are blocked until the 5-hour window resets in 2h 0m. "
                       + "Any task currently running can complete.")
    }

    func testCodexOverQuotaCopy() {
        let cx = DisplayFormatter.codex(state: .overQuota, snapshot: snapshotCodex(),
                                        forecast: forecast(tool: .codex), now: now)
        XCTAssertEqual(cx.recommendation,
                       "New Codex requests are blocked until the window resets in 2h 0m.")
    }

    func testClaudeFastBurnNamesSubagentsAndModel() {
        let c = DisplayFormatter.claude(state: .fastBurnSpike, snapshot: snapshot(used: 54),
                                        forecast: forecast(runway: 18),
                                        localAttribution: attribution(subagents: 3), now: now)
        XCTAssertEqual(c.recommendation,
                       "3 subagents running on claude-sonnet-4-6 are driving fast usage. "
                       + "If unexpected, check Claude Code for a runaway tool loop.")
        // Fallback when the inputs are missing.
        let bare = DisplayFormatter.claude(state: .fastBurnSpike, snapshot: snapshot(used: 54),
                                           forecast: forecast(runway: 18), now: now)
        XCTAssertEqual(bare.recommendation,
                       "Usage is climbing quickly. If unexpected, check Claude Code for a "
                       + "runaway tool loop.")
    }

    func testCodexFastBurnWithDeltaAndExhaustion() {
        let cx = DisplayFormatter.codex(state: .fastBurnSpike, snapshot: snapshotCodex(),
                                        forecast: forecast(tool: .codex, runway: 22),
                                        localAttribution: attribution(cacheHit: nil),
                                        fastBurnDelta: 24, now: now)
        XCTAssertEqual(cx.recommendation,
                       "Usage jumped +24% since the last check. If unexpected, check Codex for a "
                       + "runaway loop. At this pace the window exhausts in ~22 min.")
    }

    func testCodexOffMachineNamesPercentAndReset() {
        let cx = DisplayFormatter.codex(state: .offMachineBurn, snapshot: snapshotCodex(),
                                        forecast: forecast(tool: .codex), now: now)
        let text = try! XCTUnwrap(cx.recommendation)
        XCTAssertTrue(text.hasPrefix("Codex is idle on all local surfaces. Usage is likely from "
                                     + "another machine or Codex Web. 58% left · resets at "))
    }

    func testMultiSurfaceRecommendationNamesSurfaces() {
        // STEP_192: both surfaces must be burning now (an event inside the 8-minute idle gap).
        let shares = [SurfaceShare(label: "Desktop", fraction: 0.7, lastEventAt: now.addingTimeInterval(-30)),
                      SurfaceShare(label: "CLI", fraction: 0.3, lastEventAt: now.addingTimeInterval(-90))]
        let cx = DisplayFormatter.codex(state: .multiSurface, snapshot: snapshotCodex(),
                                        forecast: forecast(tool: .codex, runway: 22, burn: 2.0),
                                        localAttribution: attribution(cacheHit: nil, shares: shares),
                                        now: now)
        XCTAssertEqual(cx.recommendation,
                       "Desktop and CLI are both active. Desktop is the primary driver at "
                       + "~1.4% / min. At this combined pace the window exhausts in ~22 min.")
    }

    // MARK: STEP_192 — the card names surfaces burning now, never `Unknown`, never a 0.0 rate

    /// The 2026-09-13 22:18 CEST card. Desktop last wrote at 16:24 yet held the larger weekly
    /// share, so the whole-window split named it "the primary driver". With only one surface
    /// active the card falls back to the unnamed sentence (the state itself no longer fires —
    /// this pins the copy layer's own guard).
    func testMultiSurfaceIdleDesktopIsNotNamed() {
        let shares = [SurfaceShare(label: "Desktop", fraction: 0.57, lastEventAt: now.addingTimeInterval(-6 * 3600)),
                      SurfaceShare(label: "CLI", fraction: 0.43, lastEventAt: now.addingTimeInterval(-60))]
        let cx = DisplayFormatter.codex(state: .multiSurface, snapshot: snapshotCodex(),
                                        forecast: forecast(tool: .codex, runway: 22, burn: 2.0),
                                        localAttribution: attribution(cacheHit: nil, shares: shares),
                                        now: now)
        XCTAssertEqual(cx.recommendation, "Multiple Codex surfaces are active simultaneously.")
    }

    /// `Unknown` is a bucket, not a surface — it is never active, so Desktop + Unknown is one
    /// surface and the card can only show the guard sentence (the state itself no longer fires).
    func testMultiSurfaceNeverNamesUnknown() {
        let shares = [SurfaceShare(label: "Desktop", fraction: 0.6, lastEventAt: now),
                      SurfaceShare(label: "Unknown", fraction: 0.4, lastEventAt: now)]
        let cx = DisplayFormatter.codex(state: .multiSurface, snapshot: snapshotCodex(),
                                        forecast: forecast(tool: .codex, runway: 22, burn: 2.0),
                                        localAttribution: attribution(cacheHit: nil, shares: shares),
                                        now: now)
        XCTAssertEqual(cx.recommendation, "Multiple Codex surfaces are active simultaneously.")
    }

    /// A weekly window's %/min is ~0.01; times the primary's share it rounds to `0.0`, and
    /// "primary driver at ~0.0% / min" is a contradiction. Below the one-decimal floor the card
    /// is the two-surface sentence alone — the pace sentence hangs off the rate and goes with it.
    func testMultiSurfaceDropsRateThatRoundsToZero() {
        let shares = [SurfaceShare(label: "Desktop", fraction: 0.6, lastEventAt: now),
                      SurfaceShare(label: "CLI", fraction: 0.4, lastEventAt: now)]
        let cx = DisplayFormatter.codex(state: .multiSurface, snapshot: snapshotCodex(),
                                        forecast: forecast(tool: .codex, runway: 4 * 1440, burn: 0.01),
                                        localAttribution: attribution(cacheHit: nil, shares: shares),
                                        now: now)
        XCTAssertEqual(cx.recommendation, "Desktop and CLI are both active.")
    }

    /// Three surfaces burning at once are all named (owner ruling 2026-09-13 — the unnamed
    /// sentence is not actionable); the primary is still the largest window share.
    func testMultiSurfaceThreeActiveAreAllNamed() {
        let shares = [SurfaceShare(label: "Desktop", fraction: 0.5, lastEventAt: now),
                      SurfaceShare(label: "CLI", fraction: 0.3, lastEventAt: now),
                      SurfaceShare(label: "IDE extension", fraction: 0.2, lastEventAt: now)]
        let cx = DisplayFormatter.codex(state: .multiSurface, snapshot: snapshotCodex(),
                                        forecast: forecast(tool: .codex, runway: 22, burn: 2.0),
                                        localAttribution: attribution(cacheHit: nil, shares: shares),
                                        now: now)
        XCTAssertEqual(cx.recommendation,
                       "Desktop, CLI and IDE extension are all active. Desktop is the primary "
                       + "driver at ~1.0% / min. At this combined pace the window exhausts in ~22 min.")
    }

    // MARK: STEP_97 — D-63 hint countdowns follow the distance (§2.6/§2.8)

    /// The 2026-08-12 live block: a Codex **Go** account at 100% with a 30-day window rendered
    /// "blocked until the window resets in 41579 min". The reset row beside it already said
    /// "29 days" — only the hint did its own minute arithmetic.
    func testCodexOverQuotaSpellsOutLongWindows() {
        let go = DisplayFormatter.codex(state: .overQuota,
                                        snapshot: snapshotCodex(plan: "go", resetsInMin: 30 * 1440),
                                        forecast: forecast(tool: .codex), now: now)
        XCTAssertEqual(go.recommendation,
                       "New Codex requests are blocked until the window resets in 30 days.")
        // Plus is a 7-day window — the same sentence would otherwise read "in 10080 min".
        let plus = DisplayFormatter.codex(state: .overQuota,
                                          snapshot: snapshotCodex(resetsInMin: 7 * 1440),
                                          forecast: forecast(tool: .codex), now: now)
        XCTAssertEqual(plus.recommendation,
                       "New Codex requests are blocked until the window resets in 7 days.")
    }

    func testAtRiskSpellsOutLongWindows() {
        let cx = DisplayFormatter.codex(state: .atRisk,
                                        snapshot: snapshotCodex(resetsInMin: 30 * 1440),
                                        forecast: forecast(tool: .codex), now: now)
        let text = try! XCTUnwrap(cx.recommendation)
        XCTAssertTrue(text.hasSuffix("— 30 days away."), "got: \(text)")
    }

    /// The runway projection is a different quantity from a reset countdown but the same failure:
    /// `Fmt.runwayLong` routes it through `daysLong` so the two can never disagree about a duration.
    func testCodexFastBurnRunwaySpellsOutLongWindows() {
        let cx = DisplayFormatter.codex(state: .fastBurnSpike,
                                        snapshot: snapshotCodex(resetsInMin: 30 * 1440),
                                        forecast: forecast(tool: .codex, runway: 30 * 1440),
                                        localAttribution: attribution(cacheHit: nil),
                                        fastBurnDelta: 24, now: now)
        XCTAssertEqual(cx.recommendation,
                       "Usage jumped +24% since the last check. If unexpected, check Codex for a "
                       + "runaway loop. At this pace the window exhausts in ~30 days.")
    }

    /// D-63 extends D-59's band to the hint strings, so the boundary is D-59's: whole days at
    /// ≥ 48h, the untouched minute form below. Rounding is **up** — 49h is "3 days", never "2",
    /// because a countdown must not promise relief sooner than it arrives.
    func testHintCountdownBoundaryAt48Hours() {
        let under = DisplayFormatter.codex(state: .overQuota,
                                           snapshot: snapshotCodex(resetsInMin: 47 * 60),
                                           forecast: forecast(tool: .codex), now: now)
        XCTAssertEqual(under.recommendation,
                       "New Codex requests are blocked until the window resets in 47h 0m.")
        let over = DisplayFormatter.codex(state: .overQuota,
                                          snapshot: snapshotCodex(resetsInMin: 49 * 60),
                                          forecast: forecast(tool: .codex), now: now)
        XCTAssertEqual(over.recommendation,
                       "New Codex requests are blocked until the window resets in 3 days.")
    }

    // MARK: STEP_223 — the block banner speaks in hours and names the limit

    /// Below 48h the banner uses the form every other surface uses — `7h 0m`, `48m` — and at 48h
    /// D-59's day band takes over. The tester's build 16 weekly block read "resets in 444 min".
    func testBlockBannerSpeaksInHoursBelow48h() {
        func claudeBanner(_ minutes: Double) -> String? {
            DisplayFormatter.claude(state: .overQuota,
                                    snapshot: snapshot(used: 106, resetsInMin: minutes,
                                                       extraUsage: .disabled),
                                    forecast: forecast(), now: now).recommendation
        }
        XCTAssertEqual(claudeBanner(48),
                       "New requests are blocked until the 5-hour window resets in 48m. "
                       + "Any task currently running can complete.")
        XCTAssertEqual(claudeBanner(7 * 60),
                       "New requests are blocked until the 5-hour window resets in 7h 0m. "
                       + "Any task currently running can complete.")
        XCTAssertEqual(claudeBanner(47 * 60 + 59),
                       "New requests are blocked until the 5-hour window resets in 47h 59m. "
                       + "Any task currently running can complete.")
        XCTAssertEqual(claudeBanner(48 * 60),
                       "New requests are blocked until the 5-hour window resets in 2 days. "
                       + "Any task currently running can complete.")
        let cx = DisplayFormatter.codex(state: .overQuota, snapshot: snapshotCodex(resetsInMin: 48),
                                        forecast: forecast(tool: .codex), now: now)
        XCTAssertEqual(cx.recommendation,
                       "New Codex requests are blocked until the window resets in 48m.")
    }

    /// The limit comes from the block episode. A Codex primary is called five-hour only where it
    /// is one: a 30-day `go` primary stays "the window".
    func testBlockBannerNamesTheBlockingLimit() {
        func codexBanner(primary: Double, windowSeconds: Int, weekly: Double) -> String? {
            let s = QuotaSnapshot(tool: .codex, primaryUsedPct: primary,
                                  primaryResetsAt: now.addingTimeInterval(2 * 3600),
                                  primaryWindowSeconds: windowSeconds,
                                  secondaryUsedPct: weekly,
                                  secondaryResetsAt: now.addingTimeInterval(7 * 3600 + 24 * 60),
                                  rateLimitReached: false, extraUsage: .disabled,
                                  planType: "plus")
            return DisplayFormatter.codex(state: .overQuota, snapshot: s,
                                          forecast: forecast(tool: .codex), now: now).recommendation
        }
        XCTAssertEqual(codexBanner(primary: 100, windowSeconds: 300 * 60, weekly: 18),
                       "New Codex requests are blocked until the 5-hour window resets in 2h 0m.")
        XCTAssertEqual(codexBanner(primary: 20, windowSeconds: 300 * 60, weekly: 100),
                       "New Codex requests are blocked until the weekly resets in 7h 24m.")
        XCTAssertEqual(codexBanner(primary: 100, windowSeconds: 43_200 * 60, weekly: 18),
                       "New Codex requests are blocked until the window resets in 2h 0m.")
    }

    /// `.badTiming` was already on `Fmt.countdown`, which yields the compact `30d` above 48h —
    /// which would print "30 days" and "30d" for one reset in a single popover.
    func testBadTimingUsesTheSameSpelledOutDayForm() {
        let cx = DisplayFormatter.codex(state: .badTiming,
                                        snapshot: snapshotCodex(resetsInMin: 30 * 1440),
                                        forecast: forecast(tool: .codex), now: now)
        let text = try! XCTUnwrap(cx.recommendation)
        XCTAssertTrue(text.hasPrefix("With 58% left and 30 days until reset,"), "got: \(text)")
    }

    // MARK: Stale render (STEP_32 — §9.3 stale-keep)

    func testStaleRenderKeepsContentWithAsOfTag() {
        let asOf = now.addingTimeInterval(-15 * 60)
        let c = DisplayFormatter.claude(state: .idleFallback, snapshot: snapshot(),
                                        forecast: nil, staleAsOf: asOf, now: now)
        XCTAssertEqual(c.phase, .content, "stale cached data must never drop to the idle card")
        XCTAssertEqual(c.dot, .grey, "stale is calm — a stale warning never stays coloured")
        XCTAssertEqual(c.header?.heroText, "62%")
        XCTAssertEqual(c.header?.sourceTag?.base,
                       "Source: Claude account · as of \(Fmt.clock(asOf))",
                       "cached data must not claim exact")
        // Every freshness surface must agree with the source tag — no "· exact" leaks (found live,
        // 2026-07-06: the plan badge and burn total still said "exact" on 33-min-stale data).
        // The badge now carries no confidence token in any state (D-49); its stale tell is the
        // grey `badgeKind` asserted below, not its words.
        XCTAssertEqual(c.header?.planBadge, "Pro", "the plan pill is the plan name alone")
        XCTAssertEqual(c.header?.badgeKind, .stale, "stale badge greys — never a fresh green pill")
        XCTAssertNil(c.header?.accountBurn,
                     "a stale frozen reading must not present a rate")
    }

    /// D-49 (REV-54) accepted loss, pinned deliberately: a stale render's pill is *textually*
    /// identical to a fresh one — staleness is carried by the grey `badgeKind`, the grey dot and
    /// the `· as of [t]` source tag, never by the badge's words. If this ever fails, the fix is
    /// the styling or the source tag, not a returning suffix (P1-22).
    func testStalePlanBadgeTextMatchesFreshOnlyStylingDiffers() {
        let fresh = DisplayFormatter.claude(state: .healthy, snapshot: snapshot(),
                                            forecast: forecast(), now: now)
        let stale = DisplayFormatter.claude(state: .idleFallback, snapshot: snapshot(),
                                            forecast: nil,
                                            staleAsOf: now.addingTimeInterval(-15 * 60), now: now)
        XCTAssertEqual(stale.header?.planBadge, fresh.header?.planBadge,
                       "the pill reads the plan and nothing else in both states")
        XCTAssertEqual(fresh.header?.badgeKind, .exact)
        XCTAssertEqual(stale.header?.badgeKind, .stale,
                       "the visual tell is the only difference, and it must survive")
    }

    func testStaleRenderDatesTagWhenNotFromToday() {
        let asOf = now.addingTimeInterval(-30 * 3600)
        let c = DisplayFormatter.claude(state: .idleFallback, snapshot: snapshot(),
                                        forecast: nil, staleAsOf: asOf, now: now)
        XCTAssertEqual(c.header?.sourceTag?.base,
                       "Source: Claude account · as of \(Fmt.monthDay(asOf)), \(Fmt.clock(asOf))")
    }

    func testStaleRenderDegradesExpiredPrimaryKeepsLiveWeekly() {
        // The REV-16 complaint: the primary reset passed while asleep — the 5-hour side must
        // never show an expired countdown; the weekly stays. REV-37 (STEP_41) corrects the verdict
        // to the *unknown* form (`—`), not the confident "No active session": an expired-on-stale
        // window has simply not been re-checked (it may be burning off-machine, D-26's blind spot).
        let expired = snapshot(resetsInMin: -30)
        let c = DisplayFormatter.claude(state: .idleFallback, snapshot: expired,
                                        forecast: nil, staleAsOf: now.addingTimeInterval(-3600),
                                        now: now)
        XCTAssertEqual(c.header?.heroText, "——")
        XCTAssertEqual(c.header?.verdict?.line1, "—")
        // The five-hour side is unknown while the weekly data survives, once, in Other Limits.
        XCTAssertNil(c.header?.limit?.usedPercent)
        XCTAssertEqual(c.otherLimits?.rows.first { $0.id == .secondaryWindow }?.value, "86%")
    }

    // MARK: Obsolete not-started claim withdrawn (REV-31/D-26 — STEP_38; re-keyed REV-80 / D-101)

    /// The not-started shape every D-26 case below starts from (REV-80): 0%, no reset, 18 000 s.
    private func notStarted() -> QuotaSnapshot {
        snapshot(used: 0, resetsInMin: nil, windowSeconds: 18_000)
    }

    /// The E2 display regression test (2026-07-14 incident): local burn resumed while the app
    /// was frozen on a stale not-started snapshot, and the popover kept asserting the window was
    /// empty for ~30 minutes. Local activity postdating the snapshot falsifies that claim — the
    /// unknown form renders, with nothing asserted in its place. Since REV-80 the snapshot
    /// carries a `100%`-shaped percent, which is exactly what must **not** reach the hero here.
    func testStaleNotStartedWithLocalActivityAfterPollRendersUnknownForm() {
        let asOf = now.addingTimeInterval(-15 * 60)
        let c = DisplayFormatter.claude(
            state: .idleFallback, snapshot: notStarted(), forecast: nil,
            localAttribution: attribution(lastActivity: asOf.addingTimeInterval(300)),
            staleAsOf: asOf, now: now)
        XCTAssertEqual(c.header?.verdict?.line1, "—",
                       "a falsified claim is withdrawn — never \"No active session\", never 100%")
        XCTAssertEqual(c.header?.verdict?.line2, "—",
                       "nothing is asserted in its place — no quota state inferred from JSONL")
        XCTAssertEqual(c.header?.verdict?.family, .unknown)
        XCTAssertEqual(c.header?.heroText, "——")
        XCTAssertTrue(c.header!.heroDetails.isEmpty,
                      "no `not started` line over a withdrawn claim")
        XCTAssertEqual(c.dot, .grey)
    }

    /// The D-26 degrade leaves every other stale-keep surface untouched: `· as of [t]` stamp,
    /// grey dot, live weekly rows, `—` 5-hour rows. (The expired window is R33-7-degraded to a
    /// nil percent before the test, so it takes the same unknown form as before REV-80.)
    func testObsoleteNullWindowKeepsAsOfStampAndWeeklyRows() {
        let asOf = now.addingTimeInterval(-3600)
        let expired = snapshot(resetsInMin: -30)   // R33-7-degraded null is null too
        let c = DisplayFormatter.claude(
            state: .idleFallback, snapshot: expired, forecast: nil,
            localAttribution: attribution(lastActivity: now.addingTimeInterval(-60)),
            staleAsOf: asOf, now: now)
        XCTAssertEqual(c.header?.verdict?.line1, "—")
        XCTAssertEqual(c.header?.sourceTag?.base,
                       "Source: Claude account · as of \(Fmt.clock(asOf))")
        // The five-hour side is unknown while the weekly data survives, once, in Other Limits.
        XCTAssertNil(c.header?.limit?.usedPercent)
        XCTAssertEqual(c.otherLimits?.rows.first { $0.id == .secondaryWindow }?.value, "86%")
    }

    /// The same, from the not-started shape (D-26 with a percent present): the 5-hour rows go
    /// `—` **together** with the hero, the weekly rows and the `as of` stamp survive.
    func testObsoleteNotStartedWindowRendersUnknownForm() {
        let asOf = now.addingTimeInterval(-3600)
        let c = DisplayFormatter.claude(
            state: .idleFallback, snapshot: notStarted(), forecast: nil,
            localAttribution: attribution(lastActivity: now.addingTimeInterval(-60)),
            staleAsOf: asOf, now: now)
        XCTAssertEqual(c.header?.heroText, "——")
        XCTAssertEqual(c.header?.verdict?.line1, "—")
        XCTAssertEqual(c.header?.sourceTag?.base,
                       "Source: Claude account · as of \(Fmt.clock(asOf))")
        XCTAssertNil(c.header?.limit?.usedPercent)
        XCTAssertTrue(c.header!.heroDetails.isEmpty,
                      "never `not started` over a withdrawn claim")
        XCTAssertEqual(c.otherLimits?.rows.first { $0.id == .secondaryWindow }?.value, "86%")
    }

    /// When local activity does NOT postdate the snapshot, the not-started claim stands — the
    /// stale card keeps `100%` and the caption (the STEP_102 ruling, both tools since REV-80);
    /// only the verdict is the idle `—`, as on any stale window.
    func testStaleNotStartedWithoutNewerLocalActivityKeepsTheClaim() {
        let asOf = now.addingTimeInterval(-15 * 60)
        let c = DisplayFormatter.claude(
            state: .idleFallback, snapshot: notStarted(), forecast: nil,
            localAttribution: attribution(lastActivity: asOf.addingTimeInterval(-300)),
            staleAsOf: asOf, now: now)
        XCTAssertEqual(c.header?.heroText, "100%")
        XCTAssertEqual(c.header?.limitCaption, "5-hour quota left")
        XCTAssertEqual(c.header?.heroDetails.map(\.text), ["not started"])
        XCTAssertNotEqual(c.header?.verdict?.family, .unknown)
    }

    /// The rule is age-independent (Baseline §9.3): on the live hold path the reference is
    /// `pollAsOf` — a live not-started render also withdraws once local activity postdates it.
    func testLiveNotStartedWithNewerLocalActivityRendersUnknownForm() {
        let polledAt = now.addingTimeInterval(-3 * 60)
        let c = DisplayFormatter.claude(
            state: .healthy, snapshot: notStarted(), forecast: nil,
            localAttribution: attribution(lastActivity: now.addingTimeInterval(-60)),
            pollAsOf: polledAt, now: now)
        XCTAssertEqual(c.header?.verdict?.line1, "—")
        XCTAssertEqual(c.header?.heroText, "——")
    }

    /// And the live render without newer activity is the calm not-started card — the live D-26
    /// negative, so the withdrawal cannot fire on every not-started poll.
    func testLiveNotStartedWithoutNewerLocalActivityKeepsTheClaim() {
        let polledAt = now.addingTimeInterval(-3 * 60)
        let c = DisplayFormatter.claude(
            state: .healthy, snapshot: notStarted(), forecast: nil,
            localAttribution: attribution(lastActivity: polledAt.addingTimeInterval(-60)),
            pollAsOf: polledAt, now: now)
        XCTAssertEqual(c.header?.heroText, "100%")
        XCTAssertEqual(c.header?.heroDetails.map(\.text), ["not started"])
    }

    /// D-26 is Claude-specific (Baseline §9.3): Codex null-window semantics are D1 territory,
    /// so "No active window" renders unconditionally.
    func testCodexNullWindowUnaffectedByNewerLocalActivity() {
        let asOf = now.addingTimeInterval(-15 * 60)
        let nullWindow = snapshot(tool: .codex, used: nil, resetsInMin: nil,
                                  extraUsage: nil)
        let c = DisplayFormatter.codex(
            state: .nullWindow, snapshot: nullWindow, forecast: nil,
            localAttribution: attribution(lastActivity: now.addingTimeInterval(-60)),
            staleAsOf: asOf, now: now)
        XCTAssertEqual(c.header?.verdict?.line1, "No active window")
    }

    // MARK: A stale/expired window ≠ empty; a rate-limit ≠ idle (REV-37 — STEP_41)

    /// The REV-37 regression test (2026-07-15): a stale window whose `resets_at` is past, with **no**
    /// local activity, must read the *unknown* form (`—`), never "No active session". The 5-hour
    /// window rolled over off-machine (Claude Web) — a trace D-26's local signal can never see — and
    /// for ~5 h the app confidently asserted emptiness while quota burned.
    func testStaleExpiredWindowWithoutLocalActivityRendersUnknownNotNoSession() {
        let asOf = now.addingTimeInterval(-60 * 60)
        let c = DisplayFormatter.claude(
            state: .idleFallback, snapshot: snapshot(resetsInMin: -30), forecast: nil,
            staleAsOf: asOf, now: now)
        XCTAssertEqual(c.header?.verdict?.line1, "—",
                       "expired-on-stale is unknown, not \"No active session\" (REV-37)")
        XCTAssertEqual(c.header?.heroText, "——")
        XCTAssertEqual(c.dot, .grey)
    }

    /// The fork does not depend on local activity: off-machine burn leaves no local trace, so even
    /// with (non-postdating) attribution present the expired-on-stale window still reads `—`.
    func testStaleExpiredWindowUnknownRegardlessOfLocalActivity() {
        let asOf = now.addingTimeInterval(-60 * 60)
        let c = DisplayFormatter.claude(
            state: .idleFallback, snapshot: snapshot(resetsInMin: -30), forecast: nil,
            localAttribution: attribution(lastActivity: asOf.addingTimeInterval(-300)),
            staleAsOf: asOf, now: now)
        XCTAssertEqual(c.header?.verdict?.line1, "—")
    }

    /// A rate-limited freeze is *reconnecting*, not idle (D-33): on the stale null/expired path the
    /// verdict reads "Reconnecting…", grey — the throttle wins over the generic unknown form. No
    /// transport wording leaks (§1.4 / §10 copy ban) — this describes session state.
    func testRateLimitedFreezeRendersReconnectingClaude() {
        let asOf = now.addingTimeInterval(-15 * 60)
        let c = DisplayFormatter.claude(
            state: .idleFallback, snapshot: snapshot(resetsInMin: -30), forecast: nil,
            staleAsOf: asOf, freezeReason: .rateLimited(retryAfter: 600), now: now)
        XCTAssertEqual(c.header?.verdict?.line1, "Reconnecting…")
        XCTAssertEqual(c.header?.verdict?.line2, "—")
        XCTAssertEqual(c.header?.heroText, "——")
        XCTAssertEqual(c.dot, .grey)
    }

    /// STEP_166 item 2: the D-33 fork also wins with **cached data** — Idle/fallback past the TTL
    /// with a still-valid window used to read the generic `—` / `—` idle row while the freeze was a
    /// throttle (twice on 2026-09-06, two bare dashes under a grey header). "Reconnecting…" is the
    /// honest line; the kept percent and the `as of` stamp stay beneath it.
    func testRateLimitedFreezeRendersReconnectingOverIdleDashesWithCachedData() {
        let asOf = now.addingTimeInterval(-15 * 60)
        let c = DisplayFormatter.claude(
            state: .idleFallback, snapshot: snapshot(used: 35, resetsInMin: 90), forecast: nil,
            staleAsOf: asOf, freezeReason: .rateLimited(retryAfter: 0), now: now)
        XCTAssertEqual(c.header?.verdict?.line1, "Reconnecting…")
        XCTAssertEqual(c.header?.verdict?.line2, "—")
        XCTAssertEqual(c.header?.verdict?.family, .reconnecting)
        XCTAssertEqual(c.header?.heroText, "65%", "cached data is kept — only the verdict changes")
        XCTAssertEqual(c.dot, .grey)
        // The no-freeze twin keeps the idle row: the fork is the freeze reason, not staleness.
        let plain = DisplayFormatter.claude(
            state: .idleFallback, snapshot: snapshot(used: 35, resetsInMin: 90), forecast: nil,
            staleAsOf: asOf, now: now)
        XCTAssertEqual(plain.header?.verdict?.line1, "—")
    }

    /// Codex parity — same fork, "Reconnecting…" over "No active window".
    func testRateLimitedFreezeRendersReconnectingCodex() {
        let asOf = now.addingTimeInterval(-15 * 60)
        let x = DisplayFormatter.codex(
            state: .nullWindow, snapshot: snapshot(tool: .codex, used: nil, resetsInMin: nil,
                                                   extraUsage: nil),
            forecast: nil, staleAsOf: asOf, freezeReason: .rateLimited(retryAfter: 600), now: now)
        XCTAssertEqual(x.header?.verdict?.line1, "Reconnecting…")
    }

    /// Non-rate-limit freeze reasons fall through to the existing copy: a `.reauthRequired` freeze
    /// on the Enterprise absent-object null window (not expired, no postdating activity) is still
    /// the legitimate "No active session" — only `.rateLimited` / `.credentialExpired` are
    /// distinguished. (REV-80 narrowed that string to the absent-object shape; a stale
    /// not-started window under the same freeze keeps its `100%` claim instead.)
    func testNonRateLimitFreezeKeepsExistingNullCopy() {
        let asOf = now.addingTimeInterval(-15 * 60)
        let c = DisplayFormatter.claude(
            state: .idleFallback, snapshot: snapshot(used: nil, resetsInMin: nil), forecast: nil,
            staleAsOf: asOf, freezeReason: .reauthRequired, now: now)
        XCTAssertEqual(c.header?.verdict?.line1, "No active session")
        let n = DisplayFormatter.claude(
            state: .idleFallback, snapshot: notStarted(), forecast: nil,
            staleAsOf: asOf, freezeReason: .reauthRequired, now: now)
        XCTAssertEqual(n.header?.heroText, "100%")
    }

    /// D-33 re-keyed (REV-80 / D-101): a rate-limited freeze over a stale **not-started** window
    /// is still "Reconnecting…" over a `——` hero — the freeze fork moved with the trigger's
    /// field, so a throttled hold never asserts a confident `100%`.
    func testRateLimitedFreezeOverNotStartedRendersReconnecting() {
        let asOf = now.addingTimeInterval(-15 * 60)
        let c = DisplayFormatter.claude(
            state: .idleFallback, snapshot: notStarted(), forecast: nil,
            staleAsOf: asOf, freezeReason: .rateLimited(retryAfter: 600), now: now)
        XCTAssertEqual(c.header?.verdict?.line1, "Reconnecting…")
        XCTAssertEqual(c.header?.heroText, "——")
        XCTAssertEqual(c.dot, .grey)
    }

    /// Cross-surface invariant (Baseline §19): for one stale + `.rateLimited` + expired input the
    /// popover reads "Reconnecting…" while the menu bar shows the grey non-asserting `——` — neither
    /// claims a session. The bar gets no distinct rate-limit glyph (§1.4 / §10 copy ban); it agrees
    /// because "Reconnecting…" only ever renders when the window is null/expired, which the bar
    /// already degrades to `——`.
    func testRateLimitedFreezeCrossSurfaceAgreement() {
        let asOf = now.addingTimeInterval(-15 * 60)
        let expired = snapshot(resetsInMin: -30)
        let popover = DisplayFormatter.claude(
            state: .idleFallback, snapshot: expired, forecast: nil,
            staleAsOf: asOf, freezeReason: .rateLimited(retryAfter: 600), now: now)
        let bar = DisplayFormatter.staleMenuBar(tool: .claude, snapshot: expired, now: now)
        XCTAssertEqual(popover.header?.verdict?.line1, "Reconnecting…")
        XCTAssertEqual(bar.percentText, "——", "the bar shows no percent from an expired window")
        XCTAssertEqual(bar.dot, .grey, "grey non-asserting form — no distinct rate-limit glyph")
    }

    /// An expired sign-in reads as itself (D-38 — STEP_49): on the stale null/expired path a
    /// `.credentialExpired` freeze reads "Claude sign-in expired — open Claude Code to reconnect.",
    /// grey — waiting cannot recover it, so the line names the fix. Auth-state honesty, not
    /// polling mechanics (§1.4 / §10 copy ban intact). Wins over the `.rateLimited` "Reconnecting…".
    func testCredentialExpiredFreezeRendersSigninExpiredClaude() {
        let asOf = now.addingTimeInterval(-15 * 60)
        let c = DisplayFormatter.claude(
            state: .idleFallback, snapshot: snapshot(resetsInMin: -30), forecast: nil,
            staleAsOf: asOf, freezeReason: .credentialExpired, now: now)
        XCTAssertEqual(c.header?.verdict?.line1,
                       "Claude sign-in expired — open Claude Code to reconnect.")
        XCTAssertEqual(c.header?.verdict?.line2, "—")
        XCTAssertEqual(c.header?.heroText, "——")
        XCTAssertEqual(c.dot, .grey)
    }

    /// Cross-surface invariant (Baseline §19) for the sign-in-expired freeze: popover carries the
    /// D-38 line while the menu bar stays the grey non-asserting `——` — no new bar glyph/copy.
    func testCredentialExpiredFreezeCrossSurfaceAgreement() {
        let asOf = now.addingTimeInterval(-15 * 60)
        let expired = snapshot(resetsInMin: -30)
        let popover = DisplayFormatter.claude(
            state: .idleFallback, snapshot: expired, forecast: nil,
            staleAsOf: asOf, freezeReason: .credentialExpired, now: now)
        let bar = DisplayFormatter.staleMenuBar(tool: .claude, snapshot: expired, now: now)
        XCTAssertEqual(popover.header?.verdict?.line1,
                       "Claude sign-in expired — open Claude Code to reconnect.")
        XCTAssertEqual(bar.percentText, "——")
        XCTAssertEqual(bar.dot, .grey, "grey non-asserting form — no distinct sign-in glyph")
    }

    /// The 2026-08-02 → 08-07 blackout, reproduced from the live `quota_series` rows (REV-58 §1,
    /// STEP_86 task 4). The last successful Claude poll was 08-01 18:23:37Z at 11%, with the
    /// 5-hour window resetting at 18:40:00Z — **17 minutes later**. Six days on, the card is asked
    /// to render that snapshot under a `.credentialExpired` freeze.
    ///
    /// This is the empirical check D-56 was gated on: does a multi-day credential gate actually
    /// drive `util` to nil? It does — the stale path degrades a window whose reset has passed — so
    /// the existing D-38 copy already wins and **no display change ships**. The test stays as the
    /// regression pin, because the conclusion depends on that degradation continuing to happen.
    func testMultiDayCredentialGateRendersSigninExpiredNotAStaleNumber() {
        let lastPoll = now
        let sixDaysLater = now.addingTimeInterval(6 * 86400)
        // 11% with 17 minutes left on the window, exactly as recorded on 2026-08-01.
        let frozen = snapshot(used: 11, resetsInMin: 17)

        let c = DisplayFormatter.claude(
            state: .idleFallback, snapshot: frozen, forecast: nil,
            staleAsOf: lastPoll, freezeReason: .credentialExpired, now: sixDaysLater)

        XCTAssertEqual(c.header?.verdict?.line1,
                       "Claude sign-in expired — open Claude Code to reconnect.",
                       "a six-day-old reading must not be presented as an answer")
        XCTAssertEqual(c.header?.heroText, "——", "the expired window degrades to unknown, not 11%")
        XCTAssertEqual(c.dot, .grey)
    }

    func testStaleMenuBarKeepsPercentGreyNoTimeSlot() {
        let m = DisplayFormatter.staleMenuBar(tool: .claude, snapshot: snapshot(), now: now)
        XCTAssertEqual(m.percentText, "62%")
        XCTAssertEqual(m.dot, .grey)
        XCTAssertNil(m.timeSlot, "a cached countdown would lie")
        // Expired primary degrades to the null form.
        let expired = DisplayFormatter.staleMenuBar(tool: .claude,
                                                    snapshot: snapshot(resetsInMin: -30), now: now)
        XCTAssertEqual(expired.percentText, "——")
        XCTAssertEqual(expired.timeSlot, "est")
    }

    // MARK: Stale hard block (REV-33 — STEP_39)

    /// The target card of the 2026-07-14 incident: red hero, "Stopped — quota returns at [t]",
    /// block banner, honest `· as of [t]`, `—` runway/burn. The verdict is current; the numbers
    /// behind it are stamped with their real age. The self-contradicting grey-hero/red-row card
    /// is impossible to produce: the dot, verdict, and banner all key off the same state.
    func testStaleHardBlockRendersFullBlockPresentation() {
        let asOf = now.addingTimeInterval(-4 * 60)
        let blocked = snapshot(used: 100, resetsInMin: 26, reached: true)
        let c = DisplayFormatter.claude(state: .overQuota, snapshot: blocked,
                                        forecast: nil, staleAsOf: asOf, now: now)
        XCTAssertEqual(c.dot, .red, "a stale hard block is critical, not calm")
        XCTAssertEqual(c.header?.verdict?.line1,
                       "Stopped — quota returns at \(Fmt.clock(now.addingTimeInterval(26 * 60)))")
        XCTAssertEqual(c.header?.verdict?.colour, .red)
        XCTAssertNotNil(c.recommendation, "the block banner renders on the stale path")
        XCTAssertTrue(c.recommendation?.contains("blocked until the 5-hour window resets") == true)
        // Stale-keep honesty is unchanged: `as of` tag, `—` runway/burn. The pill is the plan
        // name alone in every state now (D-49); staleness rides `badgeKind`.
        XCTAssertEqual(c.header?.sourceTag?.base,
                       "Source: Claude account · as of \(Fmt.clock(asOf))")
        XCTAssertEqual(c.header?.planBadge, "Pro")
        XCTAssertEqual(c.header?.badgeKind, .stale)
    }

    /// D-30 through the full stale path (E-series companion): a stale/restored accruing
    /// snapshot keeps its verdict and `$` glyph prefix — util ≥ 100 with credits on is the same
    /// monotone fact as the block — while the detail degrades dollarless and the source tag
    /// carries the honest `· as of [t]`.
    func testStaleAccruingKeepsVerdictDropsMoneyTokens() {
        let asOf = now.addingTimeInterval(-4 * 60)
        let paying = snapshot(used: 100, resetsInMin: 26, reached: true,
                              extraUsage: extra(enabled: true))
        let c = DisplayFormatter.claude(state: .overQuota, snapshot: paying,
                                        forecast: nil, staleAsOf: asOf, now: now)
        XCTAssertEqual(c.header?.verdict?.line1, "Running on credits — every token costs now")
        XCTAssertEqual(c.header?.verdict?.moneyPrefix, true)
        XCTAssertEqual(c.header?.verdict?.line2,
                       "over quota · resets \(Fmt.clock(now.addingTimeInterval(26 * 60))) · in 26m")
        XCTAssertFalse(c.header?.verdict?.line2?.contains("$") ?? true,
                       "a stale spend figure invites decisions on old data")
        XCTAssertEqual(c.header?.sourceTag?.base,
                       "Source: Claude account · as of \(Fmt.clock(asOf))")
    }

    /// Every non-block state still greys out on the stale path (the STEP_32 rule, unamended
    /// for warnings) — only the hard block keeps its colour.
    func testStaleNonBlockStatesStayGrey() {
        for state in [AppState.idleFallback, .atRisk, .badTiming, .elevated] {
            let c = DisplayFormatter.claude(state: state, snapshot: snapshot(),
                                            forecast: nil,
                                            staleAsOf: now.addingTimeInterval(-900), now: now)
            XCTAssertEqual(c.dot, .grey, "stale \(state.rawValue) must stay grey")
        }
    }

    /// §1.2 v5.0 note: a stale hard block keeps its red dot and percent in the menu bar too —
    /// only the time slot degrades; every other stale state greys out (previous test block).
    func testStaleMenuBarHardBlockKeepsRedDotAndPercent() {
        let blocked = snapshot(used: 100, resetsInMin: 26, reached: true)
        let m = DisplayFormatter.staleMenuBar(tool: .claude, state: .overQuota,
                                              snapshot: blocked, now: now)
        XCTAssertEqual(m.dot, .red)
        XCTAssertEqual(m.percentText, "0%", "over quota reads 0% left (D-97)")
        XCTAssertNil(m.timeSlot, "a cached countdown would still lie")
    }

    /// A hard-block state whose window has already expired degrades to the null form even in
    /// the menu bar — the engine would never classify it, but the formatter must not trust that.
    func testStaleMenuBarHardBlockWithExpiredWindowDegrades() {
        let expired = snapshot(used: 100, resetsInMin: -30, reached: true)
        let m = DisplayFormatter.staleMenuBar(tool: .claude, state: .overQuota,
                                              snapshot: expired, now: now)
        XCTAssertEqual(m.dot, .grey)
        XCTAssertEqual(m.percentText, "——")
    }
}

// MARK: - Explanation-layer row tags (STEP_111 — UI Spec Part 3 §5.2)

final class DisplayFormatterExplanationTagTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(tool: Tool, windowSeconds: Int? = nil, secondary: Bool = true) -> QuotaSnapshot {
        QuotaSnapshot(tool: tool, primaryUsedPct: 40,
                      primaryResetsAt: now.addingTimeInterval(3600),
                      primaryWindowSeconds: windowSeconds,
                      secondaryUsedPct: secondary ? 12 : nil,
                      secondaryResetsAt: secondary ? now.addingTimeInterval(4 * 86400) : nil,
                      rateLimitReached: false, extraUsage: .disabled, planType: "Pro")
    }

    private func tags(_ rows: [LabeledRow]) -> [String: ExplanationElement?] {
        Dictionary(rows.map { ($0.label, $0.explanation) }, uniquingKeysWith: { first, _ in first })
    }

    func testQuotaRowsAreTaggedOnBothTools() {
        let claude = tags(DisplayFormatter.quotaRows(state: .healthy, snapshot: snapshot(tool: .claude), now: now))
        XCTAssertEqual(claude["5-hour left"], .primaryWindow)
        XCTAssertEqual(claude["Resets at"], .reset)
        XCTAssertEqual(claude["Weekly left"], .secondaryWindow)
        XCTAssertEqual(claude["Weekly resets"], .weeklyReset)

        // A width-named Codex primary row keeps E-01 whatever its label reads.
        let codex = tags(DisplayFormatter.quotaRows(state: .healthy,
                                                    snapshot: snapshot(tool: .codex, windowSeconds: 7 * 86400,
                                                                       secondary: false),
                                                    now: now))
        XCTAssertEqual(codex["Weekly left"], .primaryWindow)
        XCTAssertEqual(codex["Resets at"], .reset)
    }

    /// The model-scoped weekly row carries E-22 whatever the model is called; its rare sibling
    /// reset row stays inert (STEP_134/D-94 — the E-number that step deferred).
    func testScopedWeeklyLimitRowCarriesE22() {
        let rows = DisplayFormatter.quotaRows(
            state: .healthy, snapshot: snapshot(tool: .claude), now: now,
            scopedLimits: [AdditionalRateLimit(id: nil, name: "Fable", usedPercent: 10,
                                               resetsAt: now.addingTimeInterval(4 * 86400))])
        XCTAssertEqual(tags(rows)["Fable left"], .scopedLimit)
        // The all-models weekly row above keeps its own element — two rows, two concepts.
        XCTAssertEqual(tags(rows)["Weekly left"], .secondaryWindow)
    }

    private func attribution(tool: Tool) -> LocalAttribution {
        LocalAttribution(project: "/p", model: nil, surfaceBucket: tool == .codex ? "Desktop" : nil,
                         subagentCount: 0, cacheHitRatio: 0.5,
                         estValue: EstimatedValueEngine.WindowValue(weekly: 2, thirtyDay: 3),
                         surfaceShares: [], tokensPerMinute: 1000, lastActivityAt: now,
                         sessionCount: 2, windowValue: 1)
    }

    func testValueRowsCacheHitAndCreditsAreTagged() {
        // The daily local section carries the cache-hit and value elements since STEP_178 — the
        // two-part local card that used to is gone. The tags themselves are unchanged.
        let claude = DisplayFormatter.claude(state: .healthy, snapshot: snapshot(tool: .claude),
                                             forecast: nil,
                                             localAttribution: attribution(tool: .claude), now: now)
        XCTAssertEqual(claude.localActivity?.valueRows.map(\.label), ["Today", "7-day", "30-day"])
        XCTAssertEqual(LocalActivitySection.cacheHitLabel, "Cache hit")

        let credits = DisplayFormatter.creditsCard(
            snapshot: QuotaSnapshot(tool: .claude, primaryUsedPct: 40, primaryResetsAt: now.addingTimeInterval(3600),
                                    secondaryUsedPct: nil, secondaryResetsAt: nil, rateLimitReached: false,
                                    extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: 2000, usedCredits: 3.2,
                                                           utilization: nil, currency: "usd",
                                                           disabledReason: nil, usedCreditsIsCached: false),
                                    planType: "Pro"),
            forecast: nil, pollAsOf: now, staleAsOf: nil, now: now)
        XCTAssertEqual(credits?.status.explanation, .usageCredits)
    }

    // MARK: The Enterprise monthly elements (E-15…E-21 — REV-75/D-89, STEP_128)

    /// A monthly snapshot with the attribution split populated, so all six rows render — the
    /// REV-47 §2.1 worked example in minor units ($69.16 of $120.00).
    private func monthlySnapshot(tool: Tool, usedAmount: Double? = nil) -> QuotaSnapshot {
        let limit = usedAmount.map {
            MonthlyLimit(limitAmount: 12000, usedAmount: $0,
                         remainingPercent: Int((100 - ($0 / 12000 * 100)).rounded()),
                         resetsAt: now.addingTimeInterval(14 * 86_400),
                         unit: .money(currency: "USD", exponent: 2),
                         source: "derived_calendar_month_utc")
        } ?? monthlyLimit
        return QuotaSnapshot(tool: tool, primaryUsedPct: nil, primaryResetsAt: nil,
                             secondaryUsedPct: nil, secondaryResetsAt: nil,
                             rateLimitReached: nil, extraUsage: nil,
                             monthlyLimit: limit, planType: "enterprise")
    }

    private var monthlyLimit: MonthlyLimit {
        MonthlyLimit(limitAmount: 12000, usedAmount: 6916, remainingPercent: 42,
                     resetsAt: now.addingTimeInterval(14 * 86_400),
                     unit: .money(currency: "USD", exponent: 2),
                     source: "derived_calendar_month_utc")
    }

    private func monthlySplit() -> MonthlyAttribution {
        MonthlyAttribution(localAmount: 4286, offMachineAmount: 1962,
                           unattributedAmount: 668, usedAmount: 6916)
    }

    /// The monthly meter's own elements after the STEP_178 cutover: E-15 on the hero (or on its
    /// `OTHER LIMITS` row), E-16 on the organisation-and-pace line, E-17 on the reset line of that
    /// row. **E-18 and E-20 retired with the split rows they explained** (user ruling
    /// 2026-09-10): the header states what left the account and what this Mac did not explain,
    /// and neither `This machine` nor `Unattributed` has a home on the approved composition.
    func testMonthlyElementsAfterTheCutover() {
        for tool in [Tool.claude, .codex] {
            let state = tool == .claude
                ? DisplayFormatter.claude(state: .nullWindow, snapshot: monthlySnapshot(tool: tool),
                                          forecast: nil, monthlyAttribution: monthlySplit(),
                                          monthlyRatePerHour: 4.1,
                                          now: now).header
                : DisplayFormatter.codex(state: .nullWindow, snapshot: monthlySnapshot(tool: tool),
                                         forecast: nil, monthlyAttribution: monthlySplit(),
                                         monthlyRatePerHour: 4.1,
                                         now: now).header
            XCTAssertEqual(state?.heroExplanation, .monthlyUsed, "\(tool)")
            XCTAssertEqual(state?.heroDetails.map(\.explanation), [.monthlyPace], "\(tool)")
            XCTAssertEqual(state?.accountBurn?.explanation, .spendRate, "\(tool)")
            XCTAssertEqual(state?.notSeenLocally?.explanation, .monthlyOffMachine, "\(tool)")
        }
    }

    func testHeroCarriesE15OnTheMonthlyLayoutAndE04Otherwise() {
        let monthly = DisplayFormatter.header(tool: .claude, state: .healthy,
                                              snapshot: monthlySnapshot(tool: .claude),
                                              forecast: nil, now: now)
        XCTAssertEqual(monthly.heroExplanation, .monthlyUsed)
        // A populated window takes the hero back, and E-04 with it (window precedence, D-34/D-36).
        let windowed = DisplayFormatter.header(tool: .claude, state: .healthy,
                                               snapshot: snapshot(tool: .claude),
                                               forecast: nil, now: now)
        XCTAssertEqual(windowed.heroExplanation, .heroPercent)
    }

    func testBurnFactCarriesE21OnTheMonthlyLayoutAndE05Otherwise() {
        let monthly = DisplayFormatter.claude(state: .nullWindow,
                                              snapshot: monthlySnapshot(tool: .claude),
                                              forecast: nil, monthlyRatePerHour: 4.10, now: now)
        XCTAssertEqual(monthly.header?.accountBurn?.explanation, .spendRate)
        let windowed = DisplayFormatter.claude(state: .healthy, snapshot: snapshot(tool: .claude),
                                               forecast: forecast(.claude, runway: nil, burn: 0.2),
                                               now: now)
        XCTAssertEqual(windowed.header?.accountBurn?.explanation, .burn)
    }

    // MARK: The live lines (E-01/02/04/07/08/12 — REV-75/D-88 + D-90, STEP_130)

    private func live(_ rows: [LabeledRow], _ label: String) -> ExplanationLive? {
        rows.first { $0.label == label }?.explanationLive
    }

    private func forecast(_ tool: Tool, runway: Double?, burn: Double?) -> Forecast {
        Forecast(tool: tool, tier: .fullRunway, runwayMinutes: runway, burnRatePerMin: burn,
                 isEstimate: false, pollCount: 10, burnSpanMinutes: 12)
    }

    /// E-01 fills from `primaryWindowStart` — the one window-anchor derivation (REV-60) — and is
    /// the **same value** on the primary row and the D-58 caption, never derived twice.
    func testPrimaryWindowLiveIsOneValueOnTwoSurfaces() {
        let snap = snapshot(tool: .claude)   // resets +1h, so a 5-hour window started 4h ago
        let rows = DisplayFormatter.quotaRows(state: .healthy, snapshot: snap, now: now)
        let header = DisplayFormatter.header(tool: .claude, state: .healthy, snapshot: snap,
                                             forecast: nil, now: now)
        let line = live(rows, "5-hour left")
        XCTAssertNotNil(line?.text)
        XCTAssertTrue(line!.text!.hasPrefix("*This one started at "))
        XCTAssertFalse(line!.text!.contains("["))
        XCTAssertEqual(header.windowScopeLive, line)
    }

    /// The unanchored shape takes `.notStarted` on **both** tools (REV-80 / D-101 gave the Claude
    /// cell the Codex string; until then it was `—` and self-dropped as `.noTemplate`). Never
    /// gated on the tool (the STEP_85 lesson: `quotaRows` is shared).
    func testUnanchoredWindowTakesNotStartedOnBothTools() {
        let unanchored = QuotaSnapshot(tool: .codex, primaryUsedPct: 0, primaryResetsAt: nil,
                                       primaryWindowSeconds: 30 * 86_400,
                                       secondaryUsedPct: nil, secondaryResetsAt: nil,
                                       rateLimitReached: false)
        XCTAssertEqual(DisplayFormatter.primaryWindowLive(snapshot: unanchored, now: now).text,
                       "*Not started yet — your first turn starts the clock.*")
        let claudeShape = QuotaSnapshot(tool: .claude, primaryUsedPct: 0, primaryResetsAt: nil,
                                        primaryWindowSeconds: 18_000,
                                        secondaryUsedPct: nil, secondaryResetsAt: nil,
                                        rateLimitReached: false)
        XCTAssertEqual(DisplayFormatter.primaryWindowLive(snapshot: claudeShape, now: now).text,
                       "*Not started yet — your first turn starts the clock.*")
        XCTAssertEqual(DisplayFormatter.primaryWindowLive(snapshot: nil, now: now),
                       .dropped(.noWindow))
    }

    /// E-02 names whichever window is tighter, read from the two readings themselves since
    /// STEP_194 — `state == .weeklyElevated` used to stand in for that comparison and no longer
    /// exists. The card and the row are drawn from one derivation either way.
    func testSecondaryWindowLiveNamesWhicheverWindowIsTighter() {
        let snap = snapshot(tool: .claude)   // 40% primary, 12% weekly
        let calm = live(DisplayFormatter.quotaRows(state: .healthy, snapshot: snap, now: now),
                        "Weekly left")
        XCTAssertEqual(calm?.text,
                       "*Right now the 5-hour window is the tighter one — 60% left, against 88% on the weekly.*")
        // Under the amber floor, so the weekly has no tier to report and the card falls back to
        // the D-88 comparison.
        let weeklyTighter = QuotaSnapshot(
            tool: .claude, primaryUsedPct: 10, primaryResetsAt: now.addingTimeInterval(3600),
            primaryWindowSeconds: nil, secondaryUsedPct: 45,
            secondaryResetsAt: now.addingTimeInterval(4 * 86_400),
            rateLimitReached: false, extraUsage: .disabled, planType: "Pro")
        let tighter = live(DisplayFormatter.quotaRows(state: .healthy, snapshot: weeklyTighter,
                                                      now: now),
                           "Weekly left")
        XCTAssertEqual(tighter?.text,
                       "*Right now the weekly window is the tighter one — 55% left, against 90% on the 5-hour.*")
        // No weekly reading ⇒ the line goes, not a half-filled sentence.
        let none = live(DisplayFormatter.quotaRows(
                            state: .healthy,
                            snapshot: snapshot(tool: .claude, secondary: false), now: now),
                        "Weekly left")
        XCTAssertEqual(none, ExplanationLive.dropped(.noSecondary))
    }

    // MARK: The bridge line (§5.2 rule 8 — REV-77/D-97, STEP_139)

    /// Every element that shows a quota percentage opens its card with `[left]% left · [used]%
    /// used`, filled from the utilization it was drawn from; the rows that show no percentage
    /// carry none. The D-94 scoped row is covered by `DisplayFormatterScopedLimitsTests`.
    func testBridgeLineSitsOnEveryPercentageRowAndNowhereElse() {
        let rows = DisplayFormatter.quotaRows(state: .healthy, snapshot: snapshot(tool: .claude), now: now)
        let bridge = Dictionary(rows.map { ($0.label, $0.explanationBridge?.text) },
                                uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(bridge["5-hour left"], "*60% left · 40% used*")
        XCTAssertEqual(bridge["Weekly left"], "*88% left · 12% used*")
        XCTAssertNil(bridge["Resets at"] ?? nil)
        XCTAssertNil(bridge["Weekly resets"] ?? nil)
        // Null weekly ⇒ the line drops with the value, like any live line.
        let none = DisplayFormatter.quotaRows(state: .healthy,
                                              snapshot: snapshot(tool: .claude, secondary: false), now: now)
        XCTAssertEqual(none.first { $0.label == "Weekly left" }?.explanationBridge, .dropped(.noWindow))
    }

    /// The hero's bridge rides the figure the hero was drawn from — the window, or the monthly
    /// meter on the monthly layout — and, unlike E-04's live line, **survives staleness**: a
    /// stale hero still shows a percent, so its card still says what that percent is.
    func testHeroBridgeFollowsTheHeroFigureStaleOrMonthly() {
        let fresh = DisplayFormatter.header(tool: .claude, state: .healthy,
                                            snapshot: snapshot(tool: .claude), forecast: nil, now: now)
        XCTAssertEqual(fresh.heroText, "60%")
        XCTAssertEqual(fresh.heroBridge?.text, "*60% left · 40% used*")
        let stale = DisplayFormatter.header(tool: .claude, state: .healthy,
                                            snapshot: snapshot(tool: .claude), forecast: nil,
                                            staleAsOf: now.addingTimeInterval(-900), now: now)
        XCTAssertEqual(stale.heroLive, .dropped(.stale))
        XCTAssertEqual(stale.heroBridge?.text, "*60% left · 40% used*")
        let monthly = DisplayFormatter.header(tool: .claude, state: .healthy,
                                              snapshot: monthlySnapshot(tool: .claude),
                                              forecast: nil, now: now)
        XCTAssertEqual(monthly.heroExplanation, .monthlyUsed)
        XCTAssertEqual(monthly.heroText, "42%", "the monthly hero flips too — 58 used is 42 left")
        XCTAssertEqual(monthly.heroBridge?.text, "*42% left · 58% used*")
        // The `——` placeholder hero carries no bridge, as it carries no card.
        let empty = DisplayFormatter.header(tool: .claude, state: .nullWindow, snapshot: nil,
                                            forecast: nil, now: now)
        XCTAssertEqual(empty.heroText, "——")
        XCTAssertEqual(empty.heroBridge, .dropped(.noWindow))
    }

    /// One number, three surfaces (§0.1): hero, primary row and menu bar read the same remaining
    /// figure digit for digit — what the live DoD screenshot checks, pinned here.
    func testHeroRowAndMenuBarAgreeOnWhatIsLeft() {
        let snap = snapshot(tool: .claude)
        let header = DisplayFormatter.header(tool: .claude, state: .healthy, snapshot: snap,
                                             forecast: nil, now: now)
        let rows = DisplayFormatter.quotaRows(state: .healthy, snapshot: snap, now: now)
        let bar = DisplayFormatter.toolMenuBar(tool: .claude, state: .healthy, snapshot: snap,
                                               forecast: nil, now: now)
        XCTAssertEqual(header.heroText, "60%")
        XCTAssertEqual(rows.first?.value, header.heroText)
        XCTAssertEqual(bar.percentText, header.heroText)
        XCTAssertEqual(header.progress, 0.6, accuracy: 0.001)
    }

    /// E-04: a short window with a runway says remaining-as-time; a long one answers with the
    /// calendar; the monthly layout has no E-04 at all.
    func testHeroLivePicksItsVariantByShape() {
        let short = DisplayFormatter.header(tool: .claude, state: .healthy,
                                            snapshot: snapshot(tool: .claude),
                                            forecast: forecast(.claude, runway: 220, burn: 0.3),
                                            now: now)
        XCTAssertEqual(short.heroLive?.text,
                       "*About 3h40m of usage left at today's speed.*")
        // No runway on a short window drops the line (REV-77 retired `E-04·remaining`): the rule 8
        // bridge line already reads `60% left · 40% used`, so a second line saying it is noise.
        let cold = DisplayFormatter.header(tool: .claude, state: .healthy,
                                           snapshot: snapshot(tool: .claude), forecast: nil, now: now)
        XCTAssertEqual(cold.heroLive, ExplanationLive.dropped(.noRunway))
        XCTAssertEqual(cold.heroBridge?.text, "*60% left · 40% used*")
        // A weekly window: the calendar, named as a period rather than as a grain adjective.
        let weekly = DisplayFormatter.header(tool: .codex, state: .healthy,
                                             snapshot: snapshot(tool: .codex, windowSeconds: 7 * 86_400),
                                             forecast: nil, now: now)
        XCTAssertTrue(weekly.heroLive!.text!.contains("of the week gone"))
        // The verdict is self-judging over/under/on pace (2026-08-24) — "ahead of the calendar"
        // read as good news and named no subject.
        XCTAssertTrue(weekly.heroLive!.text!.contains("— you're"))
        XCTAssertTrue(weekly.heroLive!.text!.hasSuffix("pace.*"))
        // The monthly hero is E-15, so E-04's line is never fabricated. Since STEP_195 the slot
        // is E-15's own **tier** sentence where the limit has one (REV-96 §3.9) — the same line
        // the meter's `OTHER LIMITS` row reads, so the meter explains itself identically wherever
        // it is drawn — and the drop is what is left when it does not.
        // The amount is stated rather than defaulted: the shared fixture's 57.6 % at 53 % of the
        // month projects to 108 % and is **on pace** since REV-98 (STEP_200), so it no longer
        // reaches the branch this line is about.
        let monthly = DisplayFormatter.header(tool: .claude, state: .healthy,
                                              snapshot: monthlySnapshot(tool: .claude,
                                                                        usedAmount: 9_000),
                                              forecast: nil, now: now)
        XCTAssertTrue(monthly.heroLive!.text!.contains("of the month gone"))
        XCTAssertTrue(monthly.heroLive!.text!.contains("ahead of even pace"))
        // A monthly on pace has no tier sentence, and the hero says nothing rather than something
        // reassuring nobody asked for.
        let calmMonthly = DisplayFormatter.header(
            tool: .claude, state: .healthy,
            snapshot: monthlySnapshot(tool: .claude, usedAmount: 500), forecast: nil, now: now)
        XCTAssertEqual(calmMonthly.heroLive, .dropped(.monthlyLayout))
        // Stale: a remaining-as-time claim from a frozen reading is the D-35 confident claim.
        let stale = DisplayFormatter.header(tool: .claude, state: .healthy,
                                            snapshot: snapshot(tool: .claude), forecast: nil,
                                            staleAsOf: now.addingTimeInterval(-900), now: now)
        XCTAssertEqual(stale.heroLive, .dropped(.stale))
    }

    /// E-07 — the flagship subtraction, and the one case it refuses to print.
    func testOffMachineLiveShowsTheSubtractionOnlyWhenItReconciles() {
        let clean = WindowAttribution(offMachinePct: 1, localPct: 26, unattributedPct: 0,
                                      totalUsedPct: 27)
        XCTAssertEqual(DisplayFormatter.offMachineLive(clean, tool: .claude).text,
                       "*The account says 27% used, this Mac explains ≈26%, so ≈1% came from elsewhere.*")
        // A residual the app cannot attribute (REV-56/D-52) breaks the sentence's arithmetic on
        // screen — the line goes, the concept card stays.
        let residual = WindowAttribution(offMachinePct: 4, localPct: 20, unattributedPct: 3,
                                         totalUsedPct: 27)
        XCTAssertEqual(DisplayFormatter.offMachineLive(residual, tool: .claude),
                       .dropped(.noAttribution))
        let allLocal = WindowAttribution(offMachinePct: 0, localPct: 27, unattributedPct: 0,
                                         totalUsedPct: 27)
        XCTAssertEqual(DisplayFormatter.offMachineLive(allLocal, tool: .claude).text,
                       "*This window, everything the account shows is explained by this Mac.*")
        XCTAssertEqual(DisplayFormatter.offMachineLive(nil, tool: .claude),
                       .dropped(.noAttribution))
        // The quantity is the header's `Not seen locally` line since STEP_178, and on a monthly
        // meter it is the meter's own amount rather than a window share.
        let windowed = DisplayFormatter.claude(state: .healthy, snapshot: snapshot(tool: .claude),
                                               forecast: nil, offMachine: clean, now: now)
        XCTAssertEqual(windowed.header?.notSeenLocally?.value, "≈1% (est.)")
        let monthly = DisplayFormatter.claude(state: .nullWindow,
                                              snapshot: monthlySnapshot(tool: .claude),
                                              forecast: nil, offMachine: clean, now: now)
        XCTAssertEqual(monthly.header?.notSeenLocally?.intervalLabel, "Monthly")
    }

    /// E-08 is the whole card, one per family — and **nil** on every inert line 2, so STEP_133
    /// never records a drop for a target that has no card.
    func testVerdictDetailLiveIsWholeCardsAndNilWhenInert() {
        let safe = DisplayFormatter.headerVerdict(
            tool: .claude, state: .healthy, snapshot: snapshot(tool: .claude),
            forecast: forecast(.claude, runway: 220, burn: 0.3), now: now)
        XCTAssertTrue(safe!.detailLive!.text!.hasPrefix("**Runway.**"))
        XCTAssertTrue(safe!.detailLive!.text!.contains("so the reset comes first."))
        XCTAssertFalse(safe!.detailLive!.text!.contains("["))

        // Nothing burning: a measured zero, its own card, no runway needed.
        let calm = DisplayFormatter.headerVerdict(
            tool: .claude, state: .healthy, snapshot: snapshot(tool: .claude),
            forecast: forecast(.claude, runway: nil, burn: 0.0001), now: now)
        XCTAssertEqual(calm?.family, .nothingBurning)
        XCTAssertTrue(calm!.detailLive!.text!.contains("Nothing is burning right now"))

        // Measuring…: no burn yet, so no numbers — but still a card.
        let measuring = DisplayFormatter.headerVerdict(
            tool: .claude, state: .healthy, snapshot: snapshot(tool: .claude),
            forecast: nil, now: now)
        XCTAssertEqual(measuring?.family, .measuring)
        XCTAssertTrue(measuring!.detailLive!.text!.contains("Not measured yet"))

        // Every condition family: line 2 reads "—", so there is no card and no drop reason.
        for state in [AppState.idleFallback, .spendControl] {
            let verdict = DisplayFormatter.headerVerdict(tool: .claude, state: state,
                                                          snapshot: snapshot(tool: .claude),
                                                          forecast: nil, now: now)
            XCTAssertEqual(verdict?.line2, "—", "\(state)")
            XCTAssertNil(verdict?.detailLive, "\(state)")
        }
    }

    /// The two E-08 cards that reach the user through `.tagged(…)`, which carries one family for
    /// two concepts — so the variant is chosen inside the helper, not at the call site.
    func testOverQuotaAndCreditsCarryTheirOwnE08Cards() {
        let blocked = QuotaSnapshot(tool: .claude, primaryUsedPct: 100,
                                    primaryResetsAt: now.addingTimeInterval(3600),
                                    secondaryUsedPct: nil, secondaryResetsAt: nil,
                                    rateLimitReached: true, extraUsage: .disabled, planType: "Pro")
        let stopped = DisplayFormatter.headerVerdict(tool: .claude, state: .overQuota,
                                                      snapshot: blocked, forecast: nil, now: now)
        XCTAssertEqual(stopped?.family, .overQuota)
        XCTAssertTrue(stopped!.detailLive!.text!.hasPrefix("**Blocked.**"))
        XCTAssertTrue(stopped!.detailLive!.text!.contains("unless usage credits are on."))

        let accruing = QuotaSnapshot(
            tool: .claude, primaryUsedPct: 104, primaryResetsAt: now.addingTimeInterval(3600),
            secondaryUsedPct: nil, secondaryResetsAt: nil, rateLimitReached: true,
            extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: 2000, usedCredits: 3.2,
                                   utilization: nil, currency: "usd", disabledReason: nil,
                                   usedCreditsIsCached: false), planType: "Max")
        let credits = DisplayFormatter.headerVerdict(tool: .claude, state: .overQuota,
                                                     snapshot: accruing, forecast: nil, now: now)
        XCTAssertTrue(credits!.detailLive!.text!.hasPrefix("**On credits.**"))
        // Codex stops dead past 100% — no credits concept, so its cell is "—".
        let codexBlocked = QuotaSnapshot(tool: .codex, primaryUsedPct: 100,
                                         primaryResetsAt: now.addingTimeInterval(3600),
                                         secondaryUsedPct: nil, secondaryResetsAt: nil,
                                         rateLimitReached: true)
        let codex = DisplayFormatter.headerVerdict(tool: .codex, state: .overQuota,
                                                   snapshot: codexBlocked, forecast: nil, now: now)
        XCTAssertTrue(codex!.detailLive!.text!.hasPrefix("**Blocked.**"))
        XCTAssertFalse(codex!.detailLive!.text!.contains("usage credits"))
    }

    /// The monthly family: two of five returns carry a card, and `.tagged(.monthly)` must carry
    /// it through — the field is copied by hand there.
    func testMonthlyVerdictCardsSurviveTagging() {
        let verdict = DisplayFormatter.headerVerdict(tool: .claude, state: .healthy,
                                                     snapshot: monthlySnapshot(tool: .claude),
                                                     forecast: nil, now: now)
        XCTAssertEqual(verdict?.family, .monthly)
        XCTAssertTrue(verdict!.detailLive!.text!.hasPrefix("**Pace.**"))
        XCTAssertTrue(verdict!.detailLive!.text!.contains("before you reach $120.00"))
        XCTAssertFalse(verdict!.detailLive!.text!.contains("["))
    }

    /// E-12 says what the setting means for the user, which the bare `On` / `Off` does not.
    func testUsageCreditsLiveFollowsTheSetting() {
        func card(enabled: Bool, prepaidCents: Int?) -> CreditsCardSection? {
            DisplayFormatter.creditsCard(
                snapshot: QuotaSnapshot(
                    tool: .claude, primaryUsedPct: 40, primaryResetsAt: now.addingTimeInterval(3600),
                    secondaryUsedPct: nil, secondaryResetsAt: nil, rateLimitReached: false,
                    extraUsage: ExtraUsage(isEnabled: enabled, monthlyLimit: 2000, usedCredits: 3.2,
                                           utilization: nil, currency: "usd", disabledReason: nil,
                                           usedCreditsIsCached: false),
                    prepaid: prepaidCents.map { PrepaidCredits(amountCents: $0, autoReloadOn: false, asOf: now) },
                    planType: "Pro"),
                forecast: nil, pollAsOf: now, staleAsOf: nil, now: now)
        }
        XCTAssertEqual(card(enabled: false, prepaidCents: nil)?.status.explanationLive?.text,
                       "*Yours are off — at 100%, Claude stops and waits for the reset.*")
        XCTAssertEqual(card(enabled: true, prepaidCents: 4250)?.status.explanationLive?.text,
                       "*Yours are on — past 100%, work is paid from your $42.50 balance until the reset.*")
        // No prepaid reading: the balance is the sentence's subject, so the line goes.
        XCTAssertEqual(card(enabled: true, prepaidCents: nil)?.status.explanationLive,
                       .dropped(.noBalance))
    }

    func testSourceFreezeFollowsTheVerdictsFork() {
        XCTAssertEqual(DisplayFormatter.sourceFreeze(.rateLimited(retryAfter: 60), tool: .claude), .reconnecting)
        XCTAssertEqual(DisplayFormatter.sourceFreeze(.rateLimited(retryAfter: 60), tool: .codex), .reconnecting)
        XCTAssertEqual(DisplayFormatter.sourceFreeze(.credentialExpired, tool: .claude), .signInExpired)
        XCTAssertNil(DisplayFormatter.sourceFreeze(.credentialExpired, tool: .codex))
        XCTAssertNil(DisplayFormatter.sourceFreeze(.healthy, tool: .claude))
        XCTAssertNil(DisplayFormatter.sourceFreeze(nil, tool: .claude))
        // Threaded onto the display state so the tab's `ExplanationContext` can carry it.
        let state = DisplayFormatter.claude(state: .healthy, snapshot: snapshot(tool: .claude), forecast: nil,
                                            staleAsOf: now, freezeReason: .rateLimited(retryAfter: 0), now: now)
        XCTAssertEqual(state.sourceFreeze, .reconnecting)
        let codex = DisplayFormatter.codex(state: .healthy, snapshot: snapshot(tool: .codex, windowSeconds: 7 * 86400),
                                           forecast: nil, now: now)
        XCTAssertEqual(codex.windowGrain, "Weekly")
    }
}
