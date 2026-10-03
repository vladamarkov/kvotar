import Foundation
import KvotarCore

/// Where an explicit link should open the History window — a **typed** destination, never a
/// string the receiver parses (STEP_178; widened to four modes in STEP_182 — REV-93 / D-115).
///
/// Two producers. The popover's `N more projects ›` names the provider whose tab was open and the
/// **local day the section was describing**, captured at click time, so a midnight rollover
/// between the click and the window's asynchronous load cannot move the target. A Weekly recap
/// evidence link names the mode that holds the supporting evidence, the exact completed week, and
/// the provider where the fact belongs to one.
///
/// A `nil` destination is the ordinary opening — Weekly recap — which the popover footer link and
/// the status-item menu item both keep.
public struct HistoryDestination: Sendable, Equatable {

    /// What the destination narrows to on arrival. A day for the projects hand-off, a completed
    /// week for a recap evidence link, and nothing at all where the mode itself is the target.
    public enum Scope: Sendable, Equatable {
        /// The start of a local day. Matched to a strip column **by calendar day** rather than by
        /// instant: History's oldest column starts at the report's period start, not at midnight,
        /// so an equality test would silently fall back to the default selection.
        case day(Date)
        /// A completed local Monday–Sunday week, `[start, end)`.
        case week(start: Date, end: Date)
    }

    /// Which grain of a day the reader is being sent to. Projects is the only one so far.
    public enum Focus: Sendable, Equatable {
        case projects
    }

    /// The mode to open. Weekly recap is the ordinary open and is never a link target — a recap
    /// link always points *out* of the recap at the evidence behind a claim.
    public let mode: HistoryExperience.Mode
    /// The provider to filter to, or `nil` for `All`. Absent on Weekly recap, which has no
    /// provider control.
    public let provider: Tool?
    public let scope: Scope?
    public let focus: Focus?
    /// The removable banner the destination renders on arrival —
    /// `From weekly recap · Claude · Sep 1 – Sep 7`. Built here, with the link that carries it,
    /// so the banner and the scope it describes cannot drift; `nil` on an unscoped open.
    /// Rendering and clearing it is the view's job (STEP_183).
    public let banner: String?

    public init(mode: HistoryExperience.Mode, provider: Tool? = nil, scope: Scope? = nil,
                focus: Focus? = nil, banner: String? = nil) {
        self.mode = mode
        self.provider = provider
        self.scope = scope
        self.focus = focus
        self.banner = banner
    }

    /// The popover's projects hand-off, unchanged in behaviour: Explore usage, that provider,
    /// that local day, no banner (§6.2's banner belongs to recap links alone).
    public static func projects(provider: Tool, day: Date) -> HistoryDestination {
        HistoryDestination(mode: .exploreUsage, provider: provider, scope: .day(day),
                           focus: .projects)
    }

    /// The day this destination selects, where it has one.
    public var day: Date? {
        if case .day(let value) = scope { return value }
        return nil
    }

    /// The completed week this destination scopes to, where it has one.
    public var week: (start: Date, end: Date)? {
        if case .week(let start, let end) = scope { return (start, end) }
        return nil
    }
}
