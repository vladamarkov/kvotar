import CoreGraphics

/// The popover's height budget and the two rules that hang off it (Baseline §15.2, UI Spec §REV92
/// *Appearance and fit* — STEP_179).
///
/// Until this step nothing in the app had ever asked how much room the screen has. The hosting
/// controller reports its fitting size as the preferred content size, so the popover hugged its
/// content with no ceiling — and once a state outgrew the space under the menu bar, AppKit
/// re-fitted the window rather than letting the reader scroll (the same failure STEP_110 hit when
/// an inserted block moved the whole window, `HeaderSectionView`).
///
/// Pure arithmetic over values, deliberately AppKit-free: `MenuBarController` reads the screen and
/// the status button, this decides what the numbers mean, and `PopoverView` draws the result.
public enum PopoverViewport {
    /// Breathing room between the popover's bottom edge and the bottom of the screen's visible
    /// frame. Covers the callout arrow and the shadow, neither of which is in the content rect.
    public static let bottomMargin: CGFloat = 16

    /// A popover never gets less than this, whatever the screen says. A pathological display (or
    /// a status item dragged somewhere strange) should still hand back a usable scrolling box
    /// rather than a sliver; the body scrolls, so nothing is lost by insisting on it.
    public static let minimumHeight: CGFloat = 240

    /// The room a popover hanging below the status item has on the screen presenting it.
    ///
    /// `anchorMinY` is the bottom edge of the status button in Cocoa screen coordinates (origin
    /// bottom-left), so the space below it is what remains above the visible frame's own bottom —
    /// which already excludes the Dock.
    public static func availableHeight(screenVisibleFrame: CGRect,
                                       anchorMinY: CGFloat,
                                       margin: CGFloat = bottomMargin,
                                       floor: CGFloat = minimumHeight) -> CGFloat {
        max(floor, anchorMinY - screenVisibleFrame.minY - margin)
    }

    /// The room a **window** carrying the same content has, on the screen presenting the window
    /// (REV-99 §2.2 — STEP_204).
    ///
    /// `availableHeight` above is anchored to the status button and does not apply here: the
    /// window hangs off nothing. What is left is the screen's own visible frame — which already
    /// excludes the Dock and the menu bar — less the window's title bar, and the same bottom
    /// margin so the window never sits flush against the screen edge.
    ///
    /// It never returns `nil` and never falls below the floor, and that is the whole point:
    /// `bodyHeight` reads `nil` as *apply no frame at all*, which removes the one scroll view's
    /// cap and lets the content grow to its natural height. On a short display a tall quota state
    /// would then produce a recovery window taller than the screen — the window that exists to be
    /// reachable, unreachable.
    public static func windowAvailableHeight(screenVisibleFrame: CGRect,
                                             chromeHeight: CGFloat,
                                             margin: CGFloat = bottomMargin,
                                             floor: CGFloat = minimumHeight) -> CGFloat {
        max(floor, screenVisibleFrame.height - chromeHeight - margin)
    }

    /// The scrolling body's height: hug the content while it fits, cap it when it does not.
    ///
    /// `nil` means *apply no frame at all* — the natural-height path. That covers both the
    /// unbounded case (`maxHeight == nil`: previews, the snapshot harness, every test that never
    /// opened a real popover) and the frame before the content has measured itself.
    public static func bodyHeight(contentHeight: CGFloat,
                                  tabBarHeight: CGFloat,
                                  maxHeight: CGFloat?) -> CGFloat? {
        guard let maxHeight, contentHeight > 0 else { return nil }
        return min(contentHeight, max(0, maxHeight - tabBarHeight))
    }
}
