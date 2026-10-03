import Foundation

/// Usage-credits money state for the popover card (UI Spec §2.4a, Baseline §7.1, REV-29).
/// Purely **data-driven** from the `extra_usage` object (`is_enabled` × `used% vs 100`, plus the
/// §7.1 cached-value "last observed" cell). Contrast `MoneyGlyph`, which is **forecast-driven** —
/// the two are related but not identical (an armed card cell does not imply an armed glyph; the
/// glyph additionally needs `eta_to_100 < reset`). Display-only: never feeds StateEngine
/// classification, dominant-agent arbitration, or whether a notification fires (fork 3). It
/// does pick the over-quota banner's **copy** since STEP_221 (REV-102 §2.6).
public enum MoneyState: String, Sendable, Equatable {
    /// No `extra_usage` object at all (Enterprise / no pay-as-you-go) → the whole card is suppressed.
    case absent
    /// Credits on, `used% < 100` — headroom before any charge. Card status neutral (§2.4a.1).
    case armed
    /// Credits on, `used% ≥ 100` — real money leaving now. Card status red.
    case charging
    /// Credits off, `used% < 100` — a 100% crossing is a hard block, not a charge. The state the
    /// v4.7 `isEnabled || used>0` gate hid. Neutral; the sub-line goes amber when forecast-imminent.
    case noBackstop
    /// Credits off, `used% ≥ 100` — hard-blocked; block messaging is the header/hint's job.
    case blocked
    /// Credits toggled off mid-window with a cached non-zero `used_credits` (§7.1 cached-value rule).
    case lastObserved
    /// Credits on, `used_credits ≥ monthly_limit` — the cap is spent, nothing more can be charged
    /// (REV-102 / D-125, STEP_218). For every forecast question it is `noBackstop`: a 100%
    /// crossing is a hard stop. It differs only in copy. About a day later the provider reports
    /// the same fact as a switched-off meter — org-managed, off, `out_of_credits`, no amounts
    /// (REV-102 §6 item 1, STEP_222) — and that shape is this state too.
    case capReached
}

/// Menu-bar money glyph (UI Spec §1.6, REV-29). **Forecast-driven**, `is_enabled`-gated, Claude-only.
/// Rendered as an amber/red `$` appended after the time slot. Display-only (D-23).
public enum MoneyGlyph: String, Sendable, Equatable {
    case none
    /// `is_enabled` AND (`eta_to_100 < reset` OR `used% ≥ 98` no-burn fallback). Amber `$`.
    case armed
    /// `used% ≥ 100`. Red `$`.
    case charging

    /// Severity order for the §13.4-style hysteresis: escalate up immediately, demote down slowly.
    public var rank: Int {
        switch self {
        case .none: return 0
        case .armed: return 1
        case .charging: return 2
        }
    }
}

public enum MoneyModel {
    /// The `used% ≥ 98` no-burn arming fallback (§1.6): arms the glyph when a real burn rate is
    /// unavailable (cold start / near-zero burn) but the window is nearly spent.
    static let noBurnArmFloor = 98.0
    /// §1.6 burn floor: below this, `eta_to_100` is treated as ∞ (no forecast-driven arm). Distinct
    /// from `ForecastEngine.nearZeroBurnPerMin` (0.001), which governs the runway display.
    static let armBurnFloor = 0.05

    /// "A window is spent" — the five-hour **or** the weekly (REV-102 §2.2, STEP_218; was the
    /// primary alone). Credits start the moment either runs out, so the card and the glyph read
    /// one test.
    static func windowSpent(snapshot: QuotaSnapshot?) -> Bool {
        (snapshot?.primaryUsedPct ?? 0) >= StateEngine.overQuotaUtil
            || (snapshot?.secondaryUsedPct ?? 0) >= StateEngine.overQuotaUtil
    }

    /// Data-driven card state from the `extra_usage` object (§2.4a.1). `nil` extraUsage ⇒ `.absent`.
    public static func moneyState(snapshot: QuotaSnapshot?) -> MoneyState {
        guard let extra = snapshot?.extraUsage else { return .absent }
        let over = windowSpent(snapshot: snapshot)
        if extra.isEnabled {
            // Tested before charging/armed: a spent cap charges nothing, whatever the windows say.
            if let cap = extra.monthlyLimitMajor, let credits = extra.usedCredits, credits >= cap {
                return .capReached
            }
            return over ? .charging : .armed
        }
        // The organization's spent cap, a day on (STEP_222). Any other org-managed off is `Off`.
        if extra.managedByOrganization, extra.disabledReason == "out_of_credits" {
            return .capReached
        }
        // Off. A cached non-zero credits value means credits were on earlier this window (§7.1).
        if extra.usedCreditsIsCached, (extra.usedCredits ?? 0) > 0 {
            return .lastObserved
        }
        return over ? .blocked : .noBackstop
    }

    /// Finite minutes until `used%` reaches exactly 100 at the current pace, or `nil` when it
    /// cannot be stated (already ≥ 100, burn ≤ `armBurnFloor`, not the full-runway tier, or no
    /// burn data). Denominator is exactly 100 — the full-runway gate guarantees it (the inferred
    /// tier divides by a learned ceiling, §11). This is `eta_to_100` (§1.6), shared by the glyph
    /// and the §2.4a card so they read one number.
    public static func etaTo100Minutes(snapshot: QuotaSnapshot?, forecast: Forecast?) -> Double? {
        guard let used = snapshot?.primaryUsedPct, used < StateEngine.overQuotaUtil,
              forecast?.tier == .fullRunway,
              let burn = forecast?.burnRatePerMin, burn > armBurnFloor else { return nil }
        return (100 - used) / burn
    }

    /// Whether a 100% crossing is forecast before the window resets — the shared arming/imminence
    /// test, **ungated** by `is_enabled` (the glyph gates on top of it; the NO-BACKSTOP card reads
    /// it directly). True on the `≥ 98%` no-burn fallback (§1.6) or when `eta_to_100 < reset`.
    public static func isImminent(snapshot: QuotaSnapshot?, forecast: Forecast?, now: Date) -> Bool {
        let used = snapshot?.primaryUsedPct ?? 0
        if used >= noBurnArmFloor { return true }
        guard let eta = etaTo100Minutes(snapshot: snapshot, forecast: forecast),
              let resetsAt = snapshot?.primaryResetsAt else { return false }
        let minutesToReset = resetsAt.timeIntervalSince(now) / 60
        return minutesToReset > 0 && eta < minutesToReset
    }

    /// Forecast-driven, `is_enabled`-gated instantaneous glyph (§1.6) — before hysteresis. Reads
    /// the **same** shared `Forecast` and `isImminent` test the card reads, so the two surfaces
    /// cannot disagree for one window.
    public static func moneyGlyphInstant(
        snapshot: QuotaSnapshot?, forecast: Forecast?, now: Date
    ) -> MoneyGlyph {
        guard let extra = snapshot?.extraUsage, extra.isEnabled else { return .none }
        // A spent cap is `noBackstop` for the forecast side: nothing left to charge, no glyph.
        if moneyState(snapshot: snapshot) == .capReached { return .none }
        if windowSpent(snapshot: snapshot) { return .charging }
        return isImminent(snapshot: snapshot, forecast: forecast, now: now) ? .armed : .none
    }
}
