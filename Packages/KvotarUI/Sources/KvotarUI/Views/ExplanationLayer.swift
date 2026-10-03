import SwiftUI
import KvotarCore

/// The hover-card half of the explanation layer (UI Spec Part 3 §5.1/§5.2, D-72 — STEP_111).
///
/// Three pieces, all pure rendering (PATTERNS.md — views hold no business logic; the timing and the
/// peek/pin state live on `AppViewModel`):
///
/// - `ExplanationContext` — what a tab tells its elements once (tool, grain, freeze) so a row can
///   resolve its card without every section view threading a `tool` parameter.
/// - `.explainable(_:site:)` — attached to a registry element: reports the element's frame and its
///   card body up the tree, feeds hover / click to the view model, and tells the wrapped content
///   whether it is hovered (the *label* brightens and takes a dotted underline — nothing at rest;
///   the header hero `%` opts out and shows no tell, §5.1).
/// - `ExplanationCardOverlay` — one overlay at the popover root that draws the single active card
///   inside the popover's bounds, 6 pt below its element, flipping above when it would leave the
///   popover. Never a second window; the popover never changes size or position.

// MARK: - Context

/// What a tab hands its explainable elements: the tool (which copy column), the D-58 grain word
/// (fills the Codex E-01 `[Width]`), and the freeze reason the source-tag card may name. `nil` in
/// the environment (History window, bare previews) leaves every element inert.
struct ExplanationContext: Equatable {
    let tool: Tool
    var grain: String? = nil
    var freeze: SourceFreeze? = nil
}

private struct ExplanationContextKey: EnvironmentKey {
    static let defaultValue: ExplanationContext? = nil
}

/// True inside an `.explainable` element while the pointer rests on it — the label reads it to
/// draw the hover tell (§5.1).
private struct ExplanationHoveredKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var explanationContext: ExplanationContext? {
        get { self[ExplanationContextKey.self] }
        set { self[ExplanationContextKey.self] = newValue }
    }
    var explanationHovered: Bool {
        get { self[ExplanationHoveredKey.self] }
        set { self[ExplanationHoveredKey.self] = newValue }
    }
}

// MARK: - Anchors

/// What one card shows: the concept text, and at most one live line beneath it (UI Spec Part 3
/// §5.2 rule 4 as amended — REV-75/D-88, STEP_130 computed it). `live` is already filled and
/// already italic (the `*…*` is the template's); `nil` means the line was dropped or the element
/// never had one — the view cannot tell the two apart and does not need to (the reason is
/// diagnostics only, D-93). `bridge` is rule 8's line (REV-77/D-97, STEP_139) — *`[left]% left ·
/// [used]% used`* — drawn **above** the concept text on a percentage element; same nil rule.
struct ExplanationCardContent: Equatable {
    let body: String
    var live: String? = nil
    var bridge: String? = nil
}

/// One element's frame (as an anchor, resolved by the overlay) and its card content — the content
/// rides up with the anchor so a state-aware card (E-09) and a live line (D-88) always render what
/// the element resolved this frame.
struct ExplanationAnchor {
    let bounds: Anchor<CGRect>
    let content: ExplanationCardContent
}

struct ExplanationAnchorKey: PreferenceKey {
    static let defaultValue: [ExplanationTarget: ExplanationAnchor] = [:]
    static func reduce(value: inout [ExplanationTarget: ExplanationAnchor],
                       nextValue: () -> [ExplanationTarget: ExplanationAnchor]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// MARK: - The element modifier

extension View {
    /// Make this view a hover-card target for `element`. `body` is the card's markdown (already
    /// resolved from the registry — a `nil` body means the element is inert and the modifier is a
    /// no-op). `live` is the card's optional live line, already filled by `DisplayFormatter`
    /// (D-88) — nil by default, so every element without one attaches exactly as before; `bridge`
    /// likewise, the rule 8 line a percentage element opens with (REV-77/D-97). `site`
    /// disambiguates repeated elements. The whole modified view is the hover and click target and
    /// the anchor the card hangs under.
    @ViewBuilder
    func explainable(_ element: ExplanationElement, site: String = "",
                     body: String?, live: String? = nil, bridge: String? = nil) -> some View {
        if let body {
            modifier(ExplainableModifier(target: ExplanationTarget(element, site: site),
                                         content: ExplanationCardContent(body: body, live: live,
                                                                         bridge: bridge)))
        } else {
            self
        }
    }
}

/// Holds the `AppViewModel` reference — instantiated only when a body exists, so `RowView` and
/// friends can be reused where no view model is in the environment (the History window).
private struct ExplainableModifier: ViewModifier {
    let target: ExplanationTarget
    let content: ExplanationCardContent
    @EnvironmentObject private var vm: AppViewModel

    // The wrapped view is named `wrapped`, not `content`: the stored card content already owns
    // that name here.
    func body(content wrapped: Content) -> some View {
        wrapped
            .environment(\.explanationHovered, vm.hoveredExplanation == target)
            .contentShape(Rectangle())
            .onHover { vm.explanationHover(target, hovering: $0) }
            .onTapGesture { vm.togglePinnedCard(target) }
            .anchorPreference(key: ExplanationAnchorKey.self, value: .bounds) {
                [target: ExplanationAnchor(bounds: $0, content: content)]
            }
    }
}

extension Text {
    /// The hover tell on a *label* (§5.1): brightens to `text` and takes a dotted underline in
    /// `text-sec`. Nothing at rest. (SwiftUI offers no underline offset; the spec's 3 pt is the
    /// prototype's, recorded in the STEP_111 notes.)
    func explanationLabelTell(_ hovered: Bool, restColour: Color) -> Text {
        self
            .foregroundStyle(hovered ? Theme.textPrimary : restColour)
            .underline(hovered, pattern: .dot, color: Theme.textSecondary)
    }

    /// The hover tell on a state-coloured value (the burn line): the underline only — the colour
    /// is meaning and stays.
    func explanationValueTell(_ hovered: Bool) -> Text {
        underline(hovered, pattern: .dot, color: Theme.textSecondary)
    }
}

// MARK: - Card chrome and card

extension View {
    /// The hover-card container (§5.1): 8 pt radius, `bg-card`, `border`, soft shadow. Shared by
    /// the registry cards and the verdict anatomy so the two read as one family.
    func hoverCardChrome() -> some View {
        self
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

/// A registry card: the spec's markdown cell (`**lead.** body`, `*emphasis*`, `` `~` ``), verdict
/// tier since REV-75/D-87. `PINNED · ESC` while pinned, as the anatomy.
///
/// Two `Text`s, not one joined string (STEP_131): the live line takes its own colour
/// (`Theme.textSecondary`), and the §5.2 rule-5 word count stays a test over plain strings. Its
/// italics come from the template's own `*…*` — the view adds no emphasis of its own.
struct ExplanationCardView: View {
    let content: ExplanationCardContent
    var pinned: Bool = false

    /// A body-only card. The History day card (STEP_116) draws its own markdown through this same
    /// chrome and has no live line.
    init(markdown: String, pinned: Bool = false) {
        self.init(content: ExplanationCardContent(body: markdown), pinned: pinned)
    }

    init(content: ExplanationCardContent, pinned: Bool = false) {
        self.content = content
        self.pinned = pinned
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if pinned {
                Text("PINNED · ESC")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Theme.blue)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            // Rule 8: the bridge line opens a percentage card — same secondary colour as the
            // live line, its italics from the template's own `*…*`.
            if let bridge = content.bridge {
                Text(Self.rendered(bridge))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(Self.rendered(content.body))
                .font(.caption)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let live = content.live {
                Text(Self.rendered(live))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .hoverCardChrome()
    }

    private static func rendered(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }
}

// MARK: - The overlay

/// Draws the one active card (a pin wins over a peek) inside the popover's bounds. Placement: full
/// width inset 13 pt, 6 pt **below** the element; **above** when below would leave the popover.
/// While pinned, a clear scrim behind the card catches the next click anywhere and releases the
/// pin — it also sits over the rows, which is what makes "one card at a time" hold. Reduce Motion:
/// no fade.
///
/// **Since STEP_179 it is drawn inside the scrolling body** (live 2026-09-10). Beside the scroll
/// view, the card and the pinned scrim sat between the pointer and the list and swallowed the
/// wheel: a card opened under the pointer stopped the popover scrolling. Inside, the wheel reaches
/// the scroll view as it always did — and the card travels with the row it explains, so it can
/// never be left describing rows the reader has scrolled past. That is what makes the *placement*
/// rules below unchanged from the unscrolled popover: the bounds a card is fitted into are the
/// content's, and the last row still flips its card above rather than off the end.
struct ExplanationCardOverlay: View {
    let anchors: [ExplanationTarget: ExplanationAnchor]
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Each card's measured height — the flip decision needs it, and it is only known after a
    /// layout pass, so a card is transparent until its own measurement lands. Keyed per target and
    /// the card view keyed by `.id(target)` so *every* card measures itself: a preference only
    /// re-fires on a changed value, and two cards of the same length (Weekly used → Weekly resets)
    /// left the second one transparent for good (live 2026-08-16).
    @State private var heights: [ExplanationTarget: CGFloat] = [:]
    /// Below or above, latched for the life of one peek/pin (STEP_131). The card's height now
    /// changes *while it is showing* — the live line re-renders on every poll — so re-deciding
    /// each frame let a near-bottom card flip sides under the reader's pointer. The first
    /// measured height decides; `vm.activeCard` changing clears it, so the next peek decides
    /// afresh. `nil` = not yet latched, and the body falls back to the same rule.
    @State private var placedAbove: Bool?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if vm.pinnedCard != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { vm.releasePinnedCard() }
                }
                if let target = vm.activeCard, let anchor = anchors[target] {
                    let rect = geo[anchor.bounds]
                    let height = heights[target]
                    let above = placedAbove ?? !fitsBelow(rect, height ?? 0, in: geo.size)
                    let y = above ? max(0, rect.minY - 6 - (height ?? 0)) : rect.maxY + 6
                    ExplanationCardView(content: anchor.content, pinned: vm.pinnedCard == target)
                        .frame(width: max(0, geo.size.width - 26))
                        .background(GeometryReader { card in
                            Color.clear.preference(key: CardHeightKey.self, value: card.size.height)
                        })
                        .onPreferenceChange(CardHeightKey.self) { measured in
                            heights[target] = measured
                            // 0 is the card leaving, not a card that fits — never latch on it.
                            guard measured > 0, placedAbove == nil else { return }
                            placedAbove = !fitsBelow(rect, measured, in: geo.size)
                        }
                        .id(target)
                        .opacity(height == nil ? 0 : 1)
                        .offset(x: 13, y: y)
                        .onHover { vm.explanationCardHover($0) }
                        .transition(reduceMotion ? .identity : .opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: vm.activeCard)
            .onChange(of: vm.activeCard) { _, _ in placedAbove = nil }
        }
    }

    /// §5.1's placement rule: 6 pt below the element unless that would leave the popover.
    private func fitsBelow(_ rect: CGRect, _ height: CGFloat, in size: CGSize) -> Bool {
        rect.maxY + 6 + height <= size.height
    }
}

private struct CardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
