import SwiftUI

/// Semantic status-dot colour. The dot carries the urgency signal in both the menu bar
/// (Baseline §14.1 — always preserved across degradation modes) and the popover tabs (§15.1).
///
/// `neutral` is the null-window indicator: a known-good informational state, not an error —
/// it must not be grey (Baseline §13). `grey` is reserved for Loading / Idle-fallback.
public enum StatusDot: Sendable {
    case green
    case amber
    case red
    case grey
    case neutral

    public var color: Color { Theme.status(self) }

    /// The dot's meaning as a word, for VoiceOver (STEP_180). A coloured circle is the one place
    /// in the popover where colour is genuinely the only channel — every other status cue sits
    /// beside text that already says it. Spoken only; this string reaches no visible surface, so
    /// it is not UI Spec copy and must not be reused as a label.
    public var accessibilityStatusWord: String {
        switch self {
        case .green:   return "healthy"
        case .amber:   return "needs attention"
        case .red:     return "critical"
        case .grey:    return "unknown"
        case .neutral: return "no active window"
        }
    }
}
