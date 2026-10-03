import CoreGraphics
import Foundation

/// Diagnostics only: forces the quota surface's height budget so the constrained path can be
/// exercised on a tall display. Read once, never persisted, never surfaced — there is no height
/// setting (STEP_179).
///
/// Lifted out of `MenuBarController` at STEP_204 because the window measures its own budget from
/// its own screen and needs the same escape hatch; one read, two surfaces.
enum PopoverHeightOverride {
    static let value: CGFloat? = {
        guard let raw = ProcessInfo.processInfo.environment["KVOTAR_MAX_POPOVER_HEIGHT"],
              let value = Double(raw), value > 0 else { return nil }
        return CGFloat(value)
    }()
}
