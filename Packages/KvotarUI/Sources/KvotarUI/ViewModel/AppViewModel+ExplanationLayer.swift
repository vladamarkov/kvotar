import Foundation
import KvotarCore

/// One hover-card target: a registry element at a particular place in the popover. `site`
/// disambiguates elements rendered more than once (the two E-03 reset rows; the E-01 quota row
/// and the D-58 header caption), so the card hangs under the instance the pointer is on.
public struct ExplanationTarget: Hashable, Sendable {
    public let element: ExplanationElement
    public let site: String

    public init(_ element: ExplanationElement, site: String = "") {
        self.element = element
        self.site = site
    }
}

/// The hover-card half of the explanation layer (UI Spec Part 3 §5.1/§5.2, D-72 — STEP_111): the
/// same gesture grammar as the verdict anatomy — pointer rests ≥ `hoverPeekDelay` → *peek*; click →
/// *pin*; the peek follows the pointer with a `hoverGraceLeave` grace so it can cross the 6 pt gap
/// into the card; a pin is released by click-away, Esc, a tab switch, popover close, or pinning
/// the anatomy. One card at a time. Nothing here is persisted.
///
/// **Every peek waits the full delay** (REV-75/D-91 — STEP_132). There is no shortcut between
/// adjacent elements, so sweeping the pointer down the popover opens nothing at all.
extension AppViewModel {

    /// The card to draw, if any — a pin wins over a peek.
    public var activeCard: ExplanationTarget? { pinnedCard ?? peekedCard }

    /// Pointer entered (`hovering == true`) or left a registry element.
    public func explanationHover(_ target: ExplanationTarget, hovering: Bool) {
        if hovering {
            // Phantom enter while the popover window re-frames (STEP_110): not a hover.
            guard Date().timeIntervalSince(explanationSettledAt) >= hoverSettle else { return }
            hoveredExplanation = target
            explanationTimer?.cancel()
            // A pinned card owns the overlay; other elements still show their tell but no peek
            // opens under a pin (the click-away scrim covers them anyway).
            guard pinnedCard == nil else { return }
            // No shortcut for an element entered while another is already peeked (REV-75/D-91):
            // that swap was instant, so a pointer sweeping down the list dealt out one card per
            // row. Every element re-arms the full delay; the one already showing ends on its own
            // grace. Sweeping opens nothing; resting opens one card.
            explanationTimer = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: self.hoverPeekDelay)
                guard !Task.isCancelled, self.hoveredExplanation == target,
                      self.pinnedCard == nil else { return }
                self.peekedCard = target
                Logger.debug("Hover card peek", component: .appLifecycle,
                             metadata: ["element": target.element.specID, "site": target.site])
            }
        } else {
            if hoveredExplanation == target { hoveredExplanation = nil }
            scheduleExplanationPeekEnd()
        }
    }

    /// Pointer entered or left the card body itself. Entering keeps a peek alive; leaving ends it
    /// after the same grace, unless the pointer went back onto the element.
    ///
    /// Entering cancels **both** timers: the card is reached across the 6 pt gap, which lies over
    /// the *next* row, so that row has just armed a peek-in of its own that must not open under a
    /// card the reader is already reading.
    public func explanationCardHover(_ hovering: Bool) {
        explanationCardHovered = hovering
        if hovering {
            explanationTimer?.cancel()
            explanationEndTimer?.cancel()
        } else if pinnedCard == nil {
            scheduleExplanationPeekEnd()
        }
    }

    /// Click on a registry element: pin its card, or release it if it is the one already pinned.
    /// Pinning ends the peek machinery and releases a pinned anatomy (§5.1 exclusivity).
    public func togglePinnedCard(_ target: ExplanationTarget) {
        explanationTimer?.cancel()
        explanationEndTimer?.cancel()
        if pinnedCard == target {
            pinnedCard = nil
            return
        }
        peekedCard = nil
        releasePinnedAnatomy()
        pinnedCard = target
        Logger.debug("Hover card pinned", component: .appLifecycle,
                     metadata: ["element": target.element.specID, "site": target.site])
    }

    /// Release a pinned card — click-away scrim, Esc.
    public func releasePinnedCard() {
        explanationTimer?.cancel()
        explanationEndTimer?.cancel()
        if let card = pinnedCard {
            pinnedCard = nil
            Logger.debug("Hover card released", component: .appLifecycle,
                         metadata: ["element": card.element.specID])
        }
    }

    /// Drop every card state (hover tell, peek, pin) and, unless told otherwise, re-arm the settle
    /// guard — a tab switch and a popover open both re-frame the window.
    func resetExplanationCards(stampSettle: Bool = true) {
        explanationTimer?.cancel()
        explanationTimer = nil
        explanationEndTimer?.cancel()
        explanationEndTimer = nil
        explanationCardHovered = false
        if hoveredExplanation != nil { hoveredExplanation = nil }
        if peekedCard != nil { peekedCard = nil }
        if pinnedCard != nil { pinnedCard = nil }
        if stampSettle { explanationSettledAt = Date() }
    }

    /// End the showing peek after the grace — unless the pointer came back to *that* element or
    /// went into its card.
    ///
    /// The guard is "not back on the element it belongs to", not "nothing is hovered" (STEP_132).
    /// Without the instant swap, the pointer is routinely on B while A is still showing, and the
    /// old wording left A up until B's own delay elapsed. It captures `showing` rather than
    /// re-reading `peekedCard`, so a card that opened while this timer was in flight is never
    /// closed by the previous card's grace.
    private func scheduleExplanationPeekEnd() {
        explanationEndTimer?.cancel()
        guard let showing = peekedCard else { return }
        explanationEndTimer = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.hoverGraceLeave)
            guard !Task.isCancelled, self.peekedCard == showing,
                  self.hoveredExplanation != showing,
                  !self.explanationCardHovered else { return }
            self.peekedCard = nil
        }
    }
}
