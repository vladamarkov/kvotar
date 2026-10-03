import Foundation

/// One detected discontinuity — a before/after instant destined for a `discontinuity_events`
/// row (§17.1). Values are raw strings, typed at read by the owning component (the
/// `settings.value` precedent); `eventType` becomes a raw string at the storage boundary.
public struct DiscontinuityObservation: Sendable, Equatable {
    public enum EventType: String, Sendable {
        case limitChanged = "limit_changed"
        case planChanged = "plan_changed"
        case creditsToggled = "credits_toggled"
        case windowReset = "window_reset"
        /// A **live** window the provider took back (REV-64 §5 / STEP_102) — distinct from a reset,
        /// which is a window running its course. Observed 2026-08-13: a 3%-used weekly window
        /// vanished overnight with no user activity, and neither the *advanced* nor the *expired*
        /// clause fits, so nothing was recorded and the dead anchor became the "before" half of the
        /// next real reset. Kept a separate type deliberately: conflating "your window rolled over"
        /// with "your window was destroyed mid-flight" in the one table whose job is to tell them
        /// apart is what produced the fiction. **No migration** — `event_type` is `TEXT`.
        case windowDemolished = "window_demolished"
        case monthlyRollover = "monthly_rollover"
        /// The provider-side window facts (REV-69 §4 M1/M4 / D-76 — STEP_114). Facts, not
        /// inferences: each is a change the payload itself shows. **No migration** — `event_type`
        /// is `TEXT`. Semantics per Baseline §17.1: `windowAdded` old NULL / new width seconds;
        /// `windowRemoved` old width seconds / new NULL, `utilizationPct` = the last utilization
        /// the window carried; `windowWidthChanged` old/new width seconds; `earlyReset` old = the
        /// scheduled `resets_at`, new = the observed instant, `utilizationPct` = what was forgiven.
        case windowAdded = "window_added"
        case windowRemoved = "window_removed"
        case windowWidthChanged = "window_width_changed"
        case earlyReset = "early_reset"
    }

    public let eventType: EventType
    /// `"five_hour"` / `"weekly"` / `"monthly"`; nil for the account-scoped types.
    public let windowType: String?
    public let oldValue: String?
    public let newValue: String?
    /// Window utilization at the moment of the event — for `window_reset` this is
    /// utilization-at-crossing, the quota-waste histogram input.
    public let utilizationPct: Double?

    public init(eventType: EventType, windowType: String? = nil, oldValue: String? = nil,
                newValue: String? = nil, utilizationPct: Double? = nil) {
        self.eventType = eventType
        self.windowType = windowType
        self.oldValue = oldValue
        self.newValue = newValue
        self.utilizationPct = utilizationPct
    }

    /// The `window_type` column's name for a window of this width — **a read field, not a literal**
    /// (REV-64 §6 / STEP_102). Every `window_reset` row used to be stamped `"five_hour"` by a
    /// hardcoded string, for every tool and every width, violating the contract `windowType`'s own
    /// doc comment above declares.
    ///
    /// Callers pass `QuotaSnapshot.primaryWindowLength`, **never** `primaryWindowSeconds`: the
    /// former carries REV-60's five-hour fallback, which is Claude's true width (its usage endpoint
    /// reports none), so **Claude keeps the `five_hour` label it correctly has** while Codex stops
    /// borrowing it. That is the whole design constraint, and why this is a mapping rather than a
    /// special case per tool.
    ///
    /// Mirrors `DisplayFormatter.windowGrain` — same boundaries, same fall-backs — but the two
    /// vocabularies are deliberately different (`"5-hour"` there, `"five_hour"` here), so neither
    /// may call the other; that one is UI-only. `nil` means **no width claim**, the same
    /// load-bearing "say nothing" D-58 gives the display.
    public static func windowTypeName(seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        switch seconds {
        case 300 * 60:    return "five_hour"
        case 10_080 * 60: return "weekly"
        case 43_200 * 60: return "monthly"
        default:
            if seconds % 86_400 == 0, seconds >= 7 * 86_400 { return "\(seconds / 86_400)_day" }
            if seconds % 3600 == 0 { return "\(seconds / 3600)_hour" }
            return nil
        }
    }
}

/// §17.1 `discontinuity_events` detection over the consecutive-poll comparison (STEP_52) —
/// pure, like the polling policies, so the per-type gating is unit-testable without I/O.
/// `window_reset` rows are NOT detected here: they ride the §13.2 `windowReset(tool)` event
/// inside `StateEngine`, whose R33-7 once-per-anchor rule is the dedup.
///
/// Every account-scoped comparison requires both sides non-null: a null↔value transition is
/// payload shape (overnight null window, failed identity fetch, Codex healthy idle), never a
/// discontinuity. `limit_changed` is currently observable only for the monthly limit
/// (`window_type = "monthly"`, user decision 2026-07-19): no wire payload carries a 5-hour/weekly
/// window limit — the `poll_snapshots` limit columns have been NULL since v1.
///
/// **The window facts narrow that rule without abolishing it** (REV-69 / D-76 — STEP_114,
/// Baseline §17.1 stability gate). A window slot going null *while its anchor was still ahead*
/// and the other slot still carries usage is a `window_removed`; when every window is null the
/// payload is idle and nothing is written. Two limits are deliberate and recorded:
/// - `window_added` is detected for the **secondary** slot only. A primary slot going nil → live
///   is indistinguishable, from two snapshots, from a window starting after idle (Claude's
///   overnight null → morning window; Codex Enterprise idle → active), and the failure the user
///   named unacceptable is a false alarm — so the primary case is not claimed.
/// - `early_reset` on the primary slot also trips `StateEngine.detectWindowReset`'s advance
///   clause, so both a `window_reset` and an `early_reset` row land for the same instant. That is
///   correct: the window did reset, and it reset early. It is suppressed when the **plan name
///   moves** in the same comparison — Codex replaces the window on a plan change (all three
///   historical candidates in the dogfood `quota_series` were plan changes or the REV-64
///   demolition). The move, not the row: STEP_121's damping can withhold the `plan_changed` row,
///   and the window was still replaced.
///
/// **`plan_changed` is damped** (REV-73 §4.2 / D-81 — STEP_121). Two names that already traded
/// places inside `PlanChangeStability.dampingWindow` are two provider sources disagreeing, and the
/// corpus proves the cost of believing them: 245 of 248 stored Codex rows are one `enterprise ↔
/// business` argument. The caller supplies the recent stored rows; see `PlanChangeStability`.
///
/// Reads the RAW snapshots, never the R33-7-degraded ones (an expired-and-degraded window would
/// read as removed). `now` is the poll clock threaded from the coordinator.
public enum DiscontinuityDetector {

    /// The weekly slot's width, as this detector's events assume it. `secondaryUsedPct` is the
    /// weekly window on both tools (`QuotaSnapshot` doc), so one constant serves both here.
    /// *(Corrected STEP_188: the **Claude** wire carries no secondary width — Codex reports one on
    /// both transports and `QuotaSnapshot.secondaryWindowSeconds` now carries it. This constant
    /// stays the assumption these event rows are written against; the substrate column stores only
    /// what a provider actually stated.)*
    public static let secondaryWindowSeconds = 604_800

    /// One window slot as the facts see it — the same shape for primary and secondary so the
    /// rules below are written once. `widthSeconds` is what a `window_removed` row records as
    /// its `old_value` (primary: `primaryWindowLength`, i.e. REV-60's five-hour fallback on
    /// Claude; secondary: the weekly constant).
    private struct Slot {
        let usedPct: Double?
        let resetsAt: Date?
        let widthSeconds: Int
        let windowType: String?
        var isLive: Bool { usedPct != nil }
    }

    private static func primary(_ s: QuotaSnapshot) -> Slot {
        let width = Int(s.primaryWindowLength)
        return Slot(usedPct: s.primaryUsedPct, resetsAt: s.primaryResetsAt, widthSeconds: width,
                    windowType: DiscontinuityObservation.windowTypeName(seconds: width))
    }

    private static func secondary(_ s: QuotaSnapshot) -> Slot {
        Slot(usedPct: s.secondaryUsedPct, resetsAt: s.secondaryResetsAt,
             widthSeconds: secondaryWindowSeconds,
             windowType: DiscontinuityObservation.windowTypeName(seconds: secondaryWindowSeconds))
    }

    /// `recentPlanChanges` is the tool's stored `plan_changed` rows over the last
    /// `PlanChangeStability.dampingWindow`, supplied by the caller (`PollCoordinator` reads them
    /// only on the rare poll where the plan string actually moved). Empty means "no history to
    /// judge against", which is the correct reading on a first observation.
    public static func detect(previous: QuotaSnapshot?,
                              current: QuotaSnapshot,
                              now: Date,
                              recentPlanChanges: [PlanTransition] = []) -> [DiscontinuityObservation] {
        guard let previous else { return [] }
        var events: [DiscontinuityObservation] = []
        let tol = QuotaSnapshot.resetJitterTolerance

        // limit_changed — the monthly ceiling moved (admin/provider adjustment, A20's case).
        if let old = previous.monthlyLimit?.limitAmount,
           let new = current.monthlyLimit?.limitAmount, old != new {
            events.append(DiscontinuityObservation(
                eventType: .limitChanged, windowType: "monthly",
                oldValue: numeric(old), newValue: numeric(new)))
        }

        // plan_changed — the only durable record of a plan change (`accounts` is
        // INSERT OR REPLACE). **Damped** (REV-73 §4.2 / D-81 — STEP_121): a pair of names that
        // already traded places inside `PlanChangeStability.dampingWindow` is two provider sources
        // disagreeing, and writing that down again is the detector deriving a claim from an
        // unstable input. The comparison itself is unchanged — only the write is withheld — so the
        // `early_reset` suppression below still sees the plan move.
        let planChanged = previous.planType != nil && current.planType != nil
            && previous.planType != current.planType
        if let old = previous.planType, let new = current.planType, old != new,
           !PlanChangeStability.isDamped(from: old, to: new, at: now,
                                         history: recentPlanChanges) {
            events.append(DiscontinuityObservation(
                eventType: .planChanged, oldValue: old, newValue: new))
        }

        // credits_toggled — extra_usage flipped. Both objects must be present: a missing
        // object means the account exposes no pay-as-you-go at all (§7.1), not "off".
        if let old = previous.extraUsage?.isEnabled,
           let new = current.extraUsage?.isEnabled, old != new {
            events.append(DiscontinuityObservation(
                eventType: .creditsToggled,
                oldValue: old ? "1" : "0", newValue: new ? "1" : "0"))
        }

        // monthly_rollover — the cycle end advanced. old_value = spend-at-rollover (what the
        // closing cycle consumed), new_value = the new cycle end.
        if let old = previous.monthlyLimit, let new = current.monthlyLimit,
           new.resetsAt.timeIntervalSince(old.resetsAt) > QuotaSnapshot.resetJitterTolerance {
            events.append(DiscontinuityObservation(
                eventType: .monthlyRollover,
                oldValue: numeric(old.usedAmount),
                newValue: String(Int(new.resetsAt.timeIntervalSince1970))))
        }

        // ── REV-69 window facts (D-76 — STEP_114) ─────────────────────────────────────────
        // Nothing below fires on an all-null payload: that is idle, the payload-shape rule above.
        if !current.isNullWindow {
            let slots: [(prev: Slot, cur: Slot, otherLive: Bool, isPrimary: Bool)] = [
                (primary(previous), primary(current), secondary(current).isLive, true),
                (secondary(previous), secondary(current), primary(current).isLive, false),
            ]
            for (prev, cur, otherLive, isPrimary) in slots {
                // window_removed — the slot vanished while its anchor was still ahead. The
                // future anchor is what separates this from Claude's post-expiry null and from a
                // normal rollover; the other slot still carrying usage is the stability gate. A
                // Codex *unanchored* current has usedPct 0 (non-nil) and stays StateEngine's
                // `window_demolished`.
                if prev.isLive, let anchor = prev.resetsAt,
                   anchor.timeIntervalSince(now) > tol, !cur.isLive, otherLive {
                    events.append(DiscontinuityObservation(
                        eventType: .windowRemoved, windowType: prev.windowType,
                        oldValue: String(prev.widthSeconds), newValue: nil,
                        utilizationPct: prev.usedPct))
                }
                // window_added — secondary slot only (see the type doc); the primary must be live
                // on both sides so this is a window appearing *beside* one, not idle → active.
                if !isPrimary, !prev.isLive, cur.isLive,
                   primary(previous).isLive, primary(current).isLive {
                    events.append(DiscontinuityObservation(
                        eventType: .windowAdded, windowType: cur.windowType,
                        oldValue: nil, newValue: String(cur.widthSeconds)))
                }
                // early_reset — the anchor advanced while the scheduled one was still ahead and
                // the window carried usage (0 % forgives nothing, and is the Codex slide shape the
                // adapter already nulls). new = the observed instant. Not on a plan change.
                if !planChanged, prev.isLive, cur.isLive, let r0 = prev.resetsAt,
                   let r1 = cur.resetsAt, (prev.usedPct ?? 0) > 0,
                   r0.timeIntervalSince(now) > tol, r1.timeIntervalSince(r0) > tol {
                    events.append(DiscontinuityObservation(
                        eventType: .earlyReset, windowType: prev.windowType,
                        oldValue: String(Int(r0.timeIntervalSince1970)),
                        newValue: String(Int(now.timeIntervalSince1970)),
                        utilizationPct: prev.usedPct))
                }
            }
            // window_width_changed — the primary's reported width moved (Codex carries one; a
            // Claude width is the REV-60 fallback on both sides and never differs). Gate: the
            // window is live now. `window_type` names the NEW width.
            if let old = previous.primaryWindowSeconds, let new = current.primaryWindowSeconds,
               old != new, current.primaryUsedPct != nil {
                events.append(DiscontinuityObservation(
                    eventType: .windowWidthChanged,
                    windowType: DiscontinuityObservation.windowTypeName(seconds: new),
                    oldValue: String(old), newValue: String(new)))
            }
        }

        return events
    }

    /// Numeric-as-string per §17.1 — integral values without the trailing `.0` so the stored
    /// pair reads like the payload (`"5000"`, not `"5000.0"`).
    private static func numeric(_ value: Double) -> String {
        value == value.rounded() && value.magnitude < 1e15
            ? String(Int(value)) : String(value)
    }
}
