import SwiftUI
import KvotarCore

/// Unified tabbed popover (Baseline §15.1, UI Spec §2). One tab per *detected* tool (D-68) —
/// both detected → `Claude` / `Codex` tabs, each carrying a status dot so the inactive tool's
/// urgency is visible without switching; one detected → tabless, that tool's content fills the
/// popover; neither → the combined welcome. ~340px
/// single column, rendered as one opaque card (prototype v6.1) so the vibrant NSPopover material
/// never bleeds the desktop through. Reads only from `AppViewModel` (PATTERNS.md — views hold no
/// business logic).
///
/// The §15.1 priority-based default tab is chosen by the menu-bar controller on each open (it calls
/// `AppViewModel.selectDefaultTab`); this view just renders `activeTab` and switches it on tap. The
/// layout hugs its content — the popover resizes to fit (see `AppDelegate` sizing options), so short
/// states (Codex null-window) no longer reserve a large empty area — **up to the room the
/// presenting screen has** (STEP_179), past which the body scrolls under the pinned tab bar.
public struct PopoverView: View {
    @EnvironmentObject private var vm: AppViewModel
    /// The scrolling body's measured content height and the pinned tab bar's — together with
    /// `AppViewModel.popoverMaxHeight` they are all `PopoverViewport.bodyHeight` needs to decide
    /// between hugging and capping (STEP_179).
    @State private var contentHeight: CGFloat = 0
    @State private var tabBarHeight: CGFloat = 0
    /// Pointer feedback on the two clickable chrome rows (STEP_180 — REV-92 §4 names a neutral
    /// hover fill, and neither row had any hover state before). Transient view state only.
    @State private var hoveredTab: Tool?
    @State private var hoveredFooter = false

    /// The one width, read by the window that carries this same view (STEP_204) so the two
    /// surfaces cannot disagree about it.
    public static let width: CGFloat = 340

    public init() {}

    public var body: some View {
        Group {
            // Transient setup view (D-68): the right-click `Set up <tool>…` item opens straight
            // to the undetected tool's setup card. Gone again on the next ordinary open — the
            // controller's `selectDefaultTab` call clears it.
            if let setupTool = vm.transientSetupTool {
                scrollingBody { FirstRunCardView(tool: setupTool) }
            }
            // Neither tool detected (fresh install): open to the combined welcome, not an empty
            // tabbed view (UI Spec Part 3 §3). Reverts to tabs as soon as either tool is detected.
            else if vm.bothUndetected {
                scrollingBody { WelcomeView() }
            } else {
                VStack(spacing: 0) {
                    // D-68: the tab bar renders detected tools only — one tool → no tab bar,
                    // its content fills the popover. It stays **outside** the scrolling body
                    // (STEP_179): the provider tabs are visible however far the reader has
                    // scrolled, and the pinned card's click-away scrim still cannot eat a tab
                    // click (a tab switch releases the pin by itself).
                    if vm.detectedTools.count > 1 {
                        tabBar.measuring { tabBarHeight = $0 }
                    }
                    scrollingBody(explains: true) {
                        content
                        historyFooter
                    }
                }
            }
        }
        .frame(width: Self.width)
        .background(Theme.card)
    }

    /// The one scrolling body (Baseline §15.2, UI Spec §REV92 *Appearance and fit* — STEP_179).
    ///
    /// Natural height while the content fits the screen's budget, capped when it does not, and
    /// the History footer belongs to it. There is exactly one scroll view in the popover: no
    /// section scrolls inside another. `vm.popoverMaxHeight == nil` (previews, snapshots, any
    /// context with no real popover) leaves the frame off entirely, which is the pre-STEP_179
    /// hug-your-content behaviour unchanged.
    ///
    /// The explanation overlay rides **inside** the scroll view, over the content (`explains`).
    /// Beside it, the card and the pinned-card scrim sat between the pointer and the scroll view
    /// and swallowed the wheel — a card opened under the pointer stopped the popover scrolling
    /// (live 2026-09-10). Inside, the wheel reaches the scroll view as it always did, and the card
    /// travels with the row it explains, so it can never be left behind by a scroll.
    @ViewBuilder
    private func scrollingBody<Content: View>(explains: Bool = false,
                                              @ViewBuilder _ body: () -> Content) -> some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) { body() }
                .measuring { contentHeight = $0 }
                .overlayPreferenceValue(ExplanationAnchorKey.self) { anchors in
                    if explains {
                        ExplanationCardOverlay(anchors: anchors)
                    }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: PopoverViewport.bodyHeight(contentHeight: contentHeight,
                                                  tabBarHeight: tabBarHeight,
                                                  maxHeight: vm.popoverMaxHeight))
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(vm.detectedTools, id: \.self) { tool in
                tabButton(tool)
            }
        }
        .background(Theme.sectionFill)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    private func tabButton(_ tool: Tool) -> some View {
        let isActive = vm.activeTab == tool
        return Button {
            vm.selectTab(tool)
        } label: {
            HStack(spacing: 6) {
                StatusDotView(dot: vm.dot(for: tool), diameter: 7)
                    .accessibilityHidden(true)   // the tab's own label carries the status word
                // A tab is a dot and a name (UI Spec §REV92): no percentage, and no marker naming
                // the §15.1 default-tab winner (D-49, REV-54). The inactive tab's percentage went
                // at the STEP_178 cutover — two numbers on one strip invited a comparison between
                // limits that are not comparable, and the dot already carries the urgency.
                Text(tool.tabLabel)
                    .fontWeight(isActive ? .semibold : .regular)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            // STEP_180: the inactive label sits on `sectionFill`, where the reviewed tertiary hex
            // reads 4.31:1. Supporting text reads 6.17:1 there and keeps the same hierarchy —
            // the active tab is still the only one in primary ink with an underline under it.
            .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
            .background(isActive ? Theme.card : (hoveredTab == tool ? Theme.hoverFill : .clear))
            .overlay(alignment: .bottom) {
                Rectangle().fill(isActive ? Theme.tabUnderline : .clear).frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredTab = $0 ? tool : (hoveredTab == tool ? nil : hoveredTab) }
        .accessibilityLabel(Text("\(tool.tabLabel) — \(vm.dot(for: tool).accessibilityStatusWord)"))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    /// Footer link to the History window (STEP_109). One muted line under the last card — the
    /// popover stays a glance surface; the 30-day view lives in its own window.
    private var historyFooter: some View {
        Button {
            vm.openHistory()
        } label: {
            HStack {
                Text("History · last 30 days")
                    .font(.caption2)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
            }
            // STEP_180: on the chrome band, for the same reason as the inactive tab label above.
            .foregroundStyle(hoveredFooter ? Theme.blueHover : Theme.textSecondary)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hoveredFooter ? Theme.hoverFill : Theme.sectionFill)
        .onHover { hoveredFooter = $0 }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.activeTab {
        case .claude:
            ClaudePopoverContent(state: vm.claudeState, deltaLine: vm.deltaLines[.claude],
                                 onDismissDeltaLine: { vm.dismissDeltaLine(.claude) },
                                 onOpenProjects: { vm.openProjectHistory(.claude) })
        case .codex:
            CodexPopoverContent(state: vm.codexState, deltaLine: vm.deltaLines[.codex],
                                onDismissDeltaLine: { vm.dismissDeltaLine(.codex) },
                                onOpenProjects: { vm.openProjectHistory(.codex) })
        }
    }
}

// MARK: - Height measurement (STEP_179)

extension View {
    /// Report this view's own height.
    ///
    /// A background `GeometryReader` rather than a wrapping one — measuring must not change what
    /// is measured — and the value goes straight to the caller's state rather than up the tree as
    /// a `PreferenceKey`. **Preferences do not cross a macOS `ScrollView`** (measured 2026-09-10:
    /// the listener fires once with the key's default and never again), and this is the pattern
    /// the scrolling body needs, so both measurements use it.
    fileprivate func measuring(_ report: @escaping (CGFloat) -> Void) -> some View {
        background(GeometryReader { proxy in
            Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in
                report(height)
            }
        })
    }
}
