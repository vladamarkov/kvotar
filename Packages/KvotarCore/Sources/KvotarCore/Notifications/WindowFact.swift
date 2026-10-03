import Foundation

/// A provider-side window fact as one poll observed it, folded for telling (UI Spec §4.1a /
/// §2.8 trigger 6 — REV-69/D-76, STEP_146). The detector records a restructuring as two rows —
/// `window_width_changed` on the primary slot and `window_added` on the secondary, at the same
/// instant (the 2026-08-25 Codex change: weekly only → 5-hour + weekly) — and told one at a
/// time they contradict each other. Here they become one fact. The stored rows are untouched.
///
/// Widths are seconds as the wire reports them, `nil` where the row carried none; the copy
/// names them (D-58) and never states a size.
public struct WindowFact: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case added, removed, widthChanged = "width_changed", restructured
    }

    public let kind: Kind
    /// The windows the provider carried before, in slot order (`removed` / `widthChanged` /
    /// `restructured`); empty for `added`.
    public let before: [Int?]
    /// The windows it carries now (`added` / `widthChanged` / `restructured`); empty for `removed`.
    public let after: [Int?]

    public init(kind: Kind, before: [Int?] = [], after: [Int?] = []) {
        self.kind = kind
        self.before = before
        self.after = after
    }

    /// The facts in one poll's moments. `early_reset` is not one (§4.1a: nothing to act on).
    public static func fold(_ moments: [DiscontinuityObservation]) -> [WindowFact] {
        let width = { (value: String?) -> Int? in value.flatMap(Int.init) }
        let added = moments.filter { $0.eventType == .windowAdded }
        let widthChanged = moments.first { $0.eventType == .windowWidthChanged }
        var facts: [WindowFact] = []
        if let widthChanged {
            if let partner = added.first {
                facts.append(WindowFact(kind: .restructured,
                                        before: [width(widthChanged.oldValue)],
                                        after: [width(widthChanged.newValue), width(partner.newValue)]))
            } else {
                facts.append(WindowFact(kind: .widthChanged,
                                        before: [width(widthChanged.oldValue)],
                                        after: [width(widthChanged.newValue)]))
            }
        }
        for row in added.dropFirst(widthChanged == nil ? 0 : 1) {
            facts.append(WindowFact(kind: .added, after: [width(row.newValue)]))
        }
        for row in moments where row.eventType == .windowRemoved {
            facts.append(WindowFact(kind: .removed, before: [width(row.oldValue)]))
        }
        return facts
    }
}
