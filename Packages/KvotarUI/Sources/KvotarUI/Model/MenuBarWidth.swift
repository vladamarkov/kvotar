import Foundation

/// What the status item reserves its width against (UI Spec §1.0 / Baseline §14.1, REV-97 §2.6 —
/// STEP_199).
///
/// Width may change only on a state transition. A state with two phases therefore reserves the
/// **wider phase** at the transition into it and never re-measures: a bar that grew by two points
/// for five seconds every minute would shove every item to its left back and forth all day.
///
/// Pure on purpose. `MenuBarController` owns the one AppKit measurement and reads these two rules;
/// a test measures the same renders through its own hosting view and asserts the reservation does
/// not move across a phase edge. Two readers, one derivation (PATTERNS).
public enum MenuBarWidth {

    /// Every render the item can draw **without a state change** — the steady form plus, for each
    /// line, that line showing each of its reminders.
    ///
    /// The item's width is the width of its widest row, and each candidate here differs from the
    /// steady form in exactly one row, so the maximum over this list *is* the reserved width. It
    /// is bounded: at most two lines with at most two reminders each, so five renders.
    public static func phaseRenders(_ render: MenuBarRender) -> [MenuBarRender] {
        let steady = steadyForm(render)
        var out = [steady]
        for (i, line) in steady.lines.enumerated() {
            for j in line.reminders.indices {
                out.append(steady.showingReminder(j, on: i))
            }
        }
        return out
    }

    /// The render with every phase turned off — what the controller keys its re-measure on.
    ///
    /// Two renders with the same steady form say the same things and differ only in *which* of
    /// them is on screen right now, so they must share a width. A phase edge changes the drawn
    /// render and leaves this value alone, which is the whole rule in one comparison.
    public static func steadyForm(_ render: MenuBarRender) -> MenuBarRender {
        guard case .tools(let lines) = render.content else { return render }
        guard lines.contains(where: { $0.reminderIndex != nil }) else { return render }
        return MenuBarRender(lines: lines.map { $0.showingReminder(nil) })
    }
}
