import Foundation

/// The explanation layer's peek timings (UI Spec Part 1 §5 tuning table, Part 3 §5.1 — REV-75/D-91,
/// STEP_132).
///
/// One source for three surfaces. The hover cards, the verdict anatomy and the History day strip
/// are one gesture to the reader, and until this step each held its own copy of the same three
/// numbers — a delay changed in one place and not the others makes them disagree about a gesture
/// the user experiences as one.
///
/// `peekDelay` is 600 ms because 350 ms opened cards on a pointer *sweep*: the popover became a
/// slideshow on the way past. Together with the removal of the instant swap between adjacent
/// targets (`AppViewModel.explanationHover`), the rule is now simply — sweeping the list opens
/// nothing, resting on a row opens one card.
enum ExplanationTiming {
    /// Pointer must rest on a target this long before its card opens.
    static let peekDelay: Duration = .milliseconds(600)
    /// How long a peek survives after the pointer leaves — enough to cross the 6 pt gap into the
    /// card and read it.
    static let graceLeave: Duration = .milliseconds(120)
    /// Hover-enters within this long of the layer (re)appearing are the phantom AppKit delivers
    /// while the popover window re-frames, and are ignored (STEP_110, log-verified).
    static let settle: TimeInterval = 0.5
}
