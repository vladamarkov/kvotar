import Foundation
import KvotarCore

/// The window `status` reports for a tool. A live 5-hour window wins; otherwise the monthly
/// (period-quota) window Codex business / Claude Enterprise accounts surface instead (§13 item 12,
/// where the 5-hour window is null by design). `nil` kind ⇒ no active window at all.
enum WindowKind: String { case fiveHour = "five_hour", monthly }

struct DisplayWindow {
    let kind: WindowKind?
    let usedPct: Double?
    let resetsAt: Date?
    /// Monthly runway (days to empty at the cycle's average pace). Stateless single-snapshot math
    /// (`MonthlyLimit.runwayDays`, §8.3 REV-38) — it needs no live burn buffer, unlike the 5-hour
    /// runway, so the CLI can show it in Phase A. `nil` for a 5-hour window or a fresh cycle.
    let runwayDays: Double?
    /// The REV-57 / REV-80 unanchored shape — a 5-hour window with a percent (0) and no reset
    /// because none has started. `detail` says why the reset is missing (`no window open`), the
    /// same words the popover's `Resets at` row uses.
    let notStarted: Bool
}

/// The small slice of the app's display grammar (UI Spec v5.7 §2.2a / §1.1) reimplemented for the
/// terminal. The full grammar (`Fmt` + `DisplayFormatter`) lives in `KvotarUI`, which the CLI
/// cannot depend on, so this reproduces only what `status` needs: the six user-facing state labels
/// (Product Brief v5), the duration/day/clock forms, and the staleness suffix. It never emits
/// polling-mechanics copy ("throttled" / "rate limited" / "backing off") — §1.4 / Baseline §10 ban.
enum CLIFormat {
    /// AppState's §13 ranks → the six labels the menu bar shows (Product Brief v5). Total for
    /// robustness, though a cold `.restore` forecast only ever yields the non-rate-derived subset.
    /// The two long-limit ranks (STEP_194) join the label their colour already matched: ahead of
    /// pace is amber like Elevated, nearly spent is red like At Risk.
    static func stateLabel(_ state: AppState) -> String {
        switch state {
        case .healthy: return "Healthy"
        case .elevated, .limitAheadOfPace, .fastBurnSpike, .offMachineBurn,
             .multiSurface: return "Elevated"
        case .atRisk, .badTiming, .limitNearlySpent: return "At Risk"
        case .overQuota, .spendControl: return "Over Quota"
        case .nullWindow: return "Pacing Only"
        case .idleFallback: return "Unknown"
        }
    }

    /// The window the headline reports: the live 5-hour window if present, else the monthly window,
    /// else none. Mirrors the app's §13 item-12 monthly-layout fallback so Codex business / Claude
    /// Enterprise accounts (null 5-hour by design) still get their real utilization.
    static func displayWindow(_ snapshot: QuotaSnapshot?, now: Date) -> DisplayWindow {
        guard let snapshot else { return DisplayWindow(kind: nil, usedPct: nil, resetsAt: nil, runwayDays: nil, notStarted: false) }
        if let primary = snapshot.primaryUsedPct {
            return DisplayWindow(kind: .fiveHour, usedPct: primary,
                                 resetsAt: snapshot.primaryResetsAt, runwayDays: nil,
                                 notStarted: snapshot.primaryWindowIsUnanchored)
        }
        if let monthly = snapshot.monthlyLimit {
            return DisplayWindow(kind: .monthly, usedPct: monthly.usedPercentExact,
                                 resetsAt: monthly.resetsAt, runwayDays: monthly.runwayDays(now: now),
                                 notStarted: false)
        }
        return DisplayWindow(kind: nil, usedPct: nil, resetsAt: nil, runwayDays: nil, notStarted: false)
    }

    /// `38%` — whole-percent, matching the menu bar. `––` when utilization is unknown.
    static func percent(_ pct: Double?) -> String {
        guard let pct else { return "––" }
        return "\(Int(pct.rounded()))%"
    }

    /// `1h52m` / `48m` — hours only when non-zero, minutes zero-padded to two digits when hours are
    /// present, no space (UI Spec §11 `durationHM`).
    static func durationHM(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval.rounded())) / 60
        let h = minutes / 60
        let m = minutes % 60
        return h > 0 ? "\(h)h\(String(format: "%02d", m))m" : "\(m)m"
    }

    /// `17d` / `31h` — the coarse day/hour scale the monthly slot uses (UI Spec `Fmt.dayScale`).
    static func dayScale(days: Double) -> String {
        days >= 1 ? "\(Int(days.rounded()))d" : "\(Int((days * 24).rounded()))h"
    }

    /// The detail cell for a tool's line: a runway (monthly) or reset countdown for the live window,
    /// else an honest fallback. Absent snapshot ⇒ `no data yet`; no active window ⇒ `no active
    /// window`; a not-started window ⇒ `no window open` (REV-80 / D-101); a null/expired reset ⇒ `—`.
    static func detail(window: DisplayWindow, hasSnapshot: Bool, now: Date) -> String {
        guard hasSnapshot else { return "no data yet" }
        guard let kind = window.kind else { return "no active window" }
        if window.notStarted { return "no window open" }
        if kind == .monthly, let runway = window.runwayDays {
            return "runway ~\(dayScale(days: runway))"
        }
        guard let resetsAt = window.resetsAt, resetsAt.timeIntervalSince(now) > 0 else { return "—" }
        let remaining = resetsAt.timeIntervalSince(now)
        return "resets in \(kind == .monthly ? dayScale(days: remaining / 86_400) : durationHM(remaining))"
    }

    /// `9:47 pm`, gaining a `MMM d,` prefix when the reading is not from today (UI Spec §2.2a
    /// `as of Jul 5, 11:32 pm`).
    static func clock(_ date: Date, now: Date) -> String {
        let f = DateFormatter()
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        f.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "h:mm a" : "MMM d, h:mm a"
        return f.string(from: date)
    }

    /// `12s ago` → `4m ago` → `2h ago` → `3d ago` — the fresh side of the §2.2a age grammar.
    static func relativeAge(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        if s < 60 { return "\(s)s ago" }
        let m = s / 60
        if m < 60 { return "\(m)m ago" }
        let h = m / 60
        return h < 24 ? "\(h)h ago" : "\(h / 24)d ago"
    }

    /// The freshness suffix appended to a tool's line: the age when the reading is fresh, or
    /// `· as of [clock]` once it has aged past the §9.3 TTL (UI Spec §2.2a). Empty when the tool was
    /// never polled (the detail cell already says `no data yet`).
    static func freshnessSuffix(polledAt: Date?, isStale: Bool, now: Date) -> String {
        guard let polledAt else { return "" }
        return isStale ? "· as of \(clock(polledAt, now: now))" : "· \(relativeAge(now.timeIntervalSince(polledAt)))"
    }
}
